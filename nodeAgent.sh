#!/bin/sh
# ============================================================
# nodeAgent.sh — V2 瘦节点状态上报脚本
# 职责: 采集网卡原始 rx/tx 字节数 + 服务器运行时间，上报至面板
# 约束: 严禁在节点端进行流量计算、单位换算或清零操作
# ============================================================

set -eu

# ============================================================
# 脚本身份 (供 Telegram 通知标注来源: 脚本路径)
# ============================================================
_SCRIPT_PATH="$0"
_SCRIPT_NAME="${0##*/}"

# ============================================================
# Telegram 通知 — 收敛到 log() 内统一触发
#   * 默认仅 error 等级推送; 通过 .env 设置 TG_NOTIFY_LEVEL 调整
#     可选: debug / info / warn / error (阈值越低越宽松)
#   * 节流: _TG_THROTTLE_SEC 内只推送一次 (防 cron 高频刷屏), 设 0 关闭
#   * 兼容旧版 .env: 未配置 TELEGRAM_BOT_TOKEN / TG_BOT_TOKEN 则静默跳过
#   * 变量优先级: TELEGRAM_BOT_TOKEN > TG_BOT_TOKEN (chat 同理)
# ============================================================
TG_NOTIFY_LEVEL="${TG_NOTIFY_LEVEL:-error}"
_TG_THROTTLE_SEC="${TG_NOTIFY_THROTTLE:-1800}"   # 默认 30 分钟

# 日志等级 → 数值 (便于阈值比较)
_LogLevelNum() {
    case "$1" in
        error) echo 4 ;;
        warn)  echo 3 ;;
        info)  echo 2 ;;
        debug) echo 1 ;;
        *)     echo 0 ;;
    esac
}

# 解析节点 IP (供 Telegram 通知标注来源), 不发起网络请求
_TgNodeIp() {
    for _cand in "${node_ip:-}" "${_ip:-}" "${NODE_IP:-}"; do
        [ -n "$_cand" ] && { echo "$_cand"; return 0; }
    done
    _cand=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$_cand" ] && _cand=$(hostname 2>/dev/null || true)
    [ -z "$_cand" ] && _cand="未知"
    echo "$_cand"
}

# ============================================================
# 日志系统 — 等级 >= TG_NOTIFY_LEVEL (默认 error) 时自动推送 Telegram
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

    # 收敛入口: 等级达标 → 推送 (含 IP / 脚本路径 / 节点ID / 消息)
    if [ "$(_LogLevelNum "$_level")" -ge "$(_LogLevelNum "${TG_NOTIFY_LEVEL:-error}")" ]; then
        NotifyTG "🚨 [NodeHub] ${_SCRIPT_NAME}
节点ID: ${node_id:-${NODE_ID:-N/A}}
IP: $(_TgNodeIp)
脚本: ${_SCRIPT_PATH}
等级: ${_level}
时间: ${_timestamp}
消息: ${_message}"
    fi
}

# NotifyTG — 实际推送 (含节流, 由 log() 在等级达标时调用)
NotifyTG() {
    _tg_token="${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
    _tg_chat="${TELEGRAM_CHAT_ID:-${TG_CHAT_ID:-}}"
    # 兼容旧版 .env: 未配置则静默跳过, 不影响主流程
    [ -z "$_tg_token" ] || [ -z "$_tg_chat" ] && return 0

    # 节流: 标记文件记录上次推送 epoch, 窗口内跳过
    if [ "${_TG_THROTTLE_SEC:-0}" -gt 0 ] 2>/dev/null; then
        _tg_marker="${TMPDIR:-/tmp}/${_SCRIPT_NAME}.tg.throttle"
        _now=$(date +%s)
        _last=$(cat "$_tg_marker" 2>/dev/null || echo 0)
        [ $((_now - _last)) -lt "${_TG_THROTTLE_SEC}" ] && return 0
        echo "$_now" > "$_tg_marker" 2>/dev/null || true
    fi

    curl -sS --connect-timeout 5 --max-time 15 \
        --data-urlencode "chat_id=${_tg_chat}" \
        --data-urlencode "text=$1" \
        "https://api.telegram.org/bot${_tg_token}/sendMessage" >/dev/null 2>&1 || true
}

# ============================================================
# ERR Trap — set -e 未捕获失败时统一走 log error → NotifyTG
# 注意: Main() 正常完成时会 trap - EXIT 清除, 故仅在异常时触发
# ============================================================
OnError() {
    _exit_code=$?
    # 节流会自动去重: 若先前 log error 已推送过, 此处 NotifyTG 在窗口内被跳过
    log error "nodeAgent 异常退出 — 退出码=${_exit_code} (set -e 触发, 未捕获的错误)"
    exit "$_exit_code"
}
trap OnError EXIT

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
    _missing=""
    [ -z "${API_TOKEN:-}" ] && _missing="${_missing}  API_TOKEN       — 面板 API 认证 Token\n"
    [ -z "${API_URL:-}" ]   && _missing="${_missing}  API_URL         — 面板 API 地址\n"
    [ -z "${node_id:-}" ]   && _missing="${_missing}  node_id         — 节点 ID (由 proxyInstall.sh 自动分配)\n"
    if [ -n "$_missing" ]; then
        log error "以下必需环境变量未设置:"
        printf "%b" "$_missing" | while IFS= read -r _line; do log error "$_line"; done
        log error "请在 ~/.env 中配置 API_TOKEN / API_URL"
        log error "node_id 由 proxyInstall.sh 自动写入 ~/node.env"
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
# 同时更新 nodeMonitor.sh (每分钟调度器)
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

    # 同步更新 nodeMonitor.sh (每分钟调度器)
    if wget -N --timeout=30 --tries=1 -O ~/nodeMonitor.sh "${NODEHUB_URL}/nodeMonitor.sh" 2>/dev/null; then
        chmod +x ~/nodeMonitor.sh
        log debug "nodeMonitor.sh 已同步检查"
    fi
}

# ============================================================
# SSL 证书同步 — 每日一次, 从面板拉取最新 root_domain 证书到 /etc/ssl
# 依赖: jq (proxyInstall.sh 安装基线), /etc/ssl 写权限 (root)
# 调度: 仅在每天 03 点执行 (nodeAgent.sh 由 cron 每小时触发)
# 生效: 检测到 .key / .pem 任一被实际更新 → reload nginx + 重启 xray
# ============================================================
SyncSSL() {
    [ -z "${NODEHUB_URL:-}" ] && return 0

    # 1) 每日只在 03 点执行一次 — nodeAgent.sh 由 cron 每小时触发
    [ "$(date '+%H')" = "03" ] || return 0

    # 2) 读取 root_domain — 与 proxyInstall.sh:1236 一致
    if [ ! -f "${HOME}/node.json" ]; then
        log warn "SyncSSL: ~/node.json 不存在, 跳过"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log warn "SyncSSL: jq 不可用, 跳过"
        return 0
    fi
    # jq 解析失败 (如 node.json 临时损坏) 时 || true 防止 set -e 放大为脚本退出
    # 解析失败 → _root_domain 为空 → 落入下方 -z 检查的 warn 分支
    _root_domain=$(jq -r '.root_domain // empty' "${HOME}/node.json" 2>/dev/null || true)
    [ -z "$_root_domain" ] && { log warn "SyncSSL: root_domain 为空或 node.json 解析失败, 跳过"; return 0; }

    # 3) 准备目录与文件路径
    mkdir -p /etc/ssl
    _key_file="/etc/ssl/${_root_domain}.key"
    _pem_file="/etc/ssl/${_root_domain}.pem"
    _updated=0

    log info "SyncSSL: 开始同步 ${_root_domain} 证书"

    # 4) 下载 .key — wget -N 仅在远程更新时实际拉取; 对比前后 mtime 判断是否真有更新
    _key_before=""
    [ -f "$_key_file" ] && _key_before=$(stat -c %Y "$_key_file" 2>/dev/null || echo "")
    if ! wget -N --timeout=30 --tries=1 -P /etc/ssl \
            "${NODEHUB_URL}/ssl/${_root_domain}.key" 2>/dev/null; then
        log warn "SyncSSL: ${_root_domain}.key 下载失败"
        return 0
    fi
    _key_after=$(stat -c %Y "$_key_file" 2>/dev/null || echo "")
    if [ -z "$_key_before" ] || [ "$_key_before" != "$_key_after" ]; then
        _updated=1
        log info "SyncSSL: ${_root_domain}.key 已更新"
    fi

    # 5) 下载 .pem — 同上 mtime 对比
    _pem_before=""
    [ -f "$_pem_file" ] && _pem_before=$(stat -c %Y "$_pem_file" 2>/dev/null || echo "")
    if ! wget -N --timeout=30 --tries=1 -P /etc/ssl \
            "${NODEHUB_URL}/ssl/${_root_domain}.pem" 2>/dev/null; then
        log warn "SyncSSL: ${_root_domain}.pem 下载失败"
        return 0
    fi
    _pem_after=$(stat -c %Y "$_pem_file" 2>/dev/null || echo "")
    if [ -z "$_pem_before" ] || [ "$_pem_before" != "$_pem_after" ]; then
        _updated=1
        log info "SyncSSL: ${_root_domain}.pem 已更新"
    fi

    # 6) 权限收紧 — 私钥必须 600
    chmod 600 "$_key_file" 2>/dev/null || true
    chmod 644 "$_pem_file" 2>/dev/null || true

    # 7) 格式校验 — 镜像 proxyInstall.sh Step1_5_DownloadSSL
    if ! grep -q 'BEGIN CERTIFICATE' "$_pem_file" 2>/dev/null; then
        log error "SyncSSL: ${_root_domain}.pem 不含 CERTIFICATE — 源文件可能损坏"
        return 0
    fi
    if ! grep -q 'PRIVATE KEY' "$_key_file" 2>/dev/null; then
        log error "SyncSSL: ${_root_domain}.key 不含 PRIVATE KEY — 源文件可能损坏"
        return 0
    fi

    # 8) 全部通过
    log info "SyncSSL: ${_root_domain} 证书同步完成 (updated=${_updated})"

    # 9) 检测到更新 → reload nginx + 重启 xray, 让新证书生效
    if [ "$_updated" = "1" ]; then
        log info "SyncSSL: 检测到证书更新, 重载服务"

        # nginx: 先 -t 校验配置, 再 -s reload (graceful, 不断连)
        if command -v nginx >/dev/null 2>&1; then
            if nginx -t 2>/dev/null; then
                if nginx -s reload 2>/dev/null; then
                    log info "SyncSSL: nginx 已 reload"
                else
                    log warn "SyncSSL: nginx reload 失败"
                fi
            else
                log warn "SyncSSL: nginx -t 配置校验失败, 跳过 reload"
            fi
        else
            log debug "SyncSSL: nginx 未安装, 跳过 reload"
        fi

        # xray: 优先 reload (SIGHUP 热重载, 不断连); 旧版 xray.service 未定义 ExecReload 时 reload 会失败, 回退 restart
        if command -v systemctl >/dev/null 2>&1 \
            && systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service'; then
            if systemctl reload xray 2>/dev/null; then
                log info "SyncSSL: xray 已 reload"
            else
                log warn "SyncSSL: xray reload 失败 (旧版 xray.service 可能未定义 ExecReload), 回退 restart"
                if systemctl restart xray 2>/dev/null; then
                    log info "SyncSSL: xray 已 restart"
                else
                    log warn "SyncSSL: xray restart 也失败"
                fi
            fi
        else
            log debug "SyncSSL: xray.service 未发现, 跳过"
        fi
    fi
}

# ============================================================
# 一次性补丁 (2026-07-09): ayjx.top 域名失效, 检测后重装
# 约束: 仅在 2026-07-09 当天运行, 且仅运行一次
# ============================================================
PatchAyjxDomainReinstall() {
    # 1) 仅运行一次 — 标记文件存在则跳过
    _marker="${HOME}/nodeAgent.ayxj.patch.done"
    [ -f "$_marker" ] && return 0

    # 先落标记, 防止重装过程中重入导致重复执行
    : > "$_marker"

    # 2) 检测 ~/node.json 是否存在失效域名 ayxj.top
    if [ -f "${HOME}/node.json" ] && grep -q "ayxj.top" "${HOME}/node.json" 2>/dev/null; then
        log warn "检测到失效域名 ayxj.top, 触发重装以更换域名"
        cd /tmp || { log error "进入 /tmp 失败"; return 0; }
        if wget -N "https://hajimi:kawayi@kod.freessr.bid/node_hub/proxyInstall.sh" 2>/dev/null; then
            log info "proxyInstall.sh 下载完成, 开始执行重装"
            sh proxyInstall.sh || log warn "proxyInstall.sh 执行返回非零"
        else
            log error "下载 proxyInstall.sh 失败"
        fi
    else
        log debug "未检测到 ayxj.top, 跳过重装补丁"
    fi

    return 0
}

# ============================================================
# 一次性补丁 (2026-07-17): sspcccdn.xyz 域名失效, 检测后重装
# 约束: 仅在 2026-07-17 当天运行, 且仅运行一次
# ============================================================
PatchSspcccdnDomainReinstall() {
    # 1) 仅运行一次 — 标记文件存在则跳过
    _marker="${HOME}/nodeAgent.sspcccdn.patch.done"
    [ -f "$_marker" ] && return 0

    # 先落标记, 防止重装过程中重入导致重复执行
    : > "$_marker"

    # 2) 检测 ~/node.json 中 root_domain 是否为失效域名 sspcccdn.xyz
    if [ -f "${HOME}/node.json" ] && grep -q '"root_domain"[[:space:]]*:[[:space:]]*"sspcccdn.xyz"' "${HOME}/node.json" 2>/dev/null; then
        log warn "检测到失效域名 sspcccdn.xyz, 触发重装以更换域名"
        cd /tmp || { log error "进入 /tmp 失败"; return 0; }
        if wget -N "https://hajimi:kawayi@kod.freessr.bid/node_hub/proxyInstall.sh" 2>/dev/null; then
            log info "proxyInstall.sh 下载完成, 开始执行重装"
            sh proxyInstall.sh || log warn "proxyInstall.sh 执行返回非零"
        else
            log error "下载 proxyInstall.sh 失败"
        fi
    else
        log debug "未检测到 sspcccdn.xyz, 跳过重装补丁"
    fi

    return 0
}

# ============================================================
# 补丁调度器 — 集中管理所有一次性补丁 (日期窗口在此统一调度)
# 新增补丁只需追加一行, 无需改动 Main
# 过时补丁直接注释整行即可注销
# 各 Patch* 函数仅负责 "一次性标记 + 条件检测"
# ============================================================
RunPatches() {
    _today=$(date '+%Y-%m-%d')

    # 日期 → 补丁 映射; 每行独立, 过时直接注释整行即可
    # [ "$_today" = "2026-07-09" ] && PatchAyjxDomainReinstall
    [ "$_today" = "2026-07-17" ] && PatchSspcccdnDomainReinstall
}

# ============================================================
# 主流程
# ============================================================
Main() {
    LoadEnv
    CollectRawTraffic
    SubmitStatus
    SelfUpdate
    SyncSSL
    RunPatches
    trap - EXIT   # 成功完成, 清除错误捕获, 避免误触发 NotifyTG
}

Main "$@"
