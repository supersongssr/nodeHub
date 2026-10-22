#!/bin/sh
# ============================================================
# bbr_install.sh — TCP BBR 拥塞控制检测 + 启用脚本 (独立可单跑)
# 用法:  sh bbr_install.sh    (需 root)
#        * proxyInstall.sh EnsureBBR 检测到 BBR 未启用时下载执行
#        * 亦可人工单独运行 (幂等: 已启用直接退出, 重跑不产生重复配置行)
# 背景:  BBR 对高延迟/丢包链路的代理吞吐提升显著, 需内核 >= 4.9
#        (Debian 10+ / Ubuntu 18.04+ 均满足; OpenVZ/LXC 共享内核通常不支持)
# 流程:  ① 运行时检测 — 已启用则幂等退出 (退出码 0)
#        ② 内核版本预检 (< 4.9 提前清晰报错; 解析失败放行, 交由 ③ 裁决)
#        ③ modprobe tcp_bbr (内建内核时失败无害) + 可用算法列表复验
#        ④ 持久化 — 覆盖式写 /etc/sysctl.d/99-bbr.conf (fq + bbr)
#           + modules-load.d 开机自载 + 清理 /etc/sysctl.conf 中旧安装器
#             盲目追加的拥塞控制/qdisc 行 (否则 Debian 将 sysctl.conf 以
#             99-sysctl.conf 符号链接纳入 sysctl.d 加载序且排在 99-bbr.conf
#             之后, 残留行会在重启时把算法覆盖回 cubic)
#        ⑤ sysctl -w 即时生效 (fq 失败仅告警, 内核 >= 4.13 有内部 pacing;
#           bbr 失败即败) + 最终复验 (运行时算法确为 bbr 才算成功)
# 退出码: 0 = BBR 已启用 (含此前已启用) | 1 = 无法启用 (内核不支持/权限不足)
# 测试注入口 (生产不设置即真实路径): BBR_CONF_PATH / BBR_MODULES_PATH /
#        SYSCTL_CONF_PATH / BBR_AVAIL_CC_PATH / BBR_ALLOW_NON_ROOT
#        (tests/test_bbr_install.bats)
# ============================================================

set -eu

VERSION="v1.0.0-20261001"

BBR_CONF="${BBR_CONF_PATH:-/etc/sysctl.d/99-bbr.conf}"
BBR_MODULES_CONF="${BBR_MODULES_PATH:-/etc/modules-load.d/bbr.conf}"
SYSCTL_MAIN="${SYSCTL_CONF_PATH:-/etc/sysctl.conf}"
BBR_AVAIL_CC="${BBR_AVAIL_CC_PATH:-/proc/sys/net/ipv4/tcp_available_congestion_control}"

# ============================================================
# ERR Trap — 任何命令失败时打印诊断信息后终止
# ============================================================
OnError() {
    _exit_code=$?
    [ "$_exit_code" -eq 0 ] && exit 0
    printf '\033[31m%s [FATAL] 💥 命令失败 — 退出码=%d\033[0m\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_exit_code" >&2
    exit "$_exit_code"
}
trap 'OnError' EXIT

# ============================================================
# 日志系统 — 与 serverstatus_client_install.sh 同风格
# ============================================================
log() {
    _level="$1"
    shift
    _message="$*"
    _timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    _color_code="" _emoji=""

    case "$_level" in
        error) _color_code="\033[31m"; _emoji="❌" ;;
        warn)  _color_code="\033[33m"; _emoji="⚠️" ;;
        info)  _color_code="\033[32m"; _emoji="ℹ️" ;;
        debug) _color_code="\033[36m"; _emoji="🐛" ;;
        *)     _color_code="\033[0m";  _emoji="📝" ;;
    esac

    _log_message="${_timestamp} [${_level}] ${_emoji} ${_message}"
    printf '%b%s%b\n' "$_color_code" "$_log_message" "\033[0m" >&2
}

die() {
    log error "$*"
    exit 1
}

# ============================================================
# 当前拥塞控制算法 (探测失败返回 unknown)
# ============================================================
CurrentCc() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown
}

# ============================================================
# 运行时 BBR 是否已启用
# ============================================================
IsBbrActive() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr
}

# ============================================================
# 内核版本 >= 4.9 预检 (BBR 合入版本)
# 解析失败 (非常规版本串) 放行 — 交由可用算法列表复验最终裁决
# ============================================================
KernelSupportsBbr() {
    _kver=$(uname -r 2>/dev/null || echo "")
    _major=$(printf '%s' "$_kver" | cut -d. -f1)
    _minor=$(printf '%s' "$_kver" | cut -d. -f2)
    case "${_major}" in ''|*[!0-9]*) return 0 ;; esac
    case "${_minor}" in ''|*[!0-9]*) _minor=0 ;; esac
    [ "${_major}" -gt 4 ] && return 0
    [ "${_major}" -eq 4 ] && [ "${_minor}" -ge 9 ] && return 0
    return 1
}

# ============================================================
# 清理 /etc/sysctl.conf 中旧的拥塞控制/qdisc 行
# why: 旧版 proxyInstall.sh 盲目 >> 追加, 重跑堆积重复行; 且这些键残留在
#       sysctl.conf 时, Debian 的 99-sysctl.conf 符号链接在 sysctl.d 加载序
#       中排在 99-bbr.conf 之后 → 重启后覆盖回旧值, BBR 静默丢失
# 安全: 删除前备份到 <file>.bak-nodehub-bbr; 这两个键由 ${BBR_CONF} 统一接管
# ============================================================
CleanupLegacySysctlConf() {
    if [ ! -f "${SYSCTL_MAIN}" ] \
       || ! grep -qE '^[[:space:]]*net\.(ipv4\.tcp_congestion_control|core\.default_qdisc)[[:space:]]*=' "${SYSCTL_MAIN}" 2>/dev/null; then
        return 0
    fi
    cp -f "${SYSCTL_MAIN}" "${SYSCTL_MAIN}.bak-nodehub-bbr" 2>/dev/null || true
    sed -i -E '/^[[:space:]]*net\.(ipv4\.tcp_congestion_control|core\.default_qdisc)[[:space:]]*=/d' "${SYSCTL_MAIN}" \
        || die "清理 ${SYSCTL_MAIN} 旧拥塞控制行失败 (只读文件系统?)"
    log info "已清理 ${SYSCTL_MAIN} 中旧的 tcp_congestion_control/default_qdisc 行 (备份: ${SYSCTL_MAIN}.bak-nodehub-bbr) — 由 ${BBR_CONF} 统一接管"
}

# ============================================================
# 主流程
# ============================================================
Main() {
    # root 校验 (测试注入口: BBR_ALLOW_NON_ROOT=1 跳过)
    if [ "${BBR_ALLOW_NON_ROOT:-0}" != "1" ] && [ "$(id -u)" != "0" ]; then
        die "需要 root 权限 (sysctl 写入 / 模块加载)"
    fi

    log info "===== bbr_install.sh ${VERSION} 启动 ====="

    # ① 已启用 → 幂等退出 (不产生任何写入)
    if IsBbrActive; then
        log info "BBR 已启用 (当前算法: $(CurrentCc)), 无需安装"
        return 0
    fi
    log info "BBR 未启用 (当前算法: $(CurrentCc)), 开始安装"

    # ② 内核版本预检 — 老内核直接给出清晰报错
    if ! KernelSupportsBbr; then
        die "内核 $(uname -r 2>/dev/null) < 4.9, 不支持 BBR — 请升级内核 (Debian 10+ / Ubuntu 18.04+ 自带)"
    fi

    # ③ tcp_bbr 模块 — modprobe 失败无害 (内建内核/已加载), 以可用算法列表为准
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null \
            || log debug "modprobe tcp_bbr 无模块可载 (内建内核或共享内核?), 以可用算法列表判定"
    fi
    if ! grep -q bbr "${BBR_AVAIL_CC}" 2>/dev/null; then
        die "内核不支持 BBR — 当前可用算法: $(cat "${BBR_AVAIL_CC}" 2>/dev/null || echo 未知) (共享内核 OpenVZ/LXC 无法加载 tcp_bbr 模块)"
    fi
    log info "BBR 算法可用 (内核支持已确认)"

    # ④ 持久化 (三个动作各自幂等)
    if ! mkdir -p "${BBR_CONF%/*}" 2>/dev/null; then
        die "创建目录 ${BBR_CONF%/*} 失败 (只读文件系统?)"
    fi
    CleanupLegacySysctlConf

    # ④-b sysctl 持久化 — 覆盖式写入, 重跑不产生重复行
    cat > "${BBR_CONF}" <<'EOF'
# ---- TCP BBR 拥塞控制 (由 bbr_install.sh 维护, 勿手动编辑) ----
# fq 为 BBR pacing 推荐队列算法 (内核 >= 4.13 亦支持内部 pacing)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    log info "sysctl 持久化已写入 ${BBR_CONF}"

    # ④-c 模块开机自载 — 内建内核时 systemd 跳过此文件, 无害
    if mkdir -p "${BBR_MODULES_CONF%/*}" 2>/dev/null; then
        printf 'tcp_bbr\n' > "${BBR_MODULES_CONF}" \
            || log warn "写入 ${BBR_MODULES_CONF} 失败 (tcp_bbr 内建内核无需此文件; 模块型内核重启后由 sysctl 写入触发 request_module 自动加载)"
    else
        log warn "创建 ${BBR_MODULES_CONF%/*} 失败, 跳过模块自载注册 (多数发行版 sysctl 设置 bbr 时会自动 request_module)"
    fi

    # ⑤ 即时生效
    # qdisc: 个别内核/容器不可写 fq 时仅告警 — 内核 >= 4.13 有内部 pacing, 不阻断 BBR
    if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        log warn "设置 default_qdisc=fq 失败 (内核/容器不支持 fq) — 继续启用 BBR"
    fi
    # 拥塞控制算法: 关键一步, 失败即败
    if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        die "sysctl 设置 tcp_congestion_control=bbr 失败 — /proc/sys 只读 (共享内核 OpenVZ/LXC?) 或权限不足"
    fi

    # ⑥ 最终复验 — 运行时算法确为 bbr 才算成功
    if ! IsBbrActive; then
        die "BBR 复验失败 — 当前算法仍为: $(CurrentCc)"
    fi

    log info "BBR 已启用并复验通过 — 算法: bbr | qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知) | 持久化: ${BBR_CONF}"
    return 0
}

Main "$@"
