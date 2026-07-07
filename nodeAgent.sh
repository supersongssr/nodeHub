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
# 同时更新 nodeMonitor.sh (probe 自更新机制的前提, 见 nodeMonitor RunScheduledTasks)
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

    # 同步更新 nodeMonitor.sh (每分钟调度器; 含 probeTask 自更新逻辑)
    if wget -N --timeout=30 --tries=1 -O ~/nodeMonitor.sh "${NODEHUB_URL}/nodeMonitor.sh" 2>/dev/null; then
        chmod +x ~/nodeMonitor.sh
        log debug "nodeMonitor.sh 已同步检查"
    fi
}

# ============================================================
# 一次性补丁 — 更新 xray core 到 v26.6.27
# 约束:
#   1. 仅在 2026-07-07 当天运行 (日期硬限制)
#   2. 每个节点只执行一次 (flag 文件幂等)
# 投递方式: 依靠 SelfUpdate 拉取新版 nodeAgent.sh, 下一次 cron 触发时执行
# 参考: proxyInstall.sh Step3_InstallXray 的 xray 内核安装方法
# ============================================================
Patch_XrayCore_v26_6_27() {
    # 1. 日期硬限制 — 仅 2026-07-07 运行 (其余日期静默跳过)
    _today=$(date '+%Y-%m-%d')
    if [ "$_today" != "2026-07-07" ]; then
        return 0
    fi

    # 2. 幂等 — flag 文件存在则跳过 (当天只执行一次)
    _patch_flag=~/patch_xray_v26.6.27.done
    if [ -f "$_patch_flag" ]; then
        return 0
    fi

    # 3. 依赖检查 — NODEHUB_URL 必须存在 (由 SelfUpdate 同样依赖)
    if [ -z "${NODEHUB_URL:-}" ]; then
        log warn "补丁: NODEHUB_URL 未设置, 跳过 xray core 更新"
        return 0
    fi

    # 4. 按面板类型确定内核文件名 (与 proxyInstall.sh Step3_InstallXray 一致)
    _xray_bin_name=""
    case "${API_PANEL:-}" in
        ssp) _xray_bin_name="xray-plugin-ssp-v26.6.27" ;;
        srp) _xray_bin_name="xray-plugin-srp-v26.6.27" ;;
        *)
            log warn "补丁: API_PANEL=${API_PANEL:-空} 非法, 跳过 xray core 更新"
            return 0
            ;;
    esac

    _xray_url="${NODEHUB_URL}/xray/${_xray_bin_name}"
    _xray_bin_path="/usr/local/bin/xray"

    log info "补丁启动: 更新 xray core → ${_xray_bin_name}"

    # 5. 下载内核 (wget -N 跳过已下载的同名文件)
    log info "补丁: 下载 xray 内核 ${_xray_bin_name}..."
    if ! wget -N --timeout=60 --tries=3 -P /tmp "$_xray_url" 2>/dev/null; then
        log error "补丁: xray 内核下载失败: ${_xray_url}"
        return 0
    fi

    # 6. 校验下载文件非空 (防空文件覆盖导致内核损坏)
    if [ ! -s "/tmp/${_xray_bin_name}" ]; then
        log error "补丁: 下载的 xray 内核为空, 跳过更新"
        return 0
    fi

    # 7. 备份当前内核 (便于回滚)
    if [ -f "$_xray_bin_path" ]; then
        cp -f "$_xray_bin_path" "${_xray_bin_path}.bak"
    fi

    # 8. 覆盖安装
    cp -f "/tmp/${_xray_bin_name}" "$_xray_bin_path"
    chmod +x "$_xray_bin_path"

    # 9. 校验新内核可执行, 失败则回滚到备份
    #    (部分定制内核会先向 stdout 输出 Debug 行, 故优先取 "Xray x.y.z" 版本行)
    _xray_out=""
    _xray_out=$("$_xray_bin_path" version 2>/dev/null) || true
    if [ -z "$_xray_out" ]; then
        log error "补丁: 新 xray 内核无法运行, 回滚到备份"
        if [ -f "${_xray_bin_path}.bak" ]; then
            cp -f "${_xray_bin_path}.bak" "$_xray_bin_path"
        fi
        return 0
    fi
    _xray_ver=""
    _xray_ver=$(echo "$_xray_out" | grep -E '^Xray [0-9]' | head -1) || true
    if [ -z "$_xray_ver" ]; then
        _xray_ver=$(echo "$_xray_out" | head -1)
    fi
    log info "补丁: xray 内核已更新并校验通过 — ${_xray_ver}"

    # 10. 重启 xray 服务 (不因重启失败而中断 agent)
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl restart xray 2>/dev/null; then
            sleep 2
            _st=""
            _st=$(systemctl is-active xray 2>/dev/null) || true
            if [ "$_st" = "active" ]; then
                log info "补丁: xray 服务已重启并运行正常"
            else
                log warn "补丁: xray 已重启但状态异常: ${_st:-未知}"
            fi
        else
            log error "补丁: xray 重启失败"
        fi
    else
        log warn "补丁: systemctl 不可用, 请手动重启 xray"
    fi

    # 11. 写入完成标记 (幂等, 当天后续 cron 触发直接跳过)
    echo "$(date '+%Y-%m-%d %H:%M:%S') xray core 更新为 ${_xray_bin_name} (${_xray_ver})" > "$_patch_flag"
    log info "补丁完成: xray core 已更新到 ${_xray_bin_name}"
}

# ============================================================
# 主流程
# ============================================================
Main() {
    LoadEnv
    CollectRawTraffic
    SubmitStatus
    SelfUpdate
    Patch_XrayCore_v26_6_27
}

Main "$@"
