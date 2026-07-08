#!/bin/sh
# ============================================================
# probeHunt.sh — JA3↔用户 狩猎探针 (回答"指纹X是哪个用户/客户端")
#
# 原理: 在 vision/reality 节点上, xray 直接终结 :443 TLS, 所以:
#   tcpdump 抓到的 ClientHello 的 (client_ip:client_port)
#   == xray access.log 里 "from client_ip:client_port ... email: xxx"
#   用 src_ip:port 做 JOIN, 即可把 JA3 关联到 VLESS 用户邮箱.
#
# 流程:
#   1. tcpdump 抓 node_port 的 ClientHello (90秒窗口, 抓到 -c 300 上限)
#   2. huntHelper.py 关联 xray access.log → (ja3, user, src_ip, sni) 命中
#   3. 命中 HUNT watchlist 的 → 上报 /ingest/hunt (重点目标)
#   4. 命中但不在 watchlist 的"脏"JA3 (PQ缺失, 见下方判定) → 也上报 (扩名单)
#   5. 清洁 JA3 (已知 firefox/chrome) 不上报 (省带宽/隐私)
#
# 仅 vision/reality 节点有效 (xhttp 走 nginx, xray 看到 127.0.0.1, 关联失效).
# 调用方: nodeMonitor.sh 每 15 分钟 (与 probeTask 同相位或错开), 或独立 crontab.
# ============================================================

VERSION="v1.0.0-20260708"

[ -f ~/.env ] && . ~/.env || true
[ -f ~/node.env ] && . ~/node.env || true
MONITOR_INGEST_TOKEN="${MONITOR_INGEST_TOKEN:-${MONITOR_TOKEN:-}}"

plog() {
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s [hunt] %s\n' "$_ts" "$*"
}

IsDynamicNode() {
    _svc=/etc/systemd/system/stat_client.service
    [ -f "$_svc" ] || return 1
    grep -qE -- '( -g |--group )' "$_svc" 2>/dev/null
}

LoadNodeMeta() {
    [ -n "${v2_name:-${V2_NAME:-}}" ] && return 0
    [ -f ~/node.json ] || return 0
    if command -v jq >/dev/null 2>&1; then
        v2_name=$(jq -r '.v2_name // empty' ~/node.json 2>/dev/null || true)
    elif command -v python3 >/dev/null 2>&1; then
        v2_name=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/node.json'))).get('v2_name','') or '')" 2>/dev/null || true)
    fi
}

# ═════════════════ 加载 watchlist ═════════════════
# 优先级: HUNT_JA3_LIST 环境变量 > ~/huntWatchlist.conf > ${NODEHUB_URL} 下载
LoadWatchlist() {
    _wl_file=~/huntWatchlist.conf
    # 1. 环境变量直传 (最高优先级)
    if [ -n "${HUNT_JA3_LIST:-}" ]; then
        _HUNT_LIST="${HUNT_JA3_LIST}"
        return 0
    fi
    # 2. 自更新 (远程有新版才下载, 复用 nodeAgent 机制)
    if [ -n "${NODEHUB_URL:-}" ]; then
        wget -q -N --timeout=15 --tries=1 \
            -O "$_wl_file" "${NODEHUB_URL}/scripts/probe/huntWatchlist.conf" 2>/dev/null || true
    fi
    # 3. 解析 conf (去注释/空行)
    if [ -f "$_wl_file" ]; then
        _HUNT_LIST=$(grep -vE '^\s*#|^\s*$' "$_wl_file" | tr '\n' ',' | sed 's/,$//')
    else
        _HUNT_LIST=""
    fi
}

# ═════════════════ 抓包 + 关联 ═════════════════
Hunt() {
    _port="${node_port:-443}"
    _pcap=/tmp/probeHunt_$$.pcap
    _helper=~/huntHelper.py
    [ -f "$_helper" ] || { plog "huntHelper.py 缺失, 跳过"; return 1; }
    command -v tcpdump >/dev/null 2>&1 || { plog "无 tcpdump, 跳过"; return 1; }
    command -v python3 >/dev/null 2>&1 || { plog "无 python3, 跳过"; return 1; }

    # 抓 ClientHello: 90秒窗口 (比 probeTask 的30秒更长, 提高命中率), 上限300包
    plog "抓包 ${_port} 90s (watchlist=${_WLN} 个)..."
    tcpdump -i any -c 300 -s 65535 -w "$_pcap" \
        "tcp dst port ${_port} and tcp[(tcp[12]&0xf0)>>2:1] = 0x16 and tcp[((tcp[12]&0xf0)>>2)+5:1] = 0x01" \
        >/dev/null 2>&1 &
    _tcpid=$!
    sleep 90
    kill "$_tcpid" 2>/dev/null || true
    wait "$_tcpid" 2>/dev/null || true

    [ -s "$_pcap" ] || { plog "未抓到包"; rm -f "$_pcap"; return 1; }

    # 关联: huntHelper 输出 "ja3\tuser\tsrc_ip\tsrc_port\tsni\tmatched"
    _HUNT_OUT=$(python3 "$_helper" hunt "$_pcap" /var/log/xray/access.log 300 2>>~/huntLogs.stderr || true)
    rm -f "$_pcap"
    _TOTAL=$(printf '%s\n' "$_HUNT_OUT" | grep -c . || true)
    _MATCHED=$(printf '%s\n' "$_HUNT_OUT" | awk -F'\t' '$6=="yes"' | grep -c . || true)
    plog "关联完成: clienthello=$_TOTAL 关联到用户=$_MATCHED"
}

# ═════════════════ 上报 ═════════════════
# 策略:
#   - matched=yes (真实用户) 且 JA3 在 watchlist → 必报 (核心目标)
#   - matched=yes 且 JA3 不在 watchlist → 也报 (服务端可扩名单; 但清洁JA3跳过省带宽)
#   - matched=no (探针/未认证) 且在 watchlist → 报 (标记该IP是探针源)
Submit() {
    [ -z "${MONITOR_INGEST_URL:-}" ] && { plog "无 MONITOR_INGEST_URL, 跳过上报"; return 0; }
    [ -z "${MONITOR_INGEST_TOKEN:-}" ] && { plog "无 token, 跳过"; return 0; }
    _NODE_ID="${node_id:-${NODE_ID:-}}"
    _V2_NAME="${v2_name:-${V2_NAME:-}}"
    [ -z "$_NODE_ID" ] && { plog "无 node_id, 跳过"; return 0; }

    # 构造 hits: 每行 "ja3|user|src_ip|sni|matched" (用 | 避免与字段分隔冲突)
    # 规则: watchlist 命中全报; 非watchlist 只报 matched=yes 的(真实脏用户)
    _hits=""
    _nreport=0
    _wl_grep=$(printf '%s' "$_HUNT_LIST" | tr ',' '\n')
    # 用 printf 生成制表符/换行, 避免 $'..' (POSIX sh 不支持)
    _TAB=$(printf '\t')
    _NL='
'
    while IFS="$_TAB" read -r _ja3 _user _sip _sport _sni _m; do
        [ -z "$_ja3" ] && continue
        _in_wl=0
        if [ -n "$_wl_grep" ]; then
            printf '%s\n' "$_wl_grep" | grep -qx "$_ja3" && _in_wl=1
        fi
        if [ "$_in_wl" = "1" ] || [ "$_m" = "yes" ]; then
            _hits="${_hits}${_ja3}|${_user}|${_sip}|${_sni}|${_m},${_NL}"
            _nreport=$((_nreport + 1))
        fi
    done <<EOF
$_HUNT_OUT
EOF
    [ "$_nreport" -eq 0 ] && { plog "无可上报命中"; return 0; }

    # URL-encode v2_name
    if command -v jq >/dev/null 2>&1 && [ -n "$_V2_NAME" ]; then
        _v2_enc=$(printf '%s' "$_V2_NAME" | jq -sRr @uri 2>/dev/null || printf '%s' "$_V2_NAME")
    else
        _v2_enc=$(printf '%s' "$_V2_NAME" | sed 's/%/%25/g; s/&/%26/g; s/=/%3D/g; s/+/%2B/g; s/ /%20/g')
    fi

    _ts=$(date +%s)
    _body="token=${MONITOR_INGEST_TOKEN}&node_id=${_NODE_ID}&v2_name=${_v2_enc}&ts=${_ts}"
    _body="${_body}&hits=$(printf '%s' "$_hits" | tr '\n' ',' | sed 's/,$//')"

    _resp=$(printf '%s' "$_body" | curl -sS --connect-timeout 15 --max-time 40 --retry 2 \
        -w "\n%{http_code}" -X POST --data @- \
        -H "Content-Type: application/x-www-form-urlencoded" \
        "${MONITOR_INGEST_URL}/ingest/hunt" 2>&1) || true
    _http=$(printf '%s\n' "$_resp" | tail -1)
    if [ "$_http" = "200" ]; then
        plog "上报成功: $_nreport 条命中 [${_http}]"
    else
        plog "上报失败 [${_http}]"
    fi
}

Main() {
    { [ -z "${MONITOR_INGEST_URL:-}" ] && [ -z "${HUNT_JA3_LIST:-}" ]; } && {
        plog "未配置 (MONITOR_INGEST_URL 或 HUNT_JA3_LIST), 跳过"; return 0; }
    IsDynamicNode || { plog "非 group 节点, 跳过"; return 0; }
    LoadNodeMeta

    # xhttp 节点关联失效 (xray 看到 127.0.0.1), 仅对 xray 前置协议启用
    case "${v2_name:-${V2_NAME:-}}" in
        *xhttp*) plog "xhttp 协议 (nginx前置, 用户关联失效), 跳过 hunt"; return 0 ;;
    esac

    LoadWatchlist
    _WLN=$(printf '%s' "$_HUNT_LIST" | tr ',' '\n' | grep -c . || true)
    Hunt || return 0
    Submit
}

Main "$@"
