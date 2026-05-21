#!/bin/sh
# ============================================================
# proxyInstall.sh — V2 瘦节点安装脚本
# 架构: 瘦节点、胖面板 — 节点仅做环境初始化 + API 生命周期 + 配置拉取
# 生命周期: apply_id → register → nginx → xray → resolve_dns → status(循环)
# ============================================================

set -eu

VERSION="v2.3.0-20260429"

# ============================================================
# ERR Trap — 任何命令失败时打印诊断信息后终止
# ============================================================
OnError() {
    _exit_code=$?
    echo "\033[31m$(date '+%Y-%m-%d %H-%M-%S') [FATAL] 💥 命令失败 — 退出码=${_exit_code}\033[0m" >&2
    echo "$(date '+%Y-%m-%d %H-%M-%S') [FATAL] 💥 命令失败 — 退出码=${_exit_code}" >> ~/nodeLogs 2>/dev/null || true
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
# 数据清洗工具
# ============================================================

Assert() {
    _desc="$1"
    _cond="$2"
    if ! eval "$_cond"; then
        log error "断言失败: ${_desc} — 条件: ${_cond}"
        return 1
    fi
    log debug "断言通过: ${_desc}"
}

AssertNotEmpty() {
    _desc="$1"
    _var="$2"
    if [ -z "$_var" ]; then
        log error "断言失败: ${_desc} — 变量为空"
        return 1
    fi
}

AssertFileValid() {
    _desc="$1"
    _filepath="$2"
    if [ ! -f "$_filepath" ]; then
        log error "断言失败: ${_desc} — 文件不存在: ${_filepath}"
        return 1
    fi
    _size=$(wc -c < "$_filepath" 2>/dev/null || echo 0)
    if [ "$_size" -eq 0 ]; then
        log error "断言失败: ${_desc} — 文件为空: ${_filepath}"
        return 1
    fi
    log debug "断言通过: ${_desc} — 文件 ${_filepath} (${_size} bytes)"
}

AssertValidJson() {
    _desc="$1"
    _filepath="$2"
    _jq_err=$(jq -e '.' "$_filepath" 2>&1 >/dev/null) || {
        log error "断言失败: ${_desc} — 非有效 JSON — jq 错误: ${_jq_err}"
        log error "文件内容 (前 300 字符): $(head -c 300 "$_filepath" 2>/dev/null)"
        return 1
    }
    log debug "断言通过: ${_desc} — 有效 JSON"
}

# 剥离所有非数字字符(保留小数点)，返回纯 float 字符串
sanitize_float() {
    echo "$1" | tr -d '\n\r' | sed 's/[^0-9.]//g'
}

# 剥离所有非数字字符，返回纯 integer
sanitize_int() {
    echo "$1" | tr -d '\n\r' | sed 's/[^0-9]//g'
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
# A. 环境读取与变量洗白映射
# ============================================================
LoadEnv() {
    log info "===== proxyInstall.sh ${VERSION} 启动 ====="

    # 1. 加载 ~/.env (用户手工只读配置 — 全大写变量)
    if [ -f ~/.env ]; then
        # shellcheck disable=SC1090
        . ~/.env || die "加载 ~/.env 失败"
        log info "已加载 ~/.env"
    else
        die "~/.env 不存在，请先创建并填入必要配置"
    fi

    # 必需字段校验 — 缺失任何一个立即终止
    [ -z "${API_TOKEN:-}" ]             && die "~/.env 缺少必需字段: API_TOKEN"
    [ -z "${API_URL:-}" ]               && die "~/.env 缺少必需字段: API_URL"
    [ -z "${NODEHUB_URL:-}" ]           && die "~/.env 缺少必需字段: NODEHUB_URL"
    [ -z "${NODE_TRAFFIC_LIMIT:-}" ]    && die "~/.env 缺少必需字段: NODE_TRAFFIC_LIMIT"
    [ -z "${NODE_TRAFFIC_RESETDAY:-}" ] && die "~/.env 缺少必需字段: NODE_TRAFFIC_RESETDAY"
    [ -z "${NODE_COST:-}" ]             && die "~/.env 缺少必需字段: NODE_COST"
    [ -z "${API_PANEL:-}" ]             && die "~/.env 缺少必需字段: API_PANEL"

    # API_PANEL 校验
    case "${API_PANEL}" in
        ssp|srp) ;;
        *) die "API_PANEL 值无效: ${API_PANEL} — 仅支持 ssp 或 srp" ;;
    esac

    # URL 标准化
    _orig_api_url="${API_URL}" _orig_hub_url="${NODEHUB_URL}"
    case "$API_URL" in
        http*) ;;
        *) API_URL="https://${API_URL}" ;;
    esac
    case "$NODEHUB_URL" in
        http*) ;;
        *) NODEHUB_URL="https://${NODEHUB_URL}" ;;
    esac
    [ "$_orig_api_url" != "$API_URL" ]     && log debug "API_URL 标准化: ${_orig_api_url} → ${API_URL}"
    [ "$_orig_hub_url" != "$NODEHUB_URL" ] && log debug "NODEHUB_URL 标准化: ${_orig_hub_url} → ${NODEHUB_URL}"

    # 2. 加载 ~/node.env (脚本自动生成 — 全小写变量)
    if [ -f ~/node.env ]; then
        # shellcheck disable=SC1090
        . ~/node.env
        NODE_ID="${node_id:-${NODE_ID:-}}"
        log info "已加载 ~/node.env (NODE_ID=${NODE_ID:-未分配})"
        log debug "node.env 内容: $(grep -v '^\s*#' ~/node.env 2>/dev/null | grep -v '^\s*$' | tr '\n' ' ')"
    else
        log debug "~/node.env 不存在，首次安装"
    fi

    # ----------------------------------------------------------
    # ~/.env 大写变量 → 透传（无默认值，由 panel 下发）
    # 命名空间隔离: ~/.env 全大写 | ~/node.env 全小写
    # ----------------------------------------------------------

    # 协议模板名称 (可选)
    v2_name="${V2_NAME:-}"

    # 计费模式 (可选) — API v2.0.2 参数名改为 node_rxtx
    node_rxtx="${NODE_RXTX:-${NODE_RXTX_MODE:-}}"

    # 节点分组 (可选)
    node_group="${NODE_GROUP:-}"

    # 访问等级 (可选)
    node_level="${NODE_LEVEL:-}"

    # 月流量额度 / 重置日 / 成本 (必填，已在上方校验)
    node_traffic_limit="${NODE_TRAFFIC_LIMIT}"
    node_traffic_resetday="${NODE_TRAFFIC_RESETDAY}"
    node_cost="${NODE_COST}"

    # 带宽 (可选)
    node_bandwidth="${NODE_BANDWIDTH:-}"

    # 排序权重 (可选)
    node_sort="${NODE_SORT:-}"

    # 流量倍率 (可选)
    node_traffic_rate="${NODE_TRAFFIC_RATE:-}"

    # 节点描述 (可选)
    node_info="${NODE_INFO:-}"

    # root_domain: 优先使用 ~/node.env (API 分配的 root_domain)，其次 ~/.env (ROOT_DOMAIN)
    root_domain="${root_domain:-${ROOT_DOMAIN:-}}"

    log debug "透传变量汇总:"
    log debug "  v2_name=${v2_name:-空} node_rxtx=${node_rxtx:-空} node_group=${node_group:-空}"
    log debug "  node_level=${node_level:-空} node_sort=${node_sort:-空} node_traffic_rate=${node_traffic_rate:-空}"
    log debug "  node_bandwidth=${node_bandwidth:-空} node_info=${node_info:-空} root_domain=${root_domain:-空}"
    log debug "  node_traffic_limit=${node_traffic_limit} node_traffic_resetday=${node_traffic_resetday} node_cost=${node_cost}"

    # ----------------------------------------------------------
    # 自动探测默认网卡并持久化到 ~/node.env
    # ----------------------------------------------------------
    _detected_net_card=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    NET_CARD="${net_card:-${_detected_net_card}}"
    [ -n "${NET_CARD}" ] && SetNodeEnv "net_card" "${NET_CARD}"

    log info "变量加载完成 — v2_name=${v2_name:-空} node_rxtx=${node_rxtx:-空} NET_CARD=${NET_CARD}"
}

# ============================================================
# B. 硬件与网络信息动态采集
# ============================================================

GetPublicIp() {
    _ip=""
    _ip=$(curl -sS --connect-timeout 10 --max-time 15 -4 https://api.ip.sb 2>/dev/null) || true
    [ -z "$_ip" ] && _ip=$(curl -sS --connect-timeout 10 --max-time 15 -4 https://ifconfig.me 2>/dev/null) || true
    echo "$_ip" | tr -d '\n\r '
}

GetPublicIpv6() {
    _ip=""
    _ip=$(curl -sS --connect-timeout 10 --max-time 15 -6 https://api.ip.sb 2>/dev/null) || true
    [ -z "$_ip" ] && _ip=$(curl -sS --connect-timeout 10 --max-time 15 -6 https://ifconfig.me 2>/dev/null) || true
    echo "$_ip" | tr -d '\n\r '
}

# 硬件信息采集 — 输出全部为 node_xxx 纯数字变量
ProbeHardware() {
    log info "开始硬件信息采集"

    # node_cpu: CPU 核心数 (integer)
    node_cpu=$(nproc 2>/dev/null || echo 1)
    node_cpu=$(sanitize_int "$node_cpu")
    [ -z "$node_cpu" ] || [ "$node_cpu" -lt 1 ] && node_cpu=1

    # node_memory: 内存大小 GB (float)
    node_memory=$(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo "0")
    node_memory=$(sanitize_float "$node_memory")
    [ -z "$node_memory" ] && node_memory=0

    # node_disk: 磁盘大小 GB (float)
    node_disk=$(df -BG / 2>/dev/null | awk 'NR==2 {print $2}')
    node_disk=$(sanitize_float "$node_disk")
    [ -z "$node_disk" ] && node_disk=0

    # 公网 IP
    node_ip=$(GetPublicIp)
    node_ipv6=$(GetPublicIpv6)
    log debug "公网 IP 探测: IPv4=${node_ip:-空} IPv6=${node_ipv6:-空}"

    log info "硬件采集完成 — node_cpu=${node_cpu} node_memory=${node_memory} node_disk=${node_disk} node_ip=${node_ip}"
}

# ============================================================
# 媒体解锁信息采集
# 参考 v2PluginDebian.sh 的 RunMediaUnlockCheck / GetMediaUnlockInfo
# ============================================================

# 执行流媒体解锁测试脚本
RunMediaUnlockCheck() {
    log info "开始媒体解锁检测"
    cd /tmp || return

    # Script 1: check.unlock.media — Netflix/Disney/ChatGPT/Claude/Gemini 等
    if [ ! -f /tmp/media_unlock_clean.txt ]; then
        log info "执行 check.unlock.media..."
        curl -L -s check.unlock.media > /tmp/_media_unlock_script.sh 2>/dev/null || true
        if [ -f /tmp/_media_unlock_script.sh ]; then
            echo 66 | bash /tmp/_media_unlock_script.sh > /tmp/media_unlock.txt 2>/dev/null || true
        fi
        sed -r 's/\x1b\[[0-9;]*m//g' /tmp/media_unlock.txt > /tmp/media_unlock_clean.txt 2>/dev/null || true
        log debug "check.unlock.media 结果行数: $(wc -l < /tmp/media_unlock_clean.txt 2>/dev/null || echo 0)"
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
        log debug "yeahwu/check 结果行数: $(wc -l < /tmp/media_check_clean.txt 2>/dev/null || echo 0)"
    else
        log debug "yeahwu/check 结果已缓存，跳过"
    fi

    # Script 3: Google Scholar
    if [ ! -f /tmp/check_google_scholar_unlock.json ]; then
        log info "执行 Google Scholar 检测..."
        wget -N --timeout=60 --tries=3 -P /tmp "${NODEHUB_URL}/scripts/check_google_scholar_standalone.py" 2>/dev/null || true
        [ -f /tmp/check_google_scholar_standalone.py ] && python3 /tmp/check_google_scholar_standalone.py 2>/dev/null || true
        log debug "Google Scholar 结果: $(head -c 200 /tmp/check_google_scholar_unlock.json 2>/dev/null || echo '无结果')"
    else
        log debug "Google Scholar 结果已缓存，跳过"
    fi

    # Script 4: Google NotebookLM
    if [ ! -f /tmp/notebooklm_check_result.json ]; then
        log info "执行 NotebookLM 检测..."
        wget -N --timeout=60 --tries=3 -P /tmp "${NODEHUB_URL}/scripts/notebooklm_unlock_checker.py" 2>/dev/null || true
        [ -f /tmp/notebooklm_unlock_checker.py ] && python3 /tmp/notebooklm_unlock_checker.py 2>/dev/null || true
        log debug "NotebookLM 结果: $(head -c 200 /tmp/notebooklm_check_result.json 2>/dev/null || echo '无结果')"
    else
        log debug "NotebookLM 结果已缓存，跳过"
    fi

    log info "媒体解锁脚本执行完成"
}

# 解析解锁结果，每个服务存为独立变量 unlock_xxx
GetMediaUnlockInfo() {
    log info "解析媒体解锁信息"
    cd /tmp || return

    # --- 从 media_unlock_clean.txt 解析 ---

    unlock_netflix=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Netflix:/ { s/.*Netflix://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')

    unlock_chatgpt=$(sed -n '/^============\[ Multination \]====/,/^====/ { /ChatGPT:/ { s/.*ChatGPT://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')

    unlock_disney=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Disney+:/ { s/.*Disney+://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')

    unlock_bing=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Bing Region:/ { s/.*Bing Region://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')

    unlock_claude=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Claude:/ { s/.*Claude://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')

    unlock_gemini=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Google Gemini:/ { s/.*Google Gemini://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')

    unlock_bahamut=$(sed -n '/^==============\[ Taiwan \]====/,/^====/ { /Bahamut Anime:/ { s/.*Bahamut Anime://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')

    unlock_mewatch=$(sed -n '/==========\[ SouthEastAsia \]====/,/^====/ { /MeWatch:/ { s/.*MeWatch://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')

    # --- 从 media_check_clean.txt 解析 ---
    unlock_tiktok=$(grep '^ TikTok' /tmp/media_check_clean.txt 2>/dev/null | cut -d':' -f2- | xargs | tr -d ' ')

    unlock_bilibili=$(grep '^ BiliBili China' /tmp/media_check_clean.txt 2>/dev/null | cut -d':' -f2- | xargs | tr -d ' ')

    unlock_iqiyi=$(grep '^ iQIYI International' /tmp/media_check_clean.txt 2>/dev/null | cut -d':' -f2- | xargs | tr -d ' ')

    # --- 从 JSON 文件解析 ---
    unlock_google_scholar=""
    if [ -f /tmp/check_google_scholar_unlock.json ]; then
        scholar_status=$(jq -r '.access_status.overall_status' /tmp/check_google_scholar_unlock.json 2>/dev/null || echo "unknown")
        case "$scholar_status" in
            accessible|captcha) unlock_google_scholar="Yes(${scholar_status})" ;;
            *)                  unlock_google_scholar="No(${scholar_status})" ;;
        esac
    fi

    unlock_notebooklm=""
    if [ -f /tmp/notebooklm_check_result.json ]; then
        nb_status=$(jq -r '.ipv4.access_status' /tmp/notebooklm_check_result.json 2>/dev/null || echo "")
        case "$nb_status" in
            *yes*) unlock_notebooklm="Yes" ;;
            *)     unlock_notebooklm="No" ;;
        esac
    fi

    log info "解锁结果: netflix=${unlock_netflix:-空} chatgpt=${unlock_chatgpt:-空} claude=${unlock_claude:-空} gemini=${unlock_gemini:-空}"
    log info "解锁结果: disney=${unlock_disney:-空} bing=${unlock_bing:-空} tiktok=${unlock_tiktok:-空} bilibili=${unlock_bilibili:-空}"
    log info "解锁结果: bahamut=${unlock_bahamut:-空} mewatch=${unlock_mewatch:-空} iqiyi=${unlock_iqiyi:-空}"
    log info "解锁结果: google_scholar=${unlock_google_scholar:-空} notebooklm=${unlock_notebooklm:-空}"
}

# 地理位置探测 — 通过 ip-api.com 获取国家/城市/ISO代码
ProbeGeo() {
    log info "开始地理位置探测"

    # 如果 ~/.env 已显式配置，优先使用
    if [ -n "${NODE_COUNTRY:-}" ]; then
        node_country="${NODE_COUNTRY}"
        node_city="${NODE_CITY:-}"
        node_country_code="${NODE_COUNTRY_CODE:-un}"
        log info "使用 ~/.env 中的地理位置: ${node_country}/${node_city}/${node_country_code}"
        return 0
    fi

    # 通过 ip-api.com 探测 (只支持 IPv4 查询)
    geo_response=$(curl -sS --connect-timeout 10 --max-time 15 \
        "http://ip-api.com/json/${node_ip}?fields=country,city,countryCode" 2>/dev/null) || true
    log debug "ip-api.com 响应: ${geo_response:-空}"

    if [ -n "$geo_response" ]; then
        node_country=$(echo "$geo_response" | jq -r '.country // empty' 2>/dev/null || echo "")
        node_city=$(echo "$geo_response" | jq -r '.city // empty' 2>/dev/null || echo "")
        node_country_code=$(echo "$geo_response" | jq -r '.countryCode // empty' 2>/dev/null || echo "")
    fi

    # 兜底默认值
    node_country="${node_country:-Unknown}"
    node_city="${node_city:-Unknown}"
    node_country_code="${node_country_code:-un}"

    log info "地理位置探测完成 — ${node_country}/${node_city}/${node_country_code}"
}

# ============================================================
# 基础系统调优
# ============================================================
InitSystem() {
    log info "开始系统基础调优"
    log debug "系统信息: $(uname -a)"
    log debug "当前用户: $(whoami) 工作目录: $(pwd)"

    timedatectl set-timezone Asia/Shanghai 2>/dev/null || \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    log info "时区已设为 Asia/Shanghai"

    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        {
            echo "net.core.default_qdisc=fq"
            echo "net.ipv4.tcp_congestion_control=bbr"
        } >> /etc/sysctl.conf
        sysctl -p 2>/dev/null || true
        log info "BBR 已启用"
    else
        log info "BBR 已启用，跳过"
    fi

    if [ "$(ulimit -n)" -lt 65535 ]; then
        {
            echo "* soft nofile 65535"
            echo "* hard nofile 65535"
        } > /etc/security/limits.d/nofile.conf
        log info "ulimit 已调整为 65535"
    fi

    id www-data >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin www-data
    log info "www-data 用户就绪"

    apt-get update -qq
    command -v jq >/dev/null 2>&1     || apt-get install -y -qq jq
    command -v curl >/dev/null 2>&1   || apt-get install -y -qq curl
    command -v nginx >/dev/null 2>&1  || apt-get install -y -qq nginx
    command -v vnstat >/dev/null 2>&1 || apt-get install -y -qq vnstat
    log info "基础系统调优完成"
}

# ============================================================
# C. API 调用封装
# 用法: ApiCall <method> <path> <data_string> [validate_status]
#   data_string: "key1=val1&key2=val2" 格式，GET 拼接 URL，POST 用 -d 发送
#   validate_status="yes" 时额外检查 body.status == "success"
ApiCall() {
    _method="$1"
    _path="$2"
    _api_data="$3"
    _validate_status="${4:-no}"

    AssertNotEmpty "ApiCall: method 参数" "$_method"
    AssertNotEmpty "ApiCall: path 参数" "$_path"
    AssertNotEmpty "ApiCall: API_TOKEN" "${API_TOKEN:-}"
    AssertNotEmpty "ApiCall: API_URL" "${API_URL:-}"

    _url="${API_URL}${_path}"
    log info "API 调用: ${_method} ${_url}"
    log debug "API 参数: $(printf '%.300s' "$_api_data")"

    _curl_err=/tmp/_v2_curl_err_$$
    if [ "$_method" = "GET" ]; then
        response=$(curl -sS --connect-timeout 30 --max-time 120 \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -w "\n%{http_code}" \
            "${_url}?${_api_data}" 2>"$_curl_err") || true
    else
        response=$(curl -sS --connect-timeout 30 --max-time 120 \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -w "\n%{http_code}" \
            -X POST \
            -d "$_api_data" \
            "$_url" 2>"$_curl_err") || true
    fi

    if [ -s "$_curl_err" ]; then
        log debug "curl stderr: $(head -c 300 "$_curl_err")"
    fi
    rm -f "$_curl_err"

    AssertNotEmpty "ApiCall: curl response 非空" "${response:-}"

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    log debug "HTTP ${http_code} — body 长度=${#body} — $(printf '%.200s' "$body")"

    AssertNotEmpty "ApiCall: http_code 非空" "${http_code:-}"
    # 验证 http_code 为纯数字
    case "$http_code" in
        ''|*[!0-9]*) die "ApiCall: http_code 非数字: ${http_code}" ;;
    esac

    if [ "$http_code" != "200" ]; then
        die "API 调用失败: ${_method} ${_path} — HTTP ${http_code} — ${body}"
    fi

    if [ "$_validate_status" = "yes" ]; then
        biz_status=$(echo "$body" | jq -r '.status // empty' 2>/dev/null || echo "")
        if [ "$biz_status" != "success" ]; then
            die "API 业务失败: ${_method} ${_path} — status=${biz_status} — ${body}"
        fi
    fi

    log debug "ApiCall (${_path}) 完成 — 返回 body 长度=${#body}"
    echo "$body"
}

# ============================================================
# Step 0: 申请节点 ID
# ============================================================
Step0_ApplyId() {
    if [ -n "${NODE_ID:-}" ]; then
        log info "Step 0 跳过 — 已有 NODE_ID=${NODE_ID}"
        return 0
    fi

    log info "Step 0: 申请节点 ID"

    _ip=$(GetPublicIp)
    _ipv6=$(GetPublicIpv6)
    log debug "apply_id IP 探测: IPv4=${_ip:-空} IPv6=${_ipv6:-空}"

    _data="node_ip=${_ip}"
    [ -n "$_ipv6" ] && _data="${_data}&node_ipv6=${_ipv6}"

    body=$(ApiCall POST "/api/node/apply_id" "$_data" "no")

    NODE_ID=$(echo "$body" | jq -r '.node_id')
    [ -z "$NODE_ID" ] || [ "$NODE_ID" = "null" ] && die "Step 0 失败: 无法解析 node_id — ${body}"

    SetNodeEnv "node_id" "$NODE_ID"
    log info "Step 0 完成 — NODE_ID=${NODE_ID} 已持久化到 ~/node.env"
}

# ============================================================
# Step 1: 注册节点信息与裂变
# 所有字段严格对齐 npanel-node-api-v2.md 全量契约
# ============================================================
Step1_Register() {
    log info "Step 1: 注册节点信息与裂变"

    # 采集硬件 + 地理 + 网络信息
    ProbeHardware
    ProbeGeo

    # 媒体解锁检测
    RunMediaUnlockCheck
    GetMediaUnlockInfo

    # 读取本地缓存 (node.json + status.json) — panel 以节点上报为第一优先级
    _cached_node_id="" _cached_node_ids="" _cached_root_domain="" _cached_v2_name=""
    _cached_traffic_used=""
    if [ -f ~/node.json ]; then
        _cached_node_id=$(jq -r '.node_id // empty' ~/node.json 2>/dev/null || true)
        _cached_node_ids=$(jq -r '.node_ids // empty' ~/node.json 2>/dev/null || true)
        _cached_root_domain=$(jq -r '.root_domain // empty' ~/node.json 2>/dev/null || true)
        _cached_v2_name=$(jq -r '.v2_name // empty' ~/node.json 2>/dev/null || true)
        log info "node.json 缓存: node_id=${_cached_node_id:-无} node_ids=${_cached_node_ids:-无} root_domain=${_cached_root_domain:-无} v2_name=${_cached_v2_name:-无}"
    else
        log debug "~/node.json 不存在，首次安装"
    fi
    if [ -f ~/status.json ]; then
        _cached_traffic_used=$(jq -r '.traffic_used // empty' ~/status.json 2>/dev/null || true)
        log info "status.json 缓存: traffic_used=${_cached_traffic_used:-无}"
    else
        log debug "~/status.json 不存在，首次安装"
    fi

    # 环境变量覆盖 — V2_NAME / TRAFFIC_USED 为最高优先级
    if [ -n "${V2_NAME:-}" ]; then
        _cached_v2_name="${V2_NAME}"
        v2_name="${V2_NAME}"
        log info "V2_NAME 环境变量覆盖: v2_name=${V2_NAME}"
    fi
    if [ -n "${TRAFFIC_USED_GB:-}" ]; then
        _cached_traffic_used=$(awk "BEGIN {printf \"%.0f\", ${TRAFFIC_USED_GB} * 1073741824}")
        log info "TRAFFIC_USED_GB 环境变量覆盖: ${TRAFFIC_USED_GB} GB → ${_cached_traffic_used} bytes"
    fi

    # 必需字段前置校验
    [ -z "${NODE_ID:-}" ] && die "Step 1 失败: NODE_ID 为空"
    [ -z "${node_ip:-}" ] && [ -z "${node_ipv6:-}" ] && die "Step 1 失败: node_ip 和 node_ipv6 均为空"

    # 构建 urlencode 参数字符串
    _reg_data="node_id=${NODE_ID}"
    [ -n "${node_ip:-}" ]              && _reg_data="${_reg_data}&node_ip=${node_ip}"
    [ -n "${node_ipv6:-}" ]            && _reg_data="${_reg_data}&node_ipv6=${node_ipv6}"
    [ -n "${v2_name:-}" ]              && _reg_data="${_reg_data}&v2_name=${v2_name}"
    [ -n "${node_rxtx:-}" ]            && _reg_data="${_reg_data}&node_rxtx=${node_rxtx}"
    [ -n "${node_cpu:-}" ]             && _reg_data="${_reg_data}&node_cpu=${node_cpu}"
    [ -n "${node_memory:-}" ]          && _reg_data="${_reg_data}&node_memory=${node_memory}"
    [ -n "${node_disk:-}" ]            && _reg_data="${_reg_data}&node_disk=${node_disk}"
    [ -n "${node_group:-}" ]           && _reg_data="${_reg_data}&node_group=${node_group}"
    [ -n "${node_level:-}" ]           && _reg_data="${_reg_data}&node_level=${node_level}"
    [ -n "${node_traffic_limit:-}" ]   && _reg_data="${_reg_data}&node_traffic_limit=${node_traffic_limit}"
    [ -n "${node_traffic_resetday:-}" ] && _reg_data="${_reg_data}&node_traffic_resetday=${node_traffic_resetday}"
    [ -n "${node_cost:-}" ]            && _reg_data="${_reg_data}&node_cost=${node_cost}"
    [ -n "${node_bandwidth:-}" ]        && _reg_data="${_reg_data}&node_bandwidth=${node_bandwidth}"
    [ -n "${node_sort:-}" ]            && _reg_data="${_reg_data}&node_sort=${node_sort}"
    [ -n "${node_traffic_rate:-}" ]    && _reg_data="${_reg_data}&node_traffic_rate=${node_traffic_rate}"
    [ -n "${node_country:-}" ]         && _reg_data="${_reg_data}&node_country=${node_country}"
    [ -n "${node_city:-}" ]            && _reg_data="${_reg_data}&node_city=${node_city}"
    [ -n "${node_country_code:-}" ]    && _reg_data="${_reg_data}&node_country_code=${node_country_code}"
    [ -n "${root_domain:-}" ]          && _reg_data="${_reg_data}&root_domain=${root_domain}"
    [ -n "${node_info:-}" ]            && _reg_data="${_reg_data}&node_info=${node_info}"


    # 追加本地缓存字段 — panel 以节点上报值为第一优先级
    [ -n "${_cached_node_id:-}" ]     && _reg_data="${_reg_data}&node_id=${_cached_node_id}"
    [ -n "${_cached_node_ids:-}" ]    && _reg_data="${_reg_data}&node_ids=${_cached_node_ids}"
    [ -n "${_cached_root_domain:-}" ] && _reg_data="${_reg_data}&root_domain=${_cached_root_domain}"
    [ -n "${_cached_v2_name:-}" ]     && _reg_data="${_reg_data}&v2_name=${_cached_v2_name}"
    [ -n "${_cached_traffic_used:-}" ] && _reg_data="${_reg_data}&traffic_used=${_cached_traffic_used}"

    [ -n "${unlock_netflix:-}" ]       && _reg_data="${_reg_data}&unlock_netflix=${unlock_netflix}"
    [ -n "${unlock_chatgpt:-}" ]       && _reg_data="${_reg_data}&unlock_chatgpt=${unlock_chatgpt}"
    [ -n "${unlock_disney:-}" ]        && _reg_data="${_reg_data}&unlock_disney=${unlock_disney}"
    [ -n "${unlock_bing:-}" ]          && _reg_data="${_reg_data}&unlock_bing=${unlock_bing}"
    [ -n "${unlock_claude:-}" ]        && _reg_data="${_reg_data}&unlock_claude=${unlock_claude}"
    [ -n "${unlock_gemini:-}" ]        && _reg_data="${_reg_data}&unlock_gemini=${unlock_gemini}"
    [ -n "${unlock_tiktok:-}" ]        && _reg_data="${_reg_data}&unlock_tiktok=${unlock_tiktok}"
    [ -n "${unlock_bilibili:-}" ]      && _reg_data="${_reg_data}&unlock_bilibili=${unlock_bilibili}"
    [ -n "${unlock_iqiyi:-}" ]         && _reg_data="${_reg_data}&unlock_iqiyi=${unlock_iqiyi}"
    [ -n "${unlock_bahamut:-}" ]       && _reg_data="${_reg_data}&unlock_bahamut=${unlock_bahamut}"
    [ -n "${unlock_mewatch:-}" ]       && _reg_data="${_reg_data}&unlock_mewatch=${unlock_mewatch}"
    [ -n "${unlock_google_scholar:-}" ] && _reg_data="${_reg_data}&unlock_google_scholar=${unlock_google_scholar}"
    [ -n "${unlock_notebooklm:-}" ]    && _reg_data="${_reg_data}&unlock_notebooklm=${unlock_notebooklm}"

    body=$(ApiCall POST "/api/node/register" "$_reg_data" "yes")

    # 安全落盘
    echo "$body" > ~/node.json
    log info "Step 1 完成 — 裂变结果已保存到 ~/node.json"

    # 从 node.json 读取关键字段供后续步骤使用
    root_domain=$(jq -r '.root_domain // empty' ~/node.json 2>/dev/null || true)
    v2_name=$(jq -r '.v2_name // empty' ~/node.json 2>/dev/null || true)
    node_ids=$(jq -r '.node_ids // empty' ~/node.json 2>/dev/null || true)

    log info "分配的 root_domain=${root_domain:-未分配} v2_name=${v2_name:-未分配} node_ids=${node_ids:-未分配}"
}

# ============================================================
# Step 1.5: 下载 SSL 证书
# ============================================================
Step1_5_DownloadSSL() {
    log info "Step 1.5: 下载 SSL 证书"

    [ -z "${root_domain:-}" ] && die "root_domain 为空，无法下载 SSL 证书"

    wget -N --timeout=60 --tries=3 -P /etc/ssl "${NODEHUB_URL}/ssl/${root_domain}.key" \
        || die "SSL key 下载失败: ${NODEHUB_URL}/ssl/${root_domain}.key"
    wget -N --timeout=60 --tries=3 -P /etc/ssl "${NODEHUB_URL}/ssl/${root_domain}.pem" \
        || die "SSL pem 下载失败: ${NODEHUB_URL}/ssl/${root_domain}.pem"

    log info "SSL 证书已下载: /etc/ssl/${root_domain}.key /etc/ssl/${root_domain}.pem"
}

# ============================================================
# Step 2: 解析 DNS (前端负责解析，节点只触发)
# ============================================================
Step2_ResolveDns() {
    log info "Step 2: 解析 DNS"
    ApiCall POST "/api/node/resolve_dns" "node_id=${NODE_ID}" "yes" > /dev/null
    log info "Step 2 完成 — DNS 解析已提交"
}

# ============================================================
# Step 3: 拉取并安装 Xray 配置
# ============================================================
Step3_InstallXray() {
    log info "Step 3: 安装 Xray 并拉取配置"

    xray_bin_name=""
    case "${API_PANEL}" in
        ssp) xray_bin_name="xray-plugin-ssp-v0.0.9" ;;
        srp) xray_bin_name="xray-plugin-srp-v0.0.9" ;;
    esac
    xray_bin_path="/usr/local/bin/xray"

    # 下载二进制到 /tmp，wget -N 跳过已下载的同名文件
    log info "下载 Xray 内核: ${xray_bin_name}..."
    xray_url="${NODEHUB_URL}/xray/${xray_bin_name}"
    wget -N --timeout=60 --tries=3 -P /tmp "$xray_url" \
        || die "Xray 内核下载失败: ${xray_url}"

    # 复制并改名
    cp -f "/tmp/${xray_bin_name}" "$xray_bin_path"
    chmod +x "$xray_bin_path"
    log info "Xray 内核已安装: ${xray_bin_path}"

    config_body=$(ApiCall POST "/api/node/config" "node_id=${NODE_ID}" "no")

    echo "$config_body" > ~/config.json
    log info "Xray 配置已写入 ~/config.json"

    log debug "config.json 大小: $(wc -c < ~/config.json 2>/dev/null) bytes, 前 200 字符: $(head -c 200 ~/config.json 2>/dev/null)"

    # 复制到 Xray 默认配置路径
    mkdir -p /usr/local/etc/xray
    cp -f ~/config.json /usr/local/etc/xray/config.json
    log info "Xray 配置已同步到 /usr/local/etc/xray/config.json"

    # 下载 GeoIP/GeoSite 数据文件
    mkdir -p /usr/local/share/xray
    log info "下载 geosite.dat..."
    wget -N --timeout=60 --tries=3 -P /usr/local/share/xray "${NODEHUB_URL}/geodat/geosite.dat" \
        || die "geosite.dat 下载失败: ${NODEHUB_URL}/geodat/geosite.dat"
    log info "下载 geoip.dat..."
    wget -N --timeout=60 --tries=3 -P /usr/local/share/xray "${NODEHUB_URL}/geodat/geoip.dat" \
        || die "geoip.dat 下载失败: ${NODEHUB_URL}/geodat/geoip.dat"
    log info "GeoIP/GeoSite 数据已下载到 /usr/local/share/xray/"

    # 下载 xray.service 守护文件
    service_url="${NODEHUB_URL}/xray/xray.service"
    wget -N --timeout=60 --tries=3 -P /tmp "$service_url" \
        || die "xray.service 下载失败: ${service_url}"

    cp -f /tmp/xray.service /etc/systemd/system/xray.service
    systemctl daemon-reload
    log info "xray.service 已更新"

    systemctl restart xray
    systemctl enable xray
    log info "Xray 服务已启动"
}

# ============================================================
# Step 3: 配置 Nginx (前端下发完整 proxy.conf)
# ============================================================
Step3_InstallNginx() {
    log info "Step 3: 配置 Nginx"

    # POST /api/node/nginx_config — 前端渲染完整 proxy.conf，节点直接落盘
    http_code=$(curl -sS --connect-timeout 30 --max-time 60 \
        -o /etc/nginx/conf.d/proxy.conf \
        -w "%{http_code}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -d "node_id=${NODE_ID}" \
        "${API_URL}/api/node/nginx_config") || true

    case "$http_code" in
        200)
            nginx -t 2>&1 || die "Nginx 配置语法检查失败"
            systemctl restart nginx
            systemctl enable nginx
            log info "Nginx 服务已启动"
            ;;
        404)
            log info "该节点无 Nginx 配置 (如 vision 模式)，跳过"
            ;;
        *)
            die "Nginx 配置下载失败: HTTP ${http_code}"
            ;;
    esac
}

# ============================================================
# Step 4: 部署 nodeAgent.sh 到 /etc/crontab
# ============================================================
Step4_DeployCrontab() {
    log info "Step 4: 部署定时任务"

    # 下载 nodeAgent.sh (每小时执行)
    wget -N --timeout=60 --tries=3 -P ~ "${NODEHUB_URL}/nodeAgent.sh" \
        || die "nodeAgent.sh 下载失败: ${NODEHUB_URL}/nodeAgent.sh"
    chmod +x ~/nodeAgent.sh
    log info "nodeAgent.sh 已下载到 ~/"

    # 下载 nodeMonitor.sh (每分钟执行)
    wget -N --timeout=60 --tries=3 -P ~ "${NODEHUB_URL}/nodeMonitor.sh" \
        || die "nodeMonitor.sh 下载失败: ${NODEHUB_URL}/nodeMonitor.sh"
    chmod +x ~/nodeMonitor.sh
    log info "nodeMonitor.sh 已下载到 ~/"

    # 错峰调度: 使用安装时的分钟数
    install_min=$(date +%M)

    # 写入 /etc/crontab: 清除旧条目后追加新条目
    # 清除旧的 nodeAgent/nodeMonitor/nodeStatus 条目
    sed -i '/nodeAgent\.sh/d; /nodeMonitor\.sh/d; /nodeStatus\.sh/d' /etc/crontab

    # /etc/crontab 需要指定用户字段
    _cron_user="$(whoami)"
    {
        echo "${install_min} * * * * ${_cron_user} /bin/sh ~/nodeAgent.sh >> ~/nodeLogs 2>&1"
        echo "* * * * * ${_cron_user} /bin/sh ~/nodeMonitor.sh >> /tmp/nodeMonitor.log 2>&1"
    } >> /etc/crontab

    log info "/etc/crontab 已配置: nodeAgent 每小时第 ${install_min} 分钟 | nodeMonitor 每分钟"
}

# ============================================================
# 主流程
# ============================================================
Main() {
    LoadEnv
    InitSystem
    Step0_ApplyId
    Step1_Register
    Step1_5_DownloadSSL
    Step3_InstallNginx
    Step3_InstallXray
    Step2_ResolveDns
    Step4_DeployCrontab

    log info "===== 安装完成 ====="
    log info "node_id=${NODE_ID}"
    log info "node_ids=${node_ids:-无}"
    log info "配置文件: ~/node.env | ~/node.json | ~/config.json"
    log debug "文件校验: node.env=$(wc -c < ~/node.env 2>/dev/null || echo '不存在')B node.json=$(wc -c < ~/node.json 2>/dev/null || echo '不存在')B config.json=$(wc -c < ~/config.json 2>/dev/null || echo '不存在')B"
    log debug "服务状态: xray=$(systemctl is-active xray 2>/dev/null || echo '未知') nginx=$(systemctl is-active nginx 2>/dev/null || echo '未知')"

    # 安装成功，清除 EXIT trap
    trap - EXIT
}

Main "$@"
