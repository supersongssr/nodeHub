#!/bin/sh
# ============================================================
# unlockCheck.sh — 独立 IP 服务解锁检测脚本
# 职责: 检测 IP 对各服务的解锁状态 → 解析结果 → POST /api/node/unlock_check
# 检测范围: 流媒体(Netflix/Disney+/Bahamut/MeWatch)、AI(ChatGPT/Claude/Gemini/NotebookLM)、
#           社交平台(TikTok/Bilibili/iQIYI)、搜索(Google Scholar/Bing)
# 用法:
#   直接运行:  sh ~/unlockCheck.sh
#   后台运行:  nohup sh ~/unlockCheck.sh >> ~/nodeLogs 2>&1 &
# ============================================================

set -eu

SCRIPT_VERSION="v1.0.0-$(date '+%Y%m%d')"

# ============================================================
# 日志
# ============================================================
log() {
    _level="$1"; shift
    _message="$*"
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    _color="" _emoji=""
    case "$_level" in
        error) _color="\033[31m"; _emoji="❌" ;;
        warn)  _color="\033[33m"; _emoji="⚠️" ;;
        info)  _color="\033[32m"; _emoji="ℹ️" ;;
        debug) _color="\033[36m"; _emoji="🐛" ;;
        *)     _color="\033[0m";  _emoji="📝" ;;
    esac
    _msg="${_ts} [${_level}] ${_emoji} ${_message}"
    printf '%b%s%b\n' "$_color" "$_msg" "\033[0m" >&2
    echo "$_msg" >> ~/nodeLogs 2>/dev/null || true
}

# ============================================================
# 环境加载
# ============================================================
LoadEnv() {
    [ -f ~/.env ] && . ~/.env || { log error "加载 ~/.env 失败"; exit 1; }
    [ -f ~/node.env ] && . ~/node.env || true

    case "${API_URL:-}" in http*) ;; *) API_URL="https://${API_URL}" ;; esac
    case "${NODEHUB_URL:-}" in http*) ;; *) NODEHUB_URL="https://${NODEHUB_URL}" ;; esac

    NODE_ID="${node_id:-${NODE_ID:-}}"
    [ -z "${NODE_ID}" ] && log error "node_id 为空，退出" && exit 1
    [ -z "${API_TOKEN:-}" ] && log error "API_TOKEN 为空，退出" && exit 1

    log info "unlockCheck.sh ${SCRIPT_VERSION} 启动 — NODE_ID=${NODE_ID}"
}

# ============================================================
# 防重入锁
# ============================================================
AcquireLock() {
    _lock="/tmp/.unlock_check_running_${NODE_ID}"
    if [ -f "$_lock" ]; then
        _old_pid=$(cat "$_lock" 2>/dev/null || true)
        if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
            log warn "已有 unlockCheck 进程运行中 (PID=${_old_pid})，退出"
            exit 0
        fi
    fi
    echo $$ > "$_lock"
    trap 'rm -f /tmp/.unlock_check_running_${NODE_ID}' EXIT
}

# ============================================================
# 执行检测脚本
# ============================================================
RunUnlockCheck() {
    log info "开始服务解锁检测"
    cd /tmp || return

    # Script 1: check.unlock.media — Netflix/Disney/ChatGPT/Claude/Gemini 等
    if [ ! -f /tmp/media_unlock_clean.txt ]; then
        log info "执行 check.unlock.media..."
        curl -L -s check.unlock.media > /tmp/_media_unlock_script.sh 2>/dev/null || true
        if [ -f /tmp/_media_unlock_script.sh ]; then
            echo 66 | bash /tmp/_media_unlock_script.sh > /tmp/media_unlock.txt 2>/dev/null || true
        fi
        sed -r 's/\x1b\[[0-9;]*m//g' /tmp/media_unlock.txt > /tmp/media_unlock_clean.txt 2>/dev/null || true
    else
        log debug "check.unlock.media 结果已缓存，跳过"
    fi

    # Script 2: yeahwu/check — TikTok/Bilibili/iQIYI
    if [ ! -f /tmp/media_check_clean.txt ]; then
        log info "执行 yeahwu/check..."
        wget -qO /tmp/_media_check_script.sh https://github.com/yeahwu/check/raw/main/check.sh 2>/dev/null || true
        if [ -f /tmp/_media_check_script.sh ]; then
            bash /tmp/_media_check_script.sh > /tmp/media_check.txt 2>/dev/null || true
        fi
        sed -r 's/\x1b\[[0-9;]*m//g' /tmp/media_check.txt > /tmp/media_check_clean.txt 2>/dev/null || true
    else
        log debug "yeahwu/check 结果已缓存，跳过"
    fi

    # Script 3: Google Scholar
    if [ ! -f /tmp/check_google_scholar_unlock.json ]; then
        log info "执行 Google Scholar 检测..."
        wget -N --timeout=60 --tries=3 -P /tmp "${NODEHUB_URL}/scripts/check_google_scholar_standalone.py" 2>/dev/null || true
        [ -f /tmp/check_google_scholar_standalone.py ] && python3 /tmp/check_google_scholar_standalone.py 2>/dev/null || true
    else
        log debug "Google Scholar 结果已缓存，跳过"
    fi

    # Script 4: NotebookLM
    if [ ! -f /tmp/notebooklm_check_result.json ]; then
        log info "执行 NotebookLM 检测..."
        wget -N --timeout=60 --tries=3 -P /tmp "${NODEHUB_URL}/scripts/notebooklm_unlock_checker.py" 2>/dev/null || true
        [ -f /tmp/notebooklm_unlock_checker.py ] && python3 /tmp/notebooklm_unlock_checker.py 2>/dev/null || true
    else
        log debug "NotebookLM 结果已缓存，跳过"
    fi

    log info "检测脚本执行完成"
}

# ============================================================
# 解析解锁结果
# ============================================================
ParseUnlockInfo() {
    log info "解析解锁信息"

    unlock_netflix=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Netflix:/ { s/.*Netflix://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_chatgpt=$(sed -n '/^============\[ Multination \]====/,/^====/ { /ChatGPT:/ { s/.*ChatGPT://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_disney=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Disney+:/ { s/.*Disney+://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_bing=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Bing Region:/ { s/.*Bing Region://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_claude=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Claude:/ { s/.*Claude://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_gemini=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Google Gemini:/ { s/.*Google Gemini://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_bahamut=$(sed -n '/^==============\[ Taiwan \]====/,/^====/ { /Bahamut Anime:/ { s/.*Bahamut Anime://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_mewatch=$(sed -n '/==========\[ SouthEastAsia \]====/,/^====/ { /MeWatch:/ { s/.*MeWatch://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_tiktok=$(grep '^ TikTok' /tmp/media_check_clean.txt 2>/dev/null | cut -d':' -f2- | xargs | tr -d ' ')
    unlock_bilibili=$(grep '^ BiliBili China' /tmp/media_check_clean.txt 2>/dev/null | cut -d':' -f2- | xargs | tr -d ' ')
    unlock_iqiyi=$(grep '^ iQIYI International' /tmp/media_check_clean.txt 2>/dev/null | cut -d':' -f2- | xargs | tr -d ' ')

    unlock_google_scholar=""
    if [ -f /tmp/check_google_scholar_unlock.json ]; then
        _s=$(jq -r '.access_status.overall_status' /tmp/check_google_scholar_unlock.json 2>/dev/null || echo "unknown")
        case "$_s" in accessible|captcha) unlock_google_scholar="Yes(${_s})" ;; *) unlock_google_scholar="No(${_s})" ;; esac
    fi

    unlock_notebooklm=""
    if [ -f /tmp/notebooklm_check_result.json ]; then
        _n=$(jq -r '.ipv4.access_status' /tmp/notebooklm_check_result.json 2>/dev/null || echo "")
        case "$_n" in *yes*) unlock_notebooklm="Yes" ;; *) unlock_notebooklm="No" ;; esac
    fi

    log info "解锁结果: netflix=${unlock_netflix:-空} chatgpt=${unlock_chatgpt:-空} claude=${unlock_claude:-空} gemini=${unlock_gemini:-空}"
    log info "解锁结果: disney=${unlock_disney:-空} bing=${unlock_bing:-空} tiktok=${unlock_tiktok:-空} bilibili=${unlock_bilibili:-空}"
    log info "解锁结果: bahamut=${unlock_bahamut:-空} mewatch=${unlock_mewatch:-空} iqiyi=${unlock_iqiyi:-空} scholar=${unlock_google_scholar:-空} notebooklm=${unlock_notebooklm:-空}"
}

# ============================================================
# 上报结果到 Panel
# ============================================================
SubmitUnlockCheck() {
    log info "上报解锁结果到 Panel"

    _data="node_id=${NODE_ID}"
    [ -n "${unlock_netflix:-}" ]        && _data="${_data}&unlock_netflix=${unlock_netflix}"
    [ -n "${unlock_chatgpt:-}" ]        && _data="${_data}&unlock_chatgpt=${unlock_chatgpt}"
    [ -n "${unlock_disney:-}" ]         && _data="${_data}&unlock_disney=${unlock_disney}"
    [ -n "${unlock_bing:-}" ]           && _data="${_data}&unlock_bing=${unlock_bing}"
    [ -n "${unlock_claude:-}" ]         && _data="${_data}&unlock_claude=${unlock_claude}"
    [ -n "${unlock_gemini:-}" ]         && _data="${_data}&unlock_gemini=${unlock_gemini}"
    [ -n "${unlock_tiktok:-}" ]         && _data="${_data}&unlock_tiktok=${unlock_tiktok}"
    [ -n "${unlock_bilibili:-}" ]       && _data="${_data}&unlock_bilibili=${unlock_bilibili}"
    [ -n "${unlock_iqiyi:-}" ]          && _data="${_data}&unlock_iqiyi=${unlock_iqiyi}"
    [ -n "${unlock_bahamut:-}" ]        && _data="${_data}&unlock_bahamut=${unlock_bahamut}"
    [ -n "${unlock_mewatch:-}" ]        && _data="${_data}&unlock_mewatch=${unlock_mewatch}"
    [ -n "${unlock_google_scholar:-}" ] && _data="${_data}&unlock_google_scholar=${unlock_google_scholar}"
    [ -n "${unlock_notebooklm:-}" ]     && _data="${_data}&unlock_notebooklm=${unlock_notebooklm}"

    log debug "POST /api/node/unlock_check — ${_data}"

    _response=$(curl -sS --connect-timeout 15 --max-time 30 \
        --retry 3 --retry-delay 5 --retry-all-errors \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -X POST \
        -d "$_data" \
        "${API_URL}/api/node/unlock_check" 2>&1) || true

    log info "上报结果: ${_response}"
}

# ============================================================
# 主流程
# ============================================================
Main() {
    LoadEnv
    AcquireLock
    RunUnlockCheck
    ParseUnlockInfo
    SubmitUnlockCheck
    log info "===== unlockCheck.sh 完成 ====="
}

Main "$@"
