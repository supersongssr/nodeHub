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
# v1.1.0 变更 (2026-06-30):
#   - 按协议分两条握手采集路径:
#     * vision/reality → xray access.log (xray 直接处理 TLS, 探针失败在 xray)
#     * xhttp          → nginx access.log (GFW 不知道路径 → nginx 回落 → 不到 xray)
#   - 新增 fail_src_ips: 提取失败连接源 IP, 服务端判 CN → cn_fail_conns (权威探针指标)
#   - logrotate 安全: offset > 文件大小时自动重置 (修复轮转后丢窗口)
#   - 增加诊断日志 (增量行数 / 路径命中 / 偏移重置)
#
# 支持独立运行: sh ~/probeTask.sh (调试用, 输出直接到终端)
# ============================================================

VERSION="v1.1.0-20260630"

# ============================================================
# 环境加载
# ============================================================
[ -f ~/.env ] && . ~/.env || true
[ -f ~/node.env ] && . ~/node.env || true
# 兼容老变量名 MONITOR_TOKEN (老 probeReporter.sh 用), 统一到 MONITOR_INGEST_TOKEN
MONITOR_INGEST_TOKEN="${MONITOR_INGEST_TOKEN:-${MONITOR_TOKEN:-}}"

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
# 传输模式判定 (从 v2_name)
#   xhttp*    → nginx 前置 (探针死在 nginx)
#   vision*/reality* → xray 前置 (探针死在 xray)
# 输出: _TRANSPORT_MODE = "xhttp" | "xray"
# ============================================================
DetectTransportMode() {
    _v2="${v2_name:-${V2_NAME:-}}"
    case "$_v2" in
        *xhttp*) _TRANSPORT_MODE="xhttp" ;;
        *)       _TRANSPORT_MODE="xray" ;;
    esac
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
}

# ============================================================
# 通用: logrotate 安全的增量读取 (offset > 文件大小 → 重置)
# 参数: $1=log_path  $2=offset_file  返回(全局): _delta_block _delta_size _offset_reset
# ============================================================
ReadLogDelta() {
    _rl_log="$1"; _rl_off_file="$2"
    _rl_last=$(cat "$_rl_off_file" 2>/dev/null || echo 0)
    _rl_size=$(wc -c < "$_rl_log" 2>/dev/null || echo 0)
    _offset_reset=0
    # logrotate (copytruncate) 后 offset 可能 > 文件大小 → 重置
    if [ "$_rl_last" -gt "$_rl_size" ] 2>/dev/null; then
        plog debug "日志轮转检测: $1 (offset=$_rl_last > size=$_rl_size), 重置 offset"
        _rl_last=0; _offset_reset=1
    fi
    _delta_block=$(tail -c +$((_rl_last + 1)) "$_rl_log" 2>/dev/null || true)
    _delta_size=$_rl_size
}

# ============================================================
# 采集 M3/M4/M5 + fail_src_ips (vision/reality 模式: xray access.log)
# 原理: vision/reality 由 xray 直接处理 TLS, 探针 (拿不到 user id) 失败在 xray
#   - accepted → hs_ok (真实用户)
#   - rejected/invalid/REALITY失败 → hs_fail (探针)
#   - unknown sni/reject → rejected_sni (SNI不匹配探针)
#   - 失败行源 IP → fail_src_ips (服务端判 CN → cn_fail_conns)
# ============================================================
CollectHandshakeXray() {
    _hs_ok=0; _hs_fail=0; _rejected_sni=0; _fail_src_ips=""
    _log=/var/log/xray/access.log
    [ -f "$_log" ] || { plog debug "xray access.log 不存在, 跳过握手统计"; return 0; }

    ReadLogDelta "$_log" ~/probe.hs_offset
    _new_block=$_delta_block; _new_size=$_delta_size

    _hs_ok=$(printf '%s\n' "$_new_block" | grep -c "accepted" || true)
    _hs_fail=$(printf '%s\n' "$_new_block" | grep -ciE "rejected|invalid|handshake.?fail|REALITY.*(invalid|fail)|failed to" || true)
    _rejected_sni=$(printf '%s\n' "$_new_block" | grep -ciE "unknown.?sni|reject.*sni|invalid.*serverName|serverName.*reject" || true)

    # 提取失败连接源 IP (xray access.log 格式: ... from IP:port accepted/rejected ...)
    _fail_src_ips=$(printf '%s\n' "$_new_block" \
        | grep -iE "rejected|invalid|handshake.?fail|REALITY.*(invalid|fail)" \
        | grep -oE 'from [0-9a-fA-F:.]+' | sed 's/from //' \
        | grep -vE '^127\.|^::1$' | sort -u | head -50 | tr '\n' ',' | sed 's/,$//' || true)

    _log_n=$(printf '%s\n' "$_new_block" | grep -c . || true)
    [ "$_log_n" -gt 0 ] && plog debug "xray hs 增量: ${_log_n}行 ok=${_hs_ok} fail=${_hs_fail} sni_rej=${_rejected_sni} fail_ips=${_fail_ips_n:-?}"
}

# ============================================================
# 提取 xhttp 分流路径 (从 nginx proxy.conf)
#   如 location /xtp-abc123 { proxy_pass ... }  →  /xtp-abc123
# ============================================================
GetXhttpPath() {
    for _conf in /etc/nginx/conf.d/proxy.conf /etc/nginx/sites-enabled/*; do
        [ -f "$_conf" ] || continue
        _path=$(grep -oP 'location\s+\K/[^\s{]+' "$_conf" 2>/dev/null | grep -vE '^/$' | head -1)
        [ -n "$_path" ] && { printf '%s' "$_path"; return; }
    done
}

# ============================================================
# 采集 M3/M4/M5 + fail_src_ips (xhttp 模式: nginx access.log)
# 原理: xhttp 由 nginx 前置代理, 正确路径 → xray; 错误路径 → AriaNg 回落
#   GFW 不知道 xhttp 路径 → 打到错误路径 → nginx 回落 → 从未到达 xray = "失败"
#   - 路径命中 → hs_ok (真实用户)
#   - 路径不命中 → hs_fail (疑似探针/访客, 服务端判 CN 后 cn_fail_conns 精确)
#   - 不命中行源 IP → fail_src_ips (服务端判 CN → cn_fail_conns)
# ============================================================
CollectHandshakeNginx() {
    _hs_ok=0; _hs_fail=0; _rejected_sni=0; _fail_src_ips=""
    _log=/var/log/nginx/access.log
    [ -f "$_log" ] || { plog debug "nginx access.log 不存在, 跳过 xhttp 探针统计"; return 0; }

    _path=$(GetXhttpPath)
    [ -n "$_path" ] || { plog debug "xhttp 路径未找到 (nginx proxy.conf), 跳过探针统计"; return 0; }

    ReadLogDelta "$_log" ~/probe.nginx_offset
    _new_block=$_delta_block; _new_size=$_delta_size

    # 路径命中 = 真实代理用户; 路径不命中 = 疑似探针
    _hs_ok=$(printf '%s\n' "$_new_block" | grep -c "$_path" || true)
    _hs_fail=$(printf '%s\n' "$_new_block" | grep -cv "$_path" || true)

    # 提取路径不命中请求的源 IP (nginx combined log 第一字段)
    _fail_src_ips=$(printf '%s\n' "$_new_block" \
        | grep -v "$_path" | awk '{print $1}' \
        | grep -vE '^127\.|^::1$|^-$' | sort -u | head -50 | tr '\n' ',' | sed 's/,$//' || true)

    _log_n=$(printf '%s\n' "$_new_block" | grep -c . || true)
    [ "$_log_n" -gt 0 ] && plog debug "nginx xhttp 增量: ${_log_n}行 命中=${_hs_ok} 不命中=${_hs_fail} (path=${_path})"
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
# v1.1.0: 同时提交 xray offset + nginx offset (按模式只有一个有效)
# ============================================================
CommitState() {
    echo "$_bytes_now" > ~/probe.bytes_last
    echo "$_new_size"  > ~/probe.hs_offset      # xray access.log offset
    echo "$_new_size"  > ~/probe.nginx_offset   # nginx access.log offset (xhttp 模式)
    date +%s          > ~/probe.hs_last_ts
}

# ============================================================
# 上报 — v2_name 用 jq @uri 编码; fail_src_ips 随上报供服务端判 CN
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
    # 走 stdin (--data @-) 避免 ch_hex/fail_src_ips 过大触发 ARG_MAX
    _body="token=${MONITOR_INGEST_TOKEN}&node_id=${_NODE_ID}&v2_name=${_v2_enc}&ts=${_ts}"
    _body="${_body}&conns=${_conns}&src_ips=${_src_ips}&hs_ok=${_hs_ok}"
    _body="${_body}&hs_fail=${_hs_fail}&rejected_sni=${_rejected_sni}&fail_src_ips=${_fail_src_ips}"
    _body="${_body}&ch_hex=${_ch_hex}&bytes_delta=${_bytes_delta}&reporter_ver=${VERSION}"

    _resp=$(printf '%s' "$_body" | curl -sS --connect-timeout 15 --max-time 40 --retry 2 \
        -w "\n%{http_code}" -X POST --data @- \
        -H "Content-Type: application/x-www-form-urlencoded" \
        "${MONITOR_INGEST_URL}/ingest/probe" 2>&1) || true
    _http=$(printf '%s\n' "$_resp" | tail -1)

    if [ "$_http" = "200" ]; then
        CommitState
        _ch_n=$(printf '%s' "$_ch_hex" | tr ',' '\n' | grep -c . || true)
        _fail_n=$(printf '%s' "$_fail_src_ips" | tr ',' '\n' | grep -c . || true)
        plog info "上报成功: conns=${_conns} hs_ok=${_hs_ok} hs_fail=${_hs_fail} fail_ips=${_fail_n} ch=${_ch_n} bytesΔ=${_bytes_delta} [${_TRANSPORT_MODE}]"
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
    DetectTransportMode
    EnsureXrayAccessLog
    CollectConns

    # 按传输模式选择握手采集路径 (核心改动)
    #   xhttp: GFW 探针在 nginx 被回落, 不会到达 xray → 读 nginx access.log
    #   xray:  vision/reality 探针失败在 xray TLS 握手 → 读 xray access.log
    if [ "$_TRANSPORT_MODE" = "xhttp" ]; then
        CollectHandshakeNginx
    else
        CollectHandshakeXray
    fi

    CollectClientHello
    Submit
}

Main "$@"
