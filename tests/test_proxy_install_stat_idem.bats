#!/usr/bin/env bats
# ============================================================
# test_proxy_install_stat_idem.bats — Step0_5 stat_client 幂等检测测试
# 覆盖:
#   1. -a(STAT_API_URL) / -p(STAT_API_PASSWORD) 纳入幂等比对 (f-1bafff5d)
#      - 凭据轮换后重跑 → 不再误判"无变化"跳过 → 进入重写路径
#      - 尾随空格锚定: URL 前缀碰撞 (a.com/v1 vs a.com) 不误判
#   2. 幂等跳过时的活性检查:
#      - enabled + 未运行 → restart 拉活
#      - disabled / masked (人为停用) → 不 restart 不拉活, 保持现状
#   3. 既有行为回归: -u / --alias / -g / user 模式残留 -g → 重写
# 隔离方式: 提取 Step0_5 函数 + PATH mock systemctl/wget +
#   STAT_BIN_PATH / STAT_SVC_PATH 注入临时文件 (不触碰真实系统路径)
# ============================================================

load 'test_helper'

MOCK_STATE_DIR=""

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="${TEST_TMPDIR}"
    MOCK_BIN_DIR="${TEST_TMPDIR}/mock_bin"
    MOCK_STATE_DIR="${TEST_TMPDIR}/state"
    mkdir -p "${MOCK_BIN_DIR}" "${MOCK_STATE_DIR}" "${TEST_TMPDIR}/fake_client_dir"
    export MOCK_STATE_DIR

    # ---- 注入路径: 幂等检测用的假二进制 + 假 service 文件 (全在临时目录) ----
    export STAT_BIN_PATH="${TEST_TMPDIR}/fake_client_dir/stat_client"
    export STAT_SVC_PATH="${TEST_TMPDIR}/stat_client.service"
    printf '#!/bin/sh\n' > "${STAT_BIN_PATH}"
    chmod +x "${STAT_BIN_PATH}"
    STAT_SVC="${STAT_SVC_PATH}"

    # ---- mock systemctl: 行为由 state 文件驱动, 调用记录到 systemctl.log ----
    #   is_active_result/is_active_code:   is-active 的输出/退出码
    #   is_enabled_result/is_enabled_code: is-enabled 的输出/退出码
    #   restart_code:                       restart 的退出码
    cat > "${MOCK_BIN_DIR}/systemctl" <<'EOF'
#!/bin/sh
_state="${MOCK_STATE_DIR:?MOCK_STATE_DIR unset}"
echo "$@" >> "${_state}/systemctl.log"
case "$1" in
    is-active)
        cat "${_state}/is_active_result" 2>/dev/null || echo inactive
        exit "$(cat "${_state}/is_active_code" 2>/dev/null || echo 3)"
        ;;
    is-enabled)
        cat "${_state}/is_enabled_result" 2>/dev/null || echo disabled
        exit "$(cat "${_state}/is_enabled_code" 2>/dev/null || echo 1)"
        ;;
    restart)
        exit "$(cat "${_state}/restart_code" 2>/dev/null || echo 0)"
        ;;
    *)
        exit 0
        ;;
esac
EOF

    # ---- mock wget: 记录调用后失败 (仅用于探测"进入了重写路径", die 收尾) ----
    cat > "${MOCK_BIN_DIR}/wget" <<'EOF'
#!/bin/sh
_state="${MOCK_STATE_DIR:?MOCK_STATE_DIR unset}"
echo "$@" >> "${_state}/wget.log"
exit 1
EOF
    chmod +x "${MOCK_BIN_DIR}"/*
    export PATH="${MOCK_BIN_DIR}:${PATH}"

    # ---- 提取被测函数 (不能 source 整个 proxyInstall.sh — 末尾会执行 Main) ----
    sed -n '/^Step0_5_InstallServerStatus() {/,/^}$/p' \
        "${PROJECT_ROOT}/proxyInstall.sh" > "${TEST_TMPDIR}/step05.sh"

    # ---- 桩: log / die ----
    cat > "${TEST_TMPDIR}/stubs.sh" <<'EOF'
log() { _lvl="$1"; shift; echo "[${_lvl}] $*" >> "${MOCK_STATE_DIR}/log.out"; }
die() { log error "die: $*"; exit 1; }
EOF
    . "${TEST_TMPDIR}/stubs.sh"
    . "${TEST_TMPDIR}/step05.sh"

    # ---- 公共环境 (各测试按需覆盖) ----
    node_name="node_101"
    stat_user="0123456789abcdef0123456789abcdef"
    STAT_USER=""
    STAT_GID="g1"
    STAT_API_URL="https://stat.old.example.com"
    STAT_API_PASSWORD="oldpass"

    # 默认: enabled + active (健康在跑)
    printf 'enabled\n' > "${MOCK_STATE_DIR}/is_enabled_result"; printf '0\n' > "${MOCK_STATE_DIR}/is_enabled_code"
    printf 'active\n'  > "${MOCK_STATE_DIR}/is_active_result";  printf '0\n' > "${MOCK_STATE_DIR}/is_active_code"
    printf '0\n' > "${MOCK_STATE_DIR}/restart_code"
}

teardown() {
    unset STAT_BIN_PATH STAT_SVC_PATH MOCK_STATE_DIR 2>/dev/null || true
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
    return 0
}

# 写一份"当前已装"的 service 文件 (模拟子脚本的产物)
# 用法: write_svc <url> <pass> <gid|""> <alias> <u>
write_svc() {
    _gid_part=""
    [ -n "$3" ] && _gid_part="-g $3 "
    cat > "${STAT_SVC}" <<EOF
#Version=v1.1.0
[Unit]
Description=ServerStatus-Rust Client ($4)

[Service]
ExecStart=/opt/ServerStatus/client/stat_client -a $1 -u $5 -p $2 ${_gid_part}--alias $4 --interval 17
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}

entered_rewrite()    { grep -q "serverstatus_client_install.sh" "${MOCK_STATE_DIR}/wget.log" 2>/dev/null; }
restart_called()     { grep -q "restart stat_client" "${MOCK_STATE_DIR}/systemctl.log" 2>/dev/null; }
log_has()            { grep -q "$1" "${MOCK_STATE_DIR}/log.out" 2>/dev/null; }

# ============================================================
# f-1bafff5d: -a / -p 纳入幂等比对
# ============================================================

@test "幂等命中: 配置全一致 (含 -a/-p) + active + enabled → 跳过, 不重装不重启" {
    write_svc "${STAT_API_URL}" "${STAT_API_PASSWORD}" "${STAT_GID}" "${node_name}" "${stat_user}"
    run Step0_5_InstallServerStatus
    [ "$status" -eq 0 ]
    ! entered_rewrite
    ! restart_called
    log_has "跳过安装"
}

@test "f-1bafff5d: 面板轮换上报地址 (STAT_API_URL) → 不再误判无变化, 进入重写路径" {
    write_svc "https://stat.new.example.com" "${STAT_API_PASSWORD}" "${STAT_GID}" "${node_name}" "${stat_user}"
    run Step0_5_InstallServerStatus
    # 重写路径: 已发起子脚本下载 (mock wget 失败 → die, 非零退出属预期)
    [ "$status" -ne 0 ]
    entered_rewrite
}

@test "f-1bafff5d: 面板轮换上报密码 (STAT_API_PASSWORD) → 进入重写路径" {
    write_svc "${STAT_API_URL}" "newpass" "${STAT_GID}" "${node_name}" "${stat_user}"
    run Step0_5_InstallServerStatus
    [ "$status" -ne 0 ]
    entered_rewrite
}

@test "锚定: 旧 URL 是新 URL 的延长 (a.com/v1 vs a.com) → 判定变化, 重写" {
    STAT_API_URL="https://a.com"
    write_svc "https://a.com/v1" "${STAT_API_PASSWORD}" "${STAT_GID}" "${node_name}" "${stat_user}"
    run Step0_5_InstallServerStatus
    [ "$status" -ne 0 ]
    entered_rewrite
}

@test "锚定: 新 URL 是旧 URL 的延长 (a.com vs a.com/v1) → 判定变化, 重写" {
    STAT_API_URL="https://a.com/v1"
    write_svc "https://a.com" "${STAT_API_PASSWORD}" "${STAT_GID}" "${node_name}" "${stat_user}"
    run Step0_5_InstallServerStatus
    [ "$status" -ne 0 ]
    entered_rewrite
}

# ============================================================
# 幂等跳过时的活性检查
# ============================================================

@test "拉活: 配置未变 + enabled + 未运行 → restart 被调用" {
    write_svc "${STAT_API_URL}" "${STAT_API_PASSWORD}" "${STAT_GID}" "${node_name}" "${stat_user}"
    printf 'inactive\n' > "${MOCK_STATE_DIR}/is_active_result"; printf '3\n' > "${MOCK_STATE_DIR}/is_active_code"
    run Step0_5_InstallServerStatus
    [ "$status" -eq 0 ]
    restart_called
    log_has "重启拉活"
    ! entered_rewrite
}

@test "拉活: restart 成功且随后 active → 确认运行日志" {
    write_svc "${STAT_API_URL}" "${STAT_API_PASSWORD}" "${STAT_GID}" "${node_name}" "${stat_user}"
    # 首次 is-active 按退出码判"未运行"(3), restart 后的复检按输出判 active
    printf 'active\n' > "${MOCK_STATE_DIR}/is_active_result"; printf '3\n' > "${MOCK_STATE_DIR}/is_active_code"
    run Step0_5_InstallServerStatus
    [ "$status" -eq 0 ]
    restart_called
    log_has "已重启并确认运行"
}

@test "保持人为停用: 配置未变 + disabled + 未运行 → 不 restart 不重装" {
    write_svc "${STAT_API_URL}" "${STAT_API_PASSWORD}" "${STAT_GID}" "${node_name}" "${stat_user}"
    printf 'disabled\n' > "${MOCK_STATE_DIR}/is_enabled_result"; printf '1\n' > "${MOCK_STATE_DIR}/is_enabled_code"
    printf 'inactive\n' > "${MOCK_STATE_DIR}/is_active_result"; printf '3\n' > "${MOCK_STATE_DIR}/is_active_code"
    run Step0_5_InstallServerStatus
    [ "$status" -eq 0 ]
    ! restart_called
    ! entered_rewrite
    log_has "人为停用"
    log_has "跳过安装"
}

@test "保持人为停用: masked 同样不拉活" {
    write_svc "${STAT_API_URL}" "${STAT_API_PASSWORD}" "${STAT_GID}" "${node_name}" "${stat_user}"
    printf 'masked\n' > "${MOCK_STATE_DIR}/is_enabled_result"; printf '1\n' > "${MOCK_STATE_DIR}/is_enabled_code"
    printf 'inactive\n' > "${MOCK_STATE_DIR}/is_active_result"; printf '3\n' > "${MOCK_STATE_DIR}/is_active_code"
    run Step0_5_InstallServerStatus
    [ "$status" -eq 0 ]
    ! restart_called
    ! entered_rewrite
}

# ============================================================
# 既有行为回归 (本次改动不得破坏)
# ============================================================

@test "回归: -u 变化 (换 IP) → 重写" {
    write_svc "${STAT_API_URL}" "${STAT_API_PASSWORD}" "${STAT_GID}" "${node_name}" "ffffffffffffffffffffffffffffffff"
    run Step0_5_InstallServerStatus
    [ "$status" -ne 0 ]
    entered_rewrite
}

@test "回归: --alias 变化 (改名) → 重写" {
    write_svc "${STAT_API_URL}" "${STAT_API_PASSWORD}" "${STAT_GID}" "node_999" "${stat_user}"
    run Step0_5_InstallServerStatus
    [ "$status" -ne 0 ]
    entered_rewrite
}

@test "回归: -g 变化 (换组) → 重写" {
    write_svc "${STAT_API_URL}" "${STAT_API_PASSWORD}" "g2" "${node_name}" "${stat_user}"
    run Step0_5_InstallServerStatus
    [ "$status" -ne 0 ]
    entered_rewrite
}

@test "回归: group→user 切换 (service 残留 -g) → 重写" {
    STAT_GID=""
    STAT_USER="fixed-user"
    write_svc "${STAT_API_URL}" "${STAT_API_PASSWORD}" "g1" "${node_name}" "fixed-user"
    run Step0_5_InstallServerStatus
    [ "$status" -ne 0 ]
    entered_rewrite
}

@test "回归: user 模式全一致 → 跳过" {
    STAT_GID=""
    STAT_USER="fixed-user"
    write_svc "${STAT_API_URL}" "${STAT_API_PASSWORD}" "" "${node_name}" "fixed-user"
    run Step0_5_InstallServerStatus
    [ "$status" -eq 0 ]
    ! entered_rewrite
    ! restart_called
    log_has "跳过安装"
}
