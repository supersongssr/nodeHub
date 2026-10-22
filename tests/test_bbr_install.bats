#!/usr/bin/env bats
# ============================================================
# test_bbr_install.bats — BBR 检测 + 独立安装脚本测试
# 覆盖:
#   A. scripts/bbr_install.sh (独立脚本, 注入口注入临时路径):
#     1. 已启用 → 幂等退出 0, 零写入 (不下载/不写配置/不 sysctl -w)
#     2. 未启用 + 内核 < 4.9 → 退出 1, 清晰报错
#     3. 未启用 + 内核 4.9 (边界) → 正常启用
#     4. 未启用 + 算法列表无 bbr (共享内核) → 退出 1
#     5. 正常路径 → 持久化 (覆盖式 conf + modules-load) + sysctl -w 即时生效
#     6. sysctl.conf 旧追加行清理: 删拥塞控制/qdisc 行, 保留无关行, 留备份
#     7. sysctl -w bbr 失败 (只读 /proc/sys) → 退出 1
#     8. fq 写失败仅告警, 不阻断 BBR 启用 (内核内部 pacing 兜底)
#     9. 启用后重跑 → 幂等退出 0, 无新增 sysctl -w 调用
#   B. proxyInstall.sh EnsureBBR (提取函数 + PATH mock):
#    10. 已启用 → 跳过, 不发起 wget 下载
#    11. 未启用 → 经 FetchValidated 下载 scripts/bbr_install.sh 并执行
#    12. 下载失败 → log error 告警但不中断 (return 0, 不 die)
# 隔离: BBR_CONF_PATH / BBR_MODULES_PATH / SYSCTL_CONF_PATH /
#       BBR_AVAIL_CC_PATH / BBR_ALLOW_NON_ROOT 注入临时目录 +
#       PATH mock sysctl/modprobe/uname/wget (行为由 state 文件驱动)
# ============================================================

load 'test_helper'

MOCK_STATE_DIR=""

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="${TEST_TMPDIR}"
    MOCK_BIN_DIR="${TEST_TMPDIR}/mock_bin"
    MOCK_STATE_DIR="${TEST_TMPDIR}/state"
    mkdir -p "${MOCK_BIN_DIR}" "${MOCK_STATE_DIR}"
    export MOCK_STATE_DIR

    # ---- 注入口: 独立脚本的落盘路径全部指向临时目录 ----
    export BBR_CONF_PATH="${TEST_TMPDIR}/sysctl.d/99-bbr.conf"
    export BBR_MODULES_PATH="${TEST_TMPDIR}/modules-load.d/bbr.conf"
    export SYSCTL_CONF_PATH="${TEST_TMPDIR}/sysctl.conf"
    export BBR_AVAIL_CC_PATH="${MOCK_STATE_DIR}/avail"
    export BBR_ALLOW_NON_ROOT=1

    # ---- 初始系统状态: 未启用 BBR 的典型节点 ----
    echo "cubic"          > "${MOCK_STATE_DIR}/cc"
    echo "fq_codel"       > "${MOCK_STATE_DIR}/qdisc"
    echo "reno cubic"     > "${MOCK_STATE_DIR}/avail"
    echo "6.1.0-13-amd64" > "${MOCK_STATE_DIR}/kver"

    # ---- mock sysctl: 读走 state 文件, -w 记录日志并更新 state (可注入失败) ----
    #   cc / qdisc        : 当前算法/队列 (读)
    #   w_fail_cc / w_fail_qdisc: 存在时对应 -w 写入失败 (模拟只读 /proc/sys)
    cat > "${MOCK_BIN_DIR}/sysctl" <<'EOF'
#!/bin/sh
_state="${MOCK_STATE_DIR:?MOCK_STATE_DIR unset}"
case "$1" in
    -n)
        case "$2" in
            net.ipv4.tcp_congestion_control) cat "${_state}/cc" 2>/dev/null || echo cubic ;;
            net.core.default_qdisc)          cat "${_state}/qdisc" 2>/dev/null || echo fq_codel ;;
            *) echo "net.$(echo "$2" | tr . /) = unknown" ;;
        esac
        ;;
    net.ipv4.tcp_congestion_control)
        # 裸 key 查询 (EnsureBBR 检测用): 输出与真实 sysctl 同格式
        echo "net.ipv4.tcp_congestion_control = $(cat "${_state}/cc" 2>/dev/null || echo cubic)"
        ;;
    -w)
        echo "sysctl $*" >> "${_state}/sysctl_w.log"
        # 真实 sysctl: -w key=value 为单参数, 此处拆开解析
        _assign="$2"
        _key="${_assign%%=*}"
        _val="${_assign#*=}"
        case "$_key" in
            net.ipv4.tcp_congestion_control)
                [ -f "${_state}/w_fail_cc" ] && exit 1
                echo "$_val" > "${_state}/cc"
                ;;
            net.core.default_qdisc)
                [ -f "${_state}/w_fail_qdisc" ] && exit 1
                echo "$_val" > "${_state}/qdisc"
                ;;
        esac
        ;;
esac
exit 0
EOF

    # ---- mock modprobe: 记录调用; tcp_bbr 成功后 bbr 进入可用算法列表 ----
    #   (modprobe_noop 文件存在时模拟共享内核: 不改算法列表但仍退出 0)
    cat > "${MOCK_BIN_DIR}/modprobe" <<'EOF'
#!/bin/sh
_state="${MOCK_STATE_DIR:?MOCK_STATE_DIR unset}"
echo "$@" >> "${_state}/modprobe.log"
if [ "$1" = "tcp_bbr" ] && [ ! -f "${_state}/modprobe_noop" ]; then
    echo "reno cubic bbr" > "${_state}/avail"
fi
exit 0
EOF

    # ---- mock uname: -r 读 state (内核版本注入), 其余透传真实 uname ----
    cat > "${MOCK_BIN_DIR}/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-r" ]; then
    cat "${MOCK_STATE_DIR}/kver" 2>/dev/null || echo 6.1.0-13-amd64
    exit 0
fi
if [ -x /bin/uname ]; then exec /bin/uname "$@"; else exec /usr/bin/uname "$@"; fi
EOF

    # ---- mock wget: 按 wget.mode 分派 (EnsureBBR 测试用) ----
    #   ok  : -N/-O 均写出合法脚本 (#!/bin/sh, 执行时 touch 标记文件)
    #   fail: 全部失败 (网络不可达)
    cat > "${MOCK_BIN_DIR}/wget" <<'EOF'
#!/bin/sh
_state="${MOCK_STATE_DIR:?MOCK_STATE_DIR unset}"
echo "$@" >> "${_state}/wget.log"
_mode="$(cat "${_state}/wget.mode" 2>/dev/null || echo ok)"
[ "$_mode" = "fail" ] && exit 1
_out="" _dir="." _url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -O) shift; _out="$1" ;;
        -P) shift; _dir="$1" ;;
        -N|--timeout=*|--tries=*) ;;
        http://*|https://*) _url="$1" ;;
    esac
    shift
done
[ -n "$_out" ] || _out="${_dir}/${_url##*/}"
printf '#!/bin/sh\ntouch "${MOCK_STATE_DIR}/bbr_ran.marker"\n' > "$_out"
exit 0
EOF

    chmod +x "${MOCK_BIN_DIR}"/*
    export PATH="${MOCK_BIN_DIR}:${PATH}"

    # 防串扰: EnsureBBR 固定下载到 /tmp/bbr_install.sh — 清掉本机残留
    rm -f /tmp/bbr_install.sh
}

teardown() {
    rm -f /tmp/bbr_install.sh
    [ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

# 运行独立脚本 (注入口已就位)
run_bbr_install() {
    run sh "${PROJECT_ROOT}/scripts/bbr_install.sh"
}

# ============================================================
# A. 独立脚本 scripts/bbr_install.sh
# ============================================================

@test "A1: BBR 已启用 → 幂等退出 0, 零写入" {
    echo "bbr" > "${MOCK_STATE_DIR}/cc"
    run_bbr_install
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "无需安装"
    # 零写入: 不落配置文件 / 不触发 sysctl -w / 不加载模块
    [ ! -f "${BBR_CONF_PATH}" ]
    [ ! -f "${MOCK_STATE_DIR}/sysctl_w.log" ]
    [ ! -f "${MOCK_STATE_DIR}/modprobe.log" ]
}

@test "A2: 未启用 + 内核 3.16 (< 4.9) → 退出 1, 清晰报错" {
    echo "3.16.0-4-amd64" > "${MOCK_STATE_DIR}/kver"
    run_bbr_install
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "4.9"
    # 失败路径不应写持久化配置
    [ ! -f "${BBR_CONF_PATH}" ]
}

@test "A3: 未启用 + 内核 4.9 (边界) → 正常启用" {
    echo "4.9.0-8-amd64" > "${MOCK_STATE_DIR}/kver"
    run_bbr_install
    [ "$status" -eq 0 ]
    [ "$(cat "${MOCK_STATE_DIR}/cc")" = "bbr" ]
}

@test "A4: 未启用 + 算法列表无 bbr (共享内核 modprobe 无效) → 退出 1" {
    touch "${MOCK_STATE_DIR}/modprobe_noop"
    run_bbr_install
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "不支持 BBR"
    [ ! -f "${BBR_CONF_PATH}" ]
}

@test "A5: 正常路径 → 持久化 + modprobe + sysctl -w 即时生效" {
    run_bbr_install
    [ "$status" -eq 0 ]
    # sysctl.d 持久化 (覆盖式, 含 fq + bbr 两行)
    [ -f "${BBR_CONF_PATH}" ]
    grep -q '^net.core.default_qdisc=fq$'        "${BBR_CONF_PATH}"
    grep -q '^net.ipv4.tcp_congestion_control=bbr$' "${BBR_CONF_PATH}"
    # modules-load.d 开机自载
    [ -f "${BBR_MODULES_PATH}" ]
    grep -q '^tcp_bbr$' "${BBR_MODULES_PATH}"
    # modprobe 已调用 + sysctl -w 两项均生效 (state 被更新)
    grep -q 'tcp_bbr' "${MOCK_STATE_DIR}/modprobe.log"
    grep -q 'net.ipv4.tcp_congestion_control=bbr' "${MOCK_STATE_DIR}/sysctl_w.log"
    [ "$(cat "${MOCK_STATE_DIR}/cc")" = "bbr" ]
    [ "$(cat "${MOCK_STATE_DIR}/qdisc")" = "fq" ]
    echo "$output" | grep -q "复验通过"
}

@test "A6: sysctl.conf 旧追加行清理 — 删旧行/保留无关行/留备份" {
    cat > "${SYSCTL_CONF_PATH}" <<'EOF'
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
    run_bbr_install
    [ "$status" -eq 0 ]
    # 拥塞控制/qdisc 行全部删除
    ! grep -q 'tcp_congestion_control' "${SYSCTL_CONF_PATH}"
    ! grep -q 'default_qdisc'          "${SYSCTL_CONF_PATH}"
    # 无关行保留
    grep -q 'net.ipv4.ip_forward=1' "${SYSCTL_CONF_PATH}"
    grep -q 'vm.swappiness=10'      "${SYSCTL_CONF_PATH}"
    # 备份保留完整旧内容
    [ -f "${SYSCTL_CONF_PATH}.bak-nodehub-bbr" ]
    grep -c 'tcp_congestion_control' "${SYSCTL_CONF_PATH}.bak-nodehub-bbr" | grep -q '^2$'
}

@test "A7: sysctl -w bbr 失败 (只读 /proc/sys) → 退出 1" {
    touch "${MOCK_STATE_DIR}/w_fail_cc"
    run_bbr_install
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "失败"
}

@test "A8: fq 写失败仅告警 — 不阻断 BBR 启用" {
    touch "${MOCK_STATE_DIR}/w_fail_qdisc"
    run_bbr_install
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "default_qdisc=fq 失败"
    [ "$(cat "${MOCK_STATE_DIR}/cc")" = "bbr" ]
}

@test "A9: 启用后重跑 → 幂等退出 0, 无新增 sysctl -w 调用" {
    run_bbr_install
    [ "$status" -eq 0 ]
    _w_count_1=$(wc -l < "${MOCK_STATE_DIR}/sysctl_w.log")
    echo "bbr" > "${MOCK_STATE_DIR}/cc"
    run_bbr_install
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "无需安装"
    _w_count_2=$(wc -l < "${MOCK_STATE_DIR}/sysctl_w.log")
    [ "$_w_count_1" = "$_w_count_2" ]
}

# ============================================================
# B. proxyInstall.sh EnsureBBR (提取函数测试)
# ============================================================

setup_ensure_bbr() {
    # 提取 EnsureBBR (不能 source 整个 proxyInstall.sh — 末尾会执行 Main)
    sed -n '/^EnsureBBR() {/,/^}$/p' \
        "${PROJECT_ROOT}/proxyInstall.sh" > "${TEST_TMPDIR}/ensure_bbr.sh"

    # FetchValidated 依赖 _ValidateFile — 一并提取
    sed -n '/^_ValidateFile() {/,/^}$/p;/^FetchValidated() {/,/^}$/p' \
        "${PROJECT_ROOT}/proxyInstall.sh" > "${TEST_TMPDIR}/fetch_validated.sh"

    # 桩: log / die (与 stat_idem 测试同风格)
    cat > "${TEST_TMPDIR}/stubs.sh" <<EOF
log() { _lvl="\$1"; shift; echo "[\${_lvl}] \$*" >> "${MOCK_STATE_DIR}/log.out"; }
die() { log error "die: \$*"; exit 1; }
EOF
    . "${TEST_TMPDIR}/stubs.sh"
    . "${TEST_TMPDIR}/fetch_validated.sh"
    . "${TEST_TMPDIR}/ensure_bbr.sh"

    NODEHUB_URL="https://hub.example.com"
    export NODEHUB_URL
}

@test "B1: BBR 已启用 → 跳过, 不发起 wget 下载" {
    setup_ensure_bbr
    echo "bbr" > "${MOCK_STATE_DIR}/cc"
    run EnsureBBR
    [ "$status" -eq 0 ]
    grep -q "BBR 已启用，跳过" "${MOCK_STATE_DIR}/log.out"
    # 未发起网络请求
    [ ! -f "${MOCK_STATE_DIR}/wget.log" ]
}

@test "B2: BBR 未启用 → 经 FetchValidated 下载并执行 bbr_install.sh" {
    setup_ensure_bbr
    EnsureBBR
    # 下载 URL 正确 (NODEHUB_URL/scripts/bbr_install.sh)
    grep -q "https://hub.example.com/scripts/bbr_install.sh" "${MOCK_STATE_DIR}/wget.log"
    # 下载的脚本被执行 (mock 脚本 touch 标记文件)
    [ -f "${MOCK_STATE_DIR}/bbr_ran.marker" ]
    # 成功路径日志
    grep -q "BBR 已由独立脚本" "${MOCK_STATE_DIR}/log.out"
}

@test "B3: 下载失败 → log error 告警但不中断 (不 die)" {
    setup_ensure_bbr
    echo "fail" > "${MOCK_STATE_DIR}/wget.mode"
    run EnsureBBR
    [ "$status" -eq 0 ]
    grep -q "bbr_install.sh 下载或校验失败" "${MOCK_STATE_DIR}/log.out"
}
