#!/bin/sh
# ============================================================
# nodeAgent.sh — V2 瘦节点状态上报脚本
# 职责: 采集网卡原始 rx/tx 字节数 + 服务器运行时间，上报至面板
# 约束: 严禁在节点端进行流量计算、单位换算或清零操作
# ============================================================

set -eu

# ============================================================
# 日志系统
# ============================================================
log() {
    _level="$1"
    shift
    _message="$*"
    _timestamp=$(date '+%Y-%m-%d %H-%M-%S')
    _color_code="" _emoji=""

    case "$_level" in
        error) _color_code="\033[31m"; _emoji="❌" ;;
        warn)  _color_code="\033[33m"; _emoji="⚠️" ;;
        info)  _color_code="\033[32m"; _emoji="ℹ️" ;;
        debug) _color_code="\033[36m"; _emoji="🐛" ;;
        *)     _color_code="\033[0m";  _emoji="📝" ;;
    esac

    _log_message="${_timestamp} [${_level}] ${_emoji} ${_message}"
    printf '%b%s%b\n' "$_color_code" "$_log_message" "\033[0m"
    echo "$_log_message" >> ~/nodeLogs
}

# ============================================================
# 环境加载
# ============================================================
LoadEnv() {
    # ~/.env — 用户手工只读配置
    if [ -f ~/.env ]; then
        # shellcheck disable=SC1090
        . ~/.env || { log error "加载 ~/.env 失败"; return 1; }
    else
        log error "~/.env 不存在"
        return 1
    fi

    # ~/node.env — API 分配的可变配置
    if [ -f ~/node.env ]; then
        # shellcheck disable=SC1090
        . ~/node.env || { log error "加载 ~/node.env 失败"; return 1; }
    fi

    # 必需字段
    if [ -z "${API_TOKEN:-}" ]; then
        log error "~/.env 缺少 API_TOKEN"
        return 1
    fi
    if [ -z "${API_URL:-}" ]; then
        log error "~/.env 缺少 API_URL"
        return 1
    fi
    if [ -z "${node_id:-}" ]; then
        log error "~/node.env 缺少 node_id，请先运行 proxyInstall.sh"
        return 1
    fi

    # URL 标准化
    case "$API_URL" in
        http*) ;;
        *) API_URL="https://${API_URL}" ;;
    esac

    # 默认网卡
    net_card="${net_card:-eth0}"
}

# ============================================================
# 数据采集 — 原始值，不做任何运算
# ============================================================
CollectRawTraffic() {
    rx_file="/sys/class/net/${net_card}/statistics/rx_bytes"
    tx_file="/sys/class/net/${net_card}/statistics/tx_bytes"

    if [ ! -f "$rx_file" ]; then
        log error "网卡 ${net_card} 的 rx_bytes 文件不存在: ${rx_file}"
        return 1
    fi
    if [ ! -f "$tx_file" ]; then
        log error "网卡 ${net_card} 的 tx_bytes 文件不存在: ${tx_file}"
        return 1
    fi

    # 读取原始字节数 — 直接读取，不做任何换算
    RAW_RX=$(cat "$rx_file")
    RAW_TX=$(cat "$tx_file")

    # 读取服务器运行时间（秒）— 取 /proc/uptime 第一列的整数部分
    SERVER_UPTIME=$(awk '{print int($1)}' /proc/uptime)

    log debug "采集完成 — raw_rx=${RAW_RX} raw_tx=${RAW_TX} uptime=${SERVER_UPTIME}"
}

# ============================================================
# 数据上报 — application/x-www-form-urlencoded
# ============================================================
SubmitStatus() {
    url="${API_URL}/api/node/status"

    # 严格遵循参数格式: token=xxx&node_id=xxx&raw_rx=xxx&raw_tx=xxx&server_uptime=xxx
    node_bandwidth="${monitor_max_mbps:-0}"

    data="token=${API_TOKEN}&node_id=${node_id}&raw_rx=${RAW_RX}&raw_tx=${RAW_TX}&server_uptime=${SERVER_UPTIME}&node_bandwidth=${node_bandwidth}"

    log debug "上报: ${url} — raw_rx=${RAW_RX} raw_tx=${RAW_TX} uptime=${SERVER_UPTIME} bandwidth=${node_bandwidth}"

    response=$(curl -sS --connect-timeout 30 --max-time 120 \
        --retry 3 \
        --retry-delay 2 \
        --retry-max-time 180 \
        --retry-all-errors \
        -w "\n%{http_code}" \
        -X POST \
        -d "$data" \
        "$url" 2>&1) || true

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        log debug "上报成功 — $(printf '%.200s' "$body")"
        echo "$body" > ~/status.json
        log debug "返回数据已保存到 ~/status.json"
    else
        log warn "上报失败 — HTTP ${http_code} — $(printf '%.200s' "$body")"
    fi
}

# ============================================================
# 自更新 — wget -N 仅在远程文件更新时才下载
# ============================================================
SelfUpdate() {
    [ -z "${NODEHUB_URL:-}" ] && return 0

    self_path="$(readlink -f "$0")"
    remote_url="${NODEHUB_URL}/nodeAgent.sh"

    log debug "检查自更新: ${remote_url}"

    if wget -N --timeout=30 --tries=1 -O "${self_path}" "$remote_url" 2>/dev/null; then
        chmod +x "${self_path}"
        log info "自更新完成: ${self_path}"
    else
        log warn "自更新失败: ${remote_url}"
    fi
}

# ============================================================
# 主流程
# ============================================================
Main() {
    LoadEnv
    CollectRawTraffic
    SubmitStatus
    SelfUpdate
}

Main "$@"
