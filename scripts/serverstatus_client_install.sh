#!/bin/sh
# ============================================================
# serverstatus_client_install.sh — ServerStatus-Rust 客户端安装脚本
# 架构: 仿 V2 瘦节点风格 — 配置从 ~/.env + ~/node.env 读取
# 生命周期: LoadEnv → Download → Install → WriteService → Enable → Verify
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') [FATAL] 💥 命令失败 — 退出码=${_exit_code}" >> ~/nodeLogs 2>/dev/null || true
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
    echo "$_log_message" >> ~/nodeLogs 2>/dev/null || true
}

die() {
    log error "$*"
    exit 1
}

# ============================================================
# ~/node.env 原子写入
# ============================================================
SetNodeEnv() {
    _key="$1"
    _value="$2"
    _env_file=~/node.env
    _lock_file=/tmp/nodeEnv.lock

    [ -f "$_env_file" ] || touch "$_env_file"

    flock "$_lock_file" sed -i "/^${_key}=/d" "$_env_file" 2>/dev/null || true
    echo "${_key}=\"${_value}\"" >> "$_env_file"
}

# ============================================================
# A. 环境读取
# ============================================================
LoadEnv() {
    log info "===== serverstatus_client_install.sh ${VERSION} 启动 ====="

    # 1. 加载 ~/.env (用户手工只读配置)
    if [ -f ~/.env ]; then
        # shellcheck disable=SC1090
        . ~/.env || die "加载 ~/.env 失败"
        log info "已加载 ~/.env"
    else
        die "~/.env 不存在，请先创建并填入必要配置"
    fi

    # 2. 加载 ~/node.env (脚本自动生成)
    if [ -f ~/node.env ]; then
        # shellcheck disable=SC1090
        . ~/node.env || die "加载 ~/node.env 失败"
        log info "已加载 ~/node.env"
    else
        log warn "~/node.env 不存在，ALIAS 将为空 (需先运行 proxyInstall.sh)"
    fi

    # 必需字段校验
    [ -z "${STAT_API_URL:-}" ]       && die "~/.env 缺少必需字段: STAT_API_URL"
    [ -z "${STAT_API_PASSWORD:-}" ]   && die "~/.env 缺少必需字段: STAT_API_PASSWORD"
    [ -z "${API_PANEL:-}" ]           && die "~/.env 缺少必需字段: API_PANEL"

    case "${API_PANEL}" in
        ssp|srp) ;;
        *) die "API_PANEL 值无效: ${API_PANEL} — 仅支持 ssp 或 srp" ;;
    esac

    # ALIAS = node.env 中的 node_id
    ALIAS="${node_id:-}"
    if [ -z "$ALIAS" ]; then
        die "ALIAS (node_id) 为空 — 请先运行 proxyInstall.sh 注册节点获取 node_id"
    fi
    log info "ALIAS (node_id) = ${ALIAS}"

    STAT_USER="${API_PANEL}"
    # 服务端唯一节点标识: {API_PANEL}_{node_id}
    STAT_NAME="${API_PANEL}_${ALIAS}"

    log info "变量加载完成 — STAT_API_URL=${STAT_API_URL} API_PANEL=${API_PANEL} STAT_USER=${STAT_USER} STAT_NAME=${STAT_NAME}"
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
WriteService() {
    log info "写入 systemd 配置 (版本 ${_latest})"
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
ExecStart=${CLIENT_FILE} -a ${STAT_API_URL} -g ${STAT_USER} -p ${STAT_API_PASSWORD} -u ${STAT_NAME} --alias ${ALIAS} --interval 17
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

    # 记录版本到 ~/node.env
    SetNodeEnv "stat_client_version" "${_latest}"
    log info "版本 ${_latest} 已记录到 ~/node.env"
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
    LoadEnv
    ProbeArch
    GetLatestVersion

    # 幂等检查: 已安装且版本相同则跳过
    if [ -f "$CLIENT_FILE" ]; then
        _installed_version=""
        _installed_version=$(grep -oP '(?<=#Version=)[^\s]+' "$SERVICE_CONF" 2>/dev/null || true)
        if [ "$_installed_version" = "$_latest" ] && systemctl is-active --quiet stat_client 2>/dev/null; then
            log info "stat_client 已安装 (${_installed_version}) 且运行中，跳过安装"
            return 0
        fi
        log info "stat_client 已存在 (版本 ${_installed_version:-未知})，将升级到 ${_latest}"
    fi

    Download
    WriteService
    EnableService
    Verify
    Cleanup

    log info "===== ServerStatus 客户端安装完成 ====="
}

main "$@"
