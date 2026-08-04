#!/bin/sh
# ============================================================
# nodeAgent.sh — V2 瘦节点状态上报脚本
# 职责: 采集网卡原始 rx/tx 字节数 + 服务器运行时间 + vnstat 7日流量历史，上报至面板
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
# 读取流量采样结果 ~/nodeMonitor.json
# 取 max_mbps 作为节点带宽峰值上报; 缺失/解析失败时回退为 0, 不阻断上报
# (jq 为 proxyInstall 基线依赖; 字段缺失时 // 0 兴默认值)
# ============================================================
LoadNodeMonitor() {
    _nm=~/nodeMonitor.json
    monitor_max_mbps="${monitor_max_mbps:-0}"

    [ -f "$_nm" ] && command -v jq >/dev/null 2>&1 || return 0

    monitor_max_mbps=$(jq -r '.max_mbps // 0' "$_nm" 2>/dev/null) || monitor_max_mbps=0
    [ -z "$monitor_max_mbps" ] && monitor_max_mbps=0

    log debug "已加载 nodeMonitor.json — max_mbps=${monitor_max_mbps}"
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

    # ~/node.env — API 分配的可变配置 (注意: monitor_* 已迁移至 ~/nodeMonitor.json, 见 nodeMonitor.sh)
    if [ -f ~/node.env ]; then
        # shellcheck disable=SC1090
        . ~/node.env || { log error "加载 ~/node.env 失败"; return 1; }
    fi

    # ~/nodeMonitor.json — 流量采样结果 (取 max_mbps 作为带宽峰值上报)
    LoadNodeMonitor

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
# vnstat 7日流量历史采集 — 整合为字符串, 经 monitor= 参数上报
# 格式: v1,v2,v3,v4,v5,v6,v7,M-D
#   * v1..v7 = 近→远 7 天每日「下行接收 rx」, 单位 GiB(整数, 四舍五入); 今天(v1)在最前
#   * 某日无 vnstat 数据 (停机/未采集/装机未满7天) → 该位置写 "-" (空符号, 不是 0)
#   * M-D    = 今天 (第 1 个值) 的日期, 不带年份, 无前导零 (如 8-3)
#     前端据此反推: 第1个值(今天)=M-D, 第i个值 = M-D - (i-1) 天, 第7个值 = M-D - 6 天
#   * 窗口以「系统今天」为锚点 (jq now + localtime), 而非 vnstat 数组尾部:
#     vnstat 滞后/停机时, 缺失的近期日子显示 "-", 不再被伪装成数值或错位日期
#   * vnstat / jq 缺失 或 解析失败 → MONITOR_DATA 留空, 面板按"无历史"处理, 不阻断上报
# 依赖: vnstat + jq (jq 为 proxyInstall 基线依赖; vnstat 非基线, 缺失则静默跳过)
# ============================================================
CollectVnstatTraffic() {
    MONITOR_DATA=""

    command -v vnstat >/dev/null 2>&1 || { log debug "vnstat 未安装, 跳过流量历史采集"; return 0; }
    command -v jq    >/dev/null 2>&1 || { log warn  "jq 不可用, 跳过流量历史采集"; return 0; }

    _vjson=$(vnstat --json d 2>/dev/null) || { log warn "vnstat --json d 执行失败"; return 0; }
    [ -n "$_vjson" ] || { log warn "vnstat 返回空数据, 跳过"; return 0; }

    # 第 1 行: 近 7 日 rx 流量(近→远, GiB 整数, 逗号分隔); 某日无 vnstat 数据 → "-"
    # 第 2 行: 今天日期 (M-D, 不带年份, 无前导零)
    # 单位: GiB (二进制, /1024/1024/1024); 仅取 rx; 四舍五入取整 (jq round)
    # 窗口锚点 = 系统今天 (range + now + localtime), 不是 vnstat 数组尾部:
    #   逐日把 vnstat 的 rx 映射到 [今天, -1, ..., -6] 这 7 个日历日, 缺失即 "-"。
    #   这样 vnstat 滞后/停机时, 近期缺失日显示 "-", 不再错位成数值或假日期。
    _parsed=$(printf '%s' "$_vjson" | jq -r '
        ([range(0;7) | ((now|floor) - . * 86400) | localtime]) as $bdt
        | ($bdt | map("\(.[0])-\(.[1]+1)-\(.[2])")) as $keys
        | (reduce .interfaces[0].traffic.day[] as $d
            ({}; .["\($d.date.year)-\($d.date.month)-\($d.date.day)"] = $d.rx)) as $lookup
        | [
            ($keys | map(($lookup[.] // null)
                         | if . == null then "-" else ((. / 1073741824) | round | tostring) end)
                   | join(",")),
            "\($bdt[0][1]+1)-\($bdt[0][2])"
          ]
        | .[0], .[1]
    ' 2>/dev/null) || { log warn "vnstat 7日流量解析失败"; return 0; }

    _values=$(printf '%s\n' "$_parsed" | sed -n '1p')
    _vdate=$(printf '%s\n' "$_parsed" | sed -n '2p')

    # jq 成功即保证: 第1行恒为 7 项(数值或 "-"), 第2行恒为今天的 M-D
    if [ -z "$_values" ] || [ -z "$_vdate" ]; then
        log warn "vnstat 7日流量解析结果为空"
        return 0
    fi

    MONITOR_DATA="${_values},${_vdate}"
    log debug "vnstat 7日流量已采集 — ${MONITOR_DATA}"
}

# ============================================================
# 数据上报 — application/x-www-form-urlencoded
# ============================================================
SubmitStatus() {
    url="${API_URL}/api/node/status"

    # 参数: token / node_id / raw_rx / raw_tx / server_uptime / node_bandwidth / monitor
    # monitor = vnstat 近7日每日 rx 流量(GiB整数, 缺日为 "-") + 今天日期, 见 CollectVnstatTraffic; 缺失时为空
    node_bandwidth="${monitor_max_mbps:-0}"

    data="token=${API_TOKEN}&node_id=${node_id}&raw_rx=${RAW_RX}&raw_tx=${RAW_TX}&server_uptime=${SERVER_UPTIME}&node_bandwidth=${node_bandwidth}&monitor=${MONITOR_DATA:-}"

    log debug "上报: ${url} — raw_rx=${RAW_RX} raw_tx=${RAW_TX} uptime=${SERVER_UPTIME} bandwidth=${node_bandwidth} monitor=${MONITOR_DATA:-}"

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
        # 原子写入 ~/nodeAgent.json (先写临时文件再 mv, 避免读到半截 JSON)
        # nodeAgent.json = 面板 status 接口的返回体 (含 traffic_used / traffic_max_day_value 等)
        _ja=~/nodeAgent.json
        _ja_tmp="${_ja}.$$"
        printf '%s\n' "$body" > "$_ja_tmp"
        mv -f "$_ja_tmp" "$_ja" 2>/dev/null || cat "$_ja_tmp" > "$_ja" 2>/dev/null
        rm -f "$_ja_tmp" 2>/dev/null || true
        log debug "返回数据已保存到 ~/nodeAgent.json"
    else
        log warn "上报失败 — HTTP ${http_code} — $(printf '%.200s' "$body")"
    fi
}

# ============================================================
# 自更新 — 从面板拉取最新 nodeAgent.sh / nodeMonitor.sh
#   * 不用 wget -N: wget 明确警告 "timestamping does nothing in combination
#     with -O", 即 -N 与 -O 同用时时间戳判定失效, 等于每次全量下载 (17KB, 可忽略)
#   * 下载到临时文件 → 解除可能存在的 immutable(chattr +i) → 原子替换
#     (原子 mv 让运行中的旧脚本继续读旧 inode, 不会被半截写入搞坏)
#   * 失败时打印 wget 真实错误 (不再 2>/dev/null 吞掉, 便于排障)
# ============================================================

# 通用: url → 临时文件 → 解 immutable → 原子 install 到 dest
# stdout: 失败时输出错误摘要, 成功时为空; 返回码 0=成功
_SelfUpdateInstall() {
    _sui_dest="$1"; _sui_url="$2"
    _sui_tmp=$(mktemp 2>/dev/null) || _sui_tmp="${TMPDIR:-/tmp}/nodeagent.$$"
    if ! _sui_err=$(wget --timeout=30 --tries=1 -O "$_sui_tmp" "$_sui_url" 2>&1); then
        rm -f "$_sui_tmp"
        printf '%s' "$_sui_err" | tr '\n' ' ' | sed 's/  */ /g'
        return 1
    fi
    # 若 dest 被 chattr +i 锁定 → 写入会 EPERM "Operation not permitted"
    # 对普通文件 chattr -i 是无害空操作, 故无条件尝试 (fs 不支持属性时静默忽略)
    if command -v chattr >/dev/null 2>&1; then
        chattr -i "$_sui_dest" 2>/dev/null || true
    fi
    chmod +x "$_sui_tmp" 2>/dev/null || true
    if mv -f "$_sui_tmp" "$_sui_dest" 2>/dev/null; then
        return 0
    fi
    # 兜底: 原子 mv 失败 (dest 只读 / 跨文件系统等) → 直接覆盖同 inode
    if cat "$_sui_tmp" > "$_sui_dest" 2>/dev/null; then
        chmod +x "$_sui_dest" 2>/dev/null || true
        rm -f "$_sui_tmp"; return 0
    fi
    rm -f "$_sui_tmp"
    echo "写入失败 (immutable 未解除或权限不足): $_sui_dest"
    return 1
}

SelfUpdate() {
    [ -z "${NODEHUB_URL:-}" ] && return 0

    self_path="$(readlink -f "$0")"

    log debug "检查自更新: ${NODEHUB_URL}/nodeAgent.sh"
    if _su_msg=$(_SelfUpdateInstall "$self_path" "${NODEHUB_URL}/nodeAgent.sh"); then
        log info "自更新完成: ${self_path}"
    else
        log warn "自更新失败: ${NODEHUB_URL}/nodeAgent.sh — ${_su_msg}"
    fi

    # 同步更新 nodeMonitor.sh (每分钟调度器)
    if _su_msg=$(_SelfUpdateInstall ~/nodeMonitor.sh "${NODEHUB_URL}/nodeMonitor.sh"); then
        log debug "nodeMonitor.sh 已同步检查"
    else
        log warn "nodeMonitor.sh 同步失败 — ${_su_msg}"
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
        if [ -n "${NODEHUB_URL:-}" ] && wget -N "${NODEHUB_URL}/proxyInstall.sh" 2>/dev/null; then
            log info "proxyInstall.sh 下载完成, 开始执行重装"
            sh proxyInstall.sh || log warn "proxyInstall.sh 执行返回非零"
        else
            log error "下载 proxyInstall.sh 失败 (NODEHUB_URL=${NODEHUB_URL:-空})"
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
        if [ -n "${NODEHUB_URL:-}" ] && wget -N "${NODEHUB_URL}/proxyInstall.sh" 2>/dev/null; then
            log info "proxyInstall.sh 下载完成, 开始执行重装"
            sh proxyInstall.sh || log warn "proxyInstall.sh 执行返回非零"
        else
            log error "下载 proxyInstall.sh 失败 (NODEHUB_URL=${NODEHUB_URL:-空})"
        fi
    else
        log debug "未检测到 sspcccdn.xyz, 跳过重装补丁"
    fi

    return 0
}

# ============================================================
# 一次性补丁 (2026-07-31): okgfw.top / ccgfw.top / 3ups.top 域名失效, 检测后重装
# 约束: 仅在 2026-07-31 当天运行, 且仅运行一次
# ============================================================
PatchDeprecatedDomainsReinstall() {
    # 1) 仅运行一次 — 标记文件存在则跳过
    _marker="${HOME}/nodeAgent.deprecated-domains.patch.done"
    [ -f "$_marker" ] && return 0

    # 先落标记, 防止重装过程中重入导致重复执行
    : > "$_marker"

    # 2) 检测 ~/node.json 中 root_domain 是否为失效域名 (okgfw.top / ccgfw.top / 3ups.top)
    #    grep -E: 圆点转义为字面量; 与 JSON 写法 "root_domain": "xxx" 对齐, 任一命中即触发
    if [ -f "${HOME}/node.json" ] && grep -qE '"root_domain"[[:space:]]*:[[:space:]]*"(okgfw\.top|ccgfw\.top|3ups\.top)"' "${HOME}/node.json" 2>/dev/null; then
        log warn "检测到失效域名 (okgfw.top/ccgfw.top/3ups.top), 触发重装以更换域名"
        cd /tmp || { log error "进入 /tmp 失败"; return 0; }
        if [ -n "${NODEHUB_URL:-}" ] && wget -N "${NODEHUB_URL}/proxyInstall.sh" 2>/dev/null; then
            log info "proxyInstall.sh 下载完成, 开始执行重装"
            sh proxyInstall.sh || log warn "proxyInstall.sh 执行返回非零"
        else
            log error "下载 proxyInstall.sh 失败 (NODEHUB_URL=${NODEHUB_URL:-空})"
        fi
    else
        log debug "未检测到失效域名 (okgfw.top/ccgfw.top/3ups.top), 跳过重装补丁"
    fi

    return 0
}

# ============================================================
# 一次性补丁 (2026-08-08 前): 上报 traffic_reset_day + traffic_used
#   * traffic_reset_day ← ~/.env NODE_TRAFFIC_RESETDAY (1-31)
#   * traffic_used      ← vnstat 当前计费周期 tx 总和 (GiB, 面板 gb 类型)
# 脚本: .patches/fix_traffic_reset_day_and_traffic_used.py
#   (从 ${NODEHUB_URL}/.patches/ 下载到临时文件后由 python3 执行;
#    脚本自身解析 ~/.env + ~/node.env, 参考 V2ApiController::edit 上报)
# 约束: 仅运行一次 (标记文件); 2026-08-08 之后整行不再触发
# 面板约定: traffic_used 走 EDITABLE_FIELDS['gb'] 类型, 上报 GiB (字节/2^30),
#   面板 round(gib*1024³)→字节, 等价 admin traffic_used_calibrate.
# ============================================================
PatchFixTrafficResetDayAndUsed() {
    # 1) 仅运行一次 — 标记文件存在则跳过; 先落标记防重入
    _marker="${HOME}/nodeAgent.fix-traffic-reset-used.patch.done"
    [ -f "$_marker" ] && return 0
    : > "$_marker"

    # 2) 前置依赖: NODEHUB_URL (下载脚本) + python3 (执行)
    if [ -z "${NODEHUB_URL:-}" ]; then
        log warn "PatchFixTrafficResetDayAndUsed: NODEHUB_URL 未设置, 跳过"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        log warn "python3 不可用, 跳过 traffic_reset_day/traffic_used 校准补丁"
        return 0
    fi

    # 3) 从 NODEHUB_URL 拉取补丁脚本 (文件名含空格 → URL 编码为 %20)
    _patch_url="${NODEHUB_URL}/.patches/fix_traffic_reset_day_and_traffic_used.py"
    _tmp=$(mktemp 2>/dev/null) || _tmp="${TMPDIR:-/tmp}/fix-traffic.$$"
    if ! wget -q -T 30 -O "$_tmp" "$_patch_url" 2>/dev/null || [ ! -s "$_tmp" ]; then
        log warn "下载流量校准补丁失败: ${_patch_url}"
        rm -f "$_tmp" 2>/dev/null || true
        return 0
    fi

    # 4) 执行 — 输出随 nodeAgent 流入 ~/nodeLogs; 非零退出仅告警不阻断
    log info "执行流量校准补丁 (traffic_reset_day + traffic_used)"
    python3 "$_tmp" || log warn "流量校准补丁执行返回非零, 详见上方脚本输出"
    rm -f "$_tmp" 2>/dev/null || true
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
    _today_num=$(date '+%Y%m%d')

    # 日期 → 补丁 映射; 每行独立, 过时直接注释整行即可
    # [ "$_today" = "2026-07-09" ] && PatchAyjxDomainReinstall
    [ "$_today" = "2026-07-17" ] && PatchSspcccdnDomainReinstall
    [ "$_today" = "2026-07-31" ] && PatchDeprecatedDomainsReinstall

    # 窗口型: 2026-08-08 之前任意一天首次执行即跑一次 (标记文件保证仅一次)
    [ "$_today_num" -lt 20260808 ] && PatchFixTrafficResetDayAndUsed

    return 0
}

# ============================================================
# 主流程
# ============================================================
Main() {
    LoadEnv
    CollectRawTraffic
    CollectVnstatTraffic
    SubmitStatus
    SelfUpdate
    SyncSSL
    RunPatches
    trap - EXIT   # 成功完成, 清除错误捕获, 避免误触发 NotifyTG
}

Main "$@"
