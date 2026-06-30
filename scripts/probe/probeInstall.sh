#!/bin/sh
# ============================================================
# probeInstall.sh — Probe (被墙原因采集系统) 独立安装器
#
# 职责: 部署 probe 全部组件到本节点:
#   - probeTask.sh + probeHelper.py → ~/  (从 ${NODEHUB_URL}/scripts/probe/ 下载)
#   - MONITOR_INGEST_URL / MONITOR_INGEST_TOKEN / ENABLE_JA3 → ~/.env
#   - probe_collect_phase (0-14) → ~/node.env
#   - xray-access logrotate (heredoc 内联生成) → /etc/logrotate.d/
#
# 配置来源 (优先级): 环境变量 > ~/.env (已存在则读)
#   NODEHUB_URL          — 资源下载地址 (必需)
#   MONITOR_INGEST_URL   — 探针接收地址 (必需)
#   MONITOR_INGEST_TOKEN — 接收端鉴权 token (必需)
#   ENABLE_JA3           — 是否采 ClientHello (可选, 节点端默认 1)
#   IS_NEW_VPS_INSTALL   — 全新安装标志 (proxyInstall 传入; =false 时跳过)
#
# 调用方:
#   1. proxyInstall.sh Step4_6 nohup 后台调用 (仅全新安装)
#   2. 手动单独安装: sh probeInstall.sh (IS_NEW_VPS_INSTALL 默认视为 true)
#
# 不读节点 ~/.env 的业务配置, 不碰 stat_client / xray / nginx
# ============================================================

set -eu

VERSION="v1.1.0-20260630"

# ============================================================
# 日志
# ============================================================
log() {
    _lvl="$1"; shift
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    _emoji=""
    case "$_lvl" in
        error) _emoji="❌" ;;
        warn)  _emoji="⚠️" ;;
        info)  _emoji="ℹ️" ;;
        debug) _emoji="🐛" ;;
        *)     _emoji="📝" ;;
    esac
    printf '%s [%s] %s %s\n' "$_ts" "$_lvl" "$_emoji" "$*"
}

die() { log error "$*"; exit 1; }

# ============================================================
# 原子写入 env 文件 (flock 防并发, sed 删旧 + append 新)
# ============================================================
SetEnv() {
    _file="$1"; _key="$2"; _val="$3"
    [ -f "$_file" ] || touch "$_file"
    ( flock 9
      sed -i "/^${_key}=/d" "$_file" 2>/dev/null || true
      echo "${_key}=\"${_val}\"" >> "$_file"
    ) 9>/tmp/envWrite.lock
}

# ============================================================
# A. Gate — 全新安装标志 + 必需配置校验
# ============================================================
Gate() {
    # IS_NEW_VPS_INSTALL: 仅 proxyInstall 显式传 false 时跳过 (单独运行默认继续)
    if [ "${IS_NEW_VPS_INSTALL:-true}" = "false" ]; then
        log info "IS_NEW_VPS_INSTALL=false (重复安装), 跳过 probe 部署"
        exit 0
    fi

    # 读已存在的 ~/.env 作为配置默认值 (单独运行时从这取 MONITOR_*)
    [ -f ~/.env ] && . ~/.env || true

    # 兼容老变量名 MONITOR_TOKEN (老 probeReporter.sh 用), 统一到 MONITOR_INGEST_TOKEN
    MONITOR_INGEST_TOKEN="${MONITOR_INGEST_TOKEN:-${MONITOR_TOKEN:-}}"

    # 必需: NODEHUB_URL (下载资源)
    [ -z "${NODEHUB_URL:-}" ] && die "缺少 NODEHUB_URL (probe 资源下载地址)"

    # 必需: MONITOR_INGEST_URL + MONITOR_INGEST_TOKEN
    if [ -z "${MONITOR_INGEST_URL:-}" ] || [ -z "${MONITOR_INGEST_TOKEN:-}" ]; then
        die "缺少 MONITOR_INGEST_URL / MONITOR_INGEST_TOKEN (部署机 .env 或环境变量提供)"
    fi

    log info "Gate 通过: NODEHUB_URL=${NODEHUB_URL} MONITOR_INGEST_URL=${MONITOR_INGEST_URL} ENABLE_JA3=${ENABLE_JA3:-默认1}"
}

# ============================================================
# B. 下载 probeTask.sh + probeHelper.py (原子 tmp+mv, 失败不残留)
# ============================================================
DownloadFiles() {
    # 源文件在 NODEHUB_URL/scripts/probe/ 下 (与 probeInstall.sh 同目录)
    for _f in probeTask.sh probeHelper.py; do
        if wget -q --timeout=60 --tries=2 -O "/tmp/${_f}.new" "${NODEHUB_URL}/scripts/probe/${_f}" 2>/dev/null \
           && [ -s "/tmp/${_f}.new" ]; then
            mv -f "/tmp/${_f}.new" ~/"$_f"
            chmod +x ~/"$_f" 2>/dev/null || true
            log info "已下载: ~/${_f}"
        else
            rm -f "/tmp/${_f}.new" 2>/dev/null || true
            die "下载失败: ${NODEHUB_URL}/scripts/probe/${_f}"
        fi
    done
}

# ============================================================
# C. 写入 MONITOR_* → ~/.env
# ============================================================
WriteMonitorEnv() {
    SetEnv ~/.env "MONITOR_INGEST_URL"  "${MONITOR_INGEST_URL}"
    SetEnv ~/.env "MONITOR_INGEST_TOKEN" "${MONITOR_INGEST_TOKEN}"
    # ENABLE_JA3 仅显式配置时写 (不写则节点端 probeTask 默认 1)
    [ -n "${ENABLE_JA3:-}" ] && SetEnv ~/.env "ENABLE_JA3" "${ENABLE_JA3}"
    log info "MONITOR_INGEST_URL / MONITOR_INGEST_TOKEN 已写入 ~/.env"
}

# ============================================================
# D. 写入 probe_collect_phase (0-14) → ~/node.env
#    用当前分钟 % 15 作相位, 节点间错峰 (每节点固定一个值)
# ============================================================
WritePhase() {
    _m=$(date +%M | sed 's/^0//'); [ -z "$_m" ] && _m=0
    _phase=$(( _m % 15 ))
    SetEnv ~/node.env "probe_collect_phase" "$_phase"
    log info "probe_collect_phase=${_phase} 已写入 ~/node.env"
}

# ============================================================
# E. 部署 xray access.log logrotate (heredoc 内联生成, 无需独立文件/下载)
#    控制 access.log 磁盘: 每日轮转/留3份/上限100M/copytruncate
# ============================================================
DeployLogrotate() {
    mkdir -p /etc/logrotate.d 2>/dev/null || true
    cat > /etc/logrotate.d/xray-access <<'LOGROTATE_EOF'
# 由 probeInstall.sh 生成 — 控制 xray access.log 磁盘占用
/var/log/xray/access.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    maxsize 100M
    create 0644 root root
}
LOGROTATE_EOF
    if [ -f /etc/logrotate.d/xray-access ]; then
        log info "xray-access logrotate 已生成到 /etc/logrotate.d/"
    else
        log warn "xray-access logrotate 生成失败 (非致命)"
    fi
}

# ============================================================
# 主流程
# ============================================================
log "===== probeInstall.sh v${VERSION} 开始 ====="

Gate
DownloadFiles
WriteMonitorEnv
WritePhase
DeployLogrotate

log "===== probe 安装完成 (采集由 nodeMonitor.sh 每 15 分钟调度) ====="
