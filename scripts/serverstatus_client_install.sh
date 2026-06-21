#!/bin/sh
# ============================================================
# serverstatus_client_install.sh — ServerStatus-Rust 客户端安装脚本
# 配置参数: 纯透传 — 由调用方 (proxyInstall.sh / 人工) 在命令行提供 stat_client 参数
#           脚本不读取 ~/.env, 不解释参数语义, 原封不动写入 systemd ExecStart
# 生命周期: ProbeArch → GetLatestVersion → Download → WriteService($@) → Enable → Verify
# ============================================================

set -eu

VERSION="v1.0.0-20260530"

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
# 日志系统
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
# B. 探测架构
# ============================================================
ProbeArch() {
    _arch_raw=$(uname -m 2>/dev/null || echo "unknown")
    case "$_arch_raw" in
        x86_64|amd64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        armv7l|armhf)  ARCH="armv7" ;;
        *)             die "不支持的架构: ${_arch_raw}" ;;
    esac
    log info "系统架构: ${_arch_raw} → ${ARCH}"
}

# ============================================================
# C. 获取最新版本号
# ============================================================
GetLatestVersion() {
    _api_url="https://api.github.com/repos/zdz/ServerStatus-Rust/releases/latest"
    _latest=$(wget -qO- "$_api_url" 2>/dev/null | grep -oP '(?<="tag_name": ")[^"]*' | head -1 || true)
    if [ -z "$_latest" ]; then
        log warn "无法获取最新版本号，使用 'unknown'"
        _latest="unknown"
    fi
    log info "ServerStatus-Rust 最新版本: ${_latest}"
}

# ============================================================
# D. 下载与安装
# ============================================================
WORKING_DIR="/opt/ServerStatus"
CLIENT_DIR="${WORKING_DIR}/client"
CLIENT_FILE="${CLIENT_DIR}/stat_client"
SERVICE_CONF="/etc/systemd/system/stat_client.service"

Download() {
    _zip_name="client-${ARCH}-unknown-linux-musl.zip"
    _download_url="https://github.com/zdz/ServerStatus-Rust/releases/latest/download/${_zip_name}"

    # 确保 unzip 可用
    if ! command -v unzip >/dev/null 2>&1; then
        log info "unzip 未安装，正在自动安装..."
        apt-get update -qq && apt-get install -y -qq unzip || die "安装 unzip 失败，请手动执行: apt-get install -y unzip"
    fi

    log info "下载 ${ARCH} 二进制文件..."
    mkdir -p /tmp/stat_client
    cd /tmp/stat_client
    wget --no-check-certificate -q "$_download_url" -O "${_zip_name}" || die "下载失败: ${_download_url}"
    unzip -o "$_zip_name" || die "解压失败: ${_zip_name}"

    mkdir -p "$CLIENT_DIR"
    mv -f /tmp/stat_client/stat_client "$CLIENT_FILE"
    chmod +x "$CLIENT_FILE"
    log info "stat_client 已安装到 ${CLIENT_FILE}"
}

# ============================================================
# E. 写入 systemd 服务
# ============================================================
# 参数透传: 第一个参数即 stat_client 的全部命令行参数 (已由调用方拼好)
WriteService() {
    STAT_ARGS="$1"
    [ -z "$STAT_ARGS" ] && die "缺少 stat_client 参数 — 用法: $0 '<stat_client 的 -a/-u/-p/[-g]/... 参数>'"
    log info "写入 systemd 配置 (版本 ${_latest}) — ExecStart 参数: ${STAT_ARGS}"
    cat > "${SERVICE_CONF}" <<-EOF
#Version=${_latest}
[Unit]
Description=ServerStatus-Rust Client
After=network.target

[Service]
User=root
Group=root
Environment="RUST_BACKTRACE=1"
WorkingDirectory=${WORKING_DIR}
ExecStart=${CLIENT_FILE} ${STAT_ARGS}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    log info "systemd 配置已写入 ${SERVICE_CONF}"
}

# ============================================================
# F. 启用并启动服务
# ============================================================
EnableService() {
    systemctl daemon-reload
    systemctl enable stat_client
    systemctl restart stat_client
    log info "stat_client 服务已启用并启动"
}

# ============================================================
# G. 验证
# ============================================================
Verify() {
    if systemctl is-active --quiet stat_client; then
        log info "✅ stat_client 运行正常"
        systemctl status stat_client --no-pager || true
    else
        die "❌ stat_client 启动失败，请检查: journalctl -u stat_client -n 50"
    fi
}

# ============================================================
# H. 清理临时文件
# ============================================================
Cleanup() {
    rm -rf /tmp/stat_client
    log info "临时文件已清理"
}

# ============================================================
# 主流程
# ============================================================
main() {
    ProbeArch
    GetLatestVersion

    Download
    WriteService "$*"
    EnableService
    Verify
    Cleanup

    log info "===== ServerStatus 客户端安装完成 ====="
}

main "$@"
