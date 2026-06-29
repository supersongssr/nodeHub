#!/bin/sh
# ============================================================
# probeTask.sh — 探针/握手/JA3 采集上报 (被墙原因分析系统)
#
# 职责: 采集本节点入站连接/握手/ClientHello, 上报监控端独立接收服务
# 仅 group(动态)节点启用: 检测 stat_client.service 含 -g 参数
#
# 调用方: nodeMonitor.sh 每 15 分钟 (相位调度) 后台触发, 不单独写 crontab
# 上报目标: ${MONITOR_INGEST_URL}/ingest/probe (MONITOR_INGEST_TOKEN 鉴权)
#
# 支持独立运行: sh ~/probeTask.sh (调试用, 输出直接到终端)
# ============================================================

VERSION="v1.0.1-20260629"

# ============================================================
# 环境加载
# ============================================================
[ -f ~/.env ] && . ~/.env || true
[ -f ~/node.env ] && . ~/node.env || true

# ============================================================
# 日志 (stdout 由调用方 nodeMonitor 重定向到 ~/probeLogs)
# ============================================================
plog() {
    _lvl="$1"; shift
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$_lvl" in
        error) _emoji="❌" ;;
        warn)  _emoji="⚠️" ;;
        info)  _emoji="ℹ️" ;;
        debug) _emoji="🐛" ;;
        *)     _emoji="📝" ;;
    esac
    printf '%s [%s] %s %s\n' "$_ts" "$_lvl" "$_emoji" "$*"
}

# ============================================================
# 动态节点判定 — stat_client 服务带 -g (group 模式)
# 固定节点 (user 模式无 -g) 直接退出, 不采集
# ============================================================
IsDynamicNode() {
    _svc=/etc/systemd/system/stat_client.service
    [ -f "$_svc" ] || return 1
    grep -qE -- '( -g |--group )' "$_svc" 2>/dev/null
}

# ============================================================
# 确保 xray 开 access.log (面板模板默认 loglevel=error, 不会写 access.log)
# 幂等: 仅当 loglevel != info 或缺 access 路径时改; 仅运行时配置变更才重启 xray
# ============================================================
EnsureXrayAccessLog() {
    command -v jq >/dev/null 2>&1 || return 0
    mkdir -p /var/log/xray 2>/dev/null || true
    _restart=0
    _access_path="/var/log/xray/access.log"
    for _f in /usr/local/etc/xray/config.json /var/www/SPanel/resources/templates/xray/xhttp.json; do
        [ -f "$_f" ] || continue
        _before=$(jq -c '.log // {}' "$_f" 2>/dev/null || echo "{}")
        jq --arg p "$_access_path" '.log = (.log // {}) | .log.loglevel = "info" | .log.access = (.log.access // $p)' \
            "$_f" > "${_f}.tmp" 2>/dev/null || { rm -f "${_f}.tmp"; continue; }
        [ -s "${_f}.tmp" ] || { rm -f "${_f}.tmp"; continue; }
        _after=$(jq -c '.log // {}' "${_f}.tmp" 2>/dev/null || echo "{}")
        if [ "$_before" != "$_after" ]; then
            mv -f "${_f}.tmp" "$_f"
            [ "$_f" = "/usr/local/etc/xray/config.json" ] && _restart=1
            plog info "xray log 已修正: $_f (loglevel→info, access→${_access_path})"
        else
            rm -f "${_f}.tmp"
        fi
    done
    if [ "$_restart" = "1" ]; then
        if systemctl restart xray 2>/dev/null; then
            plog info "xray 已重启 (log 配置变更生效)"
        else
            plog warn "xray 重启失败 (配置已改, 下次 xray 自启时生效)"
        fi
    fi
}

# ============================================================
# node.json 元数据加载 — v2_name 仅存在于 node.json (非 .env/node.env)
# node_id/node_port 已由 node.env 提供, 此处仅补 v2_name (幂等: env 已有则不覆盖)
# ============================================================
LoadNodeMeta() {
    [ -n "${v2_name:-${V2_NAME:-}}" ] && return 0
    [ -f ~/node.json ] || return 0
    if command -v jq >/dev/null 2>&1; then
        v2_name=$(jq -r '.v2_name // empty' ~/node.json 2>/dev/null || true)
    elif command -v python3 >/dev/null 2>&1; then
        v2_name=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/node.json'))).get('v2_name','') or '')" 2>/dev/null || true)
    fi
}

# ============================================================
# 采集 M1/M2/M9: 入站连接 + 源IP + 出站字节增量 (按 node_port, 不硬编码 443)
# ============================================================
CollectConns() {
    _port="${node_port:-443}"
    _ss_out=$(ss -tnH state established "( sport = :${_port} )" 2>/dev/null || true)
    _conns=$(printf '%s\n' "$_ss_out" | grep -c . || true)
    [ -z "$_conns" ] && _conns=0

    _src_ips=$(printf '%s\n' "$_ss_out" | awk '{print $4}' \
        | sed -E 's/^\[?([0-9a-fA-F:.]+)\]?:[0-9]+$/\1/' \
        | sort -u | head -50 | tr '\n' ',' | sed 's/,$//')

    # 出站字节增量; 网卡校验, 缺失记 warn 不静默归零误导
    _card="${net_card:-eth0}"
    _rx_f="/sys/class/net/${_card}/statistics/rx_bytes"
    _tx_f="/sys/class/net/${_card}/statistics/tx_bytes"
    _bytes_now=0
    if [ -r "$_rx_f" ] && [ -r "$_tx_f" ]; then
        _bytes_now=$(( $(cat "$_rx_f") + $(cat "$_tx_f") ))
    else
        plog warn "网卡 ${_card} 统计文件不可读, bytes_delta=0"
    fi
    _bytes_delta=0
    if [ -f ~/probe.bytes_last ]; then
        _bytes_last=$(cat ~/probe.bytes_last 2>/dev/null || echo 0)
        _bytes_delta=$((_bytes_now - _bytes_last))
        [ "$_bytes_delta" -lt 0 ] && _bytes_delta=0
    fi
    # 不写 ~/probe.bytes_last — 提交成功后才写 (CommitState), 避免上报失败丢窗口
}

# ============================================================
# 采集 M3/M4/M5: xray 握手统计 (从 access.log 增量窗口, 已读偏移)
# ============================================================
CollectHandshake() {
    _hs_ok=0; _hs_fail=0; _rejected_sni=0; _new_size=0
    _log=/var/log/xray/access.log
    [ -f "$_log" ] || { plog debug "xray access.log 不存在, 跳过握手统计"; return 0; }

    _last_offset=$(cat ~/probe.hs_offset 2>/dev/null || echo 0)
    _new_block=$(tail -c +$((_last_offset + 1)) "$_log" 2>/dev/null || true)
    _new_size=$(wc -c < "$_log" 2>/dev/null || echo 0)

    _hs_ok=$(printf '%s\n' "$_new_block" | grep -c "accepted" || true)
    _hs_fail=$(printf '%s\n' "$_new_block" | grep -ciE "rejected|handshake fail|invalid" || true)
    _rejected_sni=$(printf '%s\n' "$_new_block" | grep -ciE "unknown sni|reject" || true)
    # 不写 offset — 提交成功后才写
}

# ============================================================
# 采集 M6/M7/M8: ClientHello (tcpdump 30秒 + python 解析; 按 node_port)
# 默认 ENABLE_JA3=1 (启用); 仅 ENABLE_JA3=0 时跳过
# ============================================================
CollectClientHello() {
    _ch_hex=""
    [ "${ENABLE_JA3:-1}" = "1" ] || return 0
    command -v tcpdump >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    _port="${node_port:-443}"
    _pcap=/tmp/probe_ch_$$.pcap
    _helper=~/probeHelper.py
    [ -f "$_helper" ] || return 0

    # BPF: 仅抓入站 node_port 的 ClientHello; -c 100 上限; 30 秒窗口
    tcpdump -i any -c 100 -s 65535 -w "$_pcap" \
        "tcp dst port ${_port} and tcp[(tcp[12]&0xf0)>>2:1] = 0x16 and tcp[((tcp[12]&0xf0)>>2)+5:1] = 0x01" \
        >/dev/null 2>&1 &
    _tcpid=$!
    sleep 30
    kill "$_tcpid" 2>/dev/null || true
    wait "$_tcpid" 2>/dev/null || true

    if [ -s "$_pcap" ]; then
        _ch_hex=$(python3 "$_helper" parse "$_pcap" 100 2>/dev/null \
            | awk -F'\t' 'NF>=2{print $2}' | tr '\n' ',' | sed 's/,$//' || true)
    fi
    rm -f "$_pcap"
}

# ============================================================
# 提交成功后才推进本地状态 (修复: 上报失败不丢窗口)
# ============================================================
CommitState() {
    echo "$_bytes_now" > ~/probe.bytes_last
    echo "$_new_size"  > ~/probe.hs_offset
    date +%s          > ~/probe.hs_last_ts
}

# ============================================================
# 上报 — v2_name 用 jq @uri 编码 (避免 &/= 破坏 form body); ch_hex/src_ips 为安全字符不编码
# ============================================================
Submit() {
    _NODE_ID="${node_id:-${NODE_ID:-}}"
    _V2_NAME="${v2_name:-${V2_NAME:-}}"
    [ -z "$_NODE_ID" ] && { plog warn "node_id 缺失, 跳过上报"; return 0; }

    # v2_name URL 编码 (jq 优先, 无 jq 则 sed fallback)
    if command -v jq >/dev/null 2>&1 && [ -n "$_V2_NAME" ]; then
        _v2_enc=$(printf '%s' "$_V2_NAME" | jq -sRr @uri 2>/dev/null || printf '%s' "$_V2_NAME")
    else
        _v2_enc=$(printf '%s' "$_V2_NAME" | sed 's/%/%25/g; s/&/%26/g; s/=/%3D/g; s/+/%2B/g; s/ /%20/g')
    fi

    _ts=$(date +%s)
    # 走 stdin (--data @-) 避免 ch_hex 过大触发 ARG_MAX
    _body="token=${MONITOR_INGEST_TOKEN}&node_id=${_NODE_ID}&v2_name=${_v2_enc}&ts=${_ts}"
    _body="${_body}&conns=${_conns}&src_ips=${_src_ips}&hs_ok=${_hs_ok}"
    _body="${_body}&hs_fail=${_hs_fail}&rejected_sni=${_rejected_sni}&ch_hex=${_ch_hex}"
    _body="${_body}&bytes_delta=${_bytes_delta}&reporter_ver=${VERSION}"

    _resp=$(printf '%s' "$_body" | curl -sS --connect-timeout 15 --max-time 40 --retry 2 \
        -w "\n%{http_code}" -X POST --data @- \
        -H "Content-Type: application/x-www-form-urlencoded" \
        "${MONITOR_INGEST_URL}/ingest/probe" 2>&1) || true
    _http=$(printf '%s\n' "$_resp" | tail -1)

    if [ "$_http" = "200" ]; then
        CommitState
        _ch_n=$(printf '%s' "$_ch_hex" | tr ',' '\n' | grep -c . || true)
        plog info "上报成功: conns=${_conns} hs_ok=${_hs_ok} hs_fail=${_hs_fail} ch=${_ch_n} bytesΔ=${_bytes_delta}"
    else
        # 状态未提交 → 下次窗口从原 offset 重读, 不丢数据
        plog warn "上报失败 HTTP=${_http} (状态未提交, 下次重试)"
    fi
}

# ============================================================
# 主流程
# ============================================================
Main() {
    # 必需配置校验
    { [ -z "${MONITOR_INGEST_URL:-}" ] || [ -z "${MONITOR_INGEST_TOKEN:-}" ]; } && {
        plog debug "MONITOR_INGEST_URL/MONITOR_INGEST_TOKEN 未配置, 跳过"; return 0; }
    # 仅动态节点采集
    IsDynamicNode || { plog debug "非 group 节点, 跳过"; return 0; }

    LoadNodeMeta
    EnsureXrayAccessLog
    CollectConns
    CollectHandshake
    CollectClientHello
    Submit
}

Main "$@"
