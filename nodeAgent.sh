#!/bin/sh
# ============================================================
# nodeAgent.sh — V2 瘦节点状态上报脚本
# 职责: 采集网卡原始 rx/tx 字节数 + 服务器运行时间 + vnstat 7日流量历史，上报至面板;
#       每日检测 node_port 是否被墙 (借 proxyDiagnose.sh 大陆 tcping),
#       在【IP 未被墙 + 端口三网全屏蔽】时自动换随机端口重装 (快速复活节点),
#       并 Telegram 通知被墙情况与处置结果 (详见 DailyPortBlockCheck)
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
TG_NOTIFY_LEVEL="${TG_NOTIFY_LEVEL:-warn}"
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

    # 收敛入口: 等级达标 → 推送 (含 IP / 脚本路径 / 节点ID / 消息)
    if [ "$(_LogLevelNum "$_level")" -ge "$(_LogLevelNum "${TG_NOTIFY_LEVEL:-error}")" ]; then
        NotifyTG "${_level}" "🚨 [NodeHub] ${_SCRIPT_NAME}
节点ID: ${node_id:-${NODE_ID:-N/A}}
IP: $(_TgNodeIp)
脚本: ${_SCRIPT_PATH}
等级: ${_level}
时间: ${_timestamp}
消息: ${_message}"
    fi
}

# NotifyTG — 实际推送 (含节流, 由 log() 在等级达标时调用)
# 用法: NotifyTG <level> <message>   (level 用于按等级独立节流, 避免 warn 刷屏吞掉后续 error)
NotifyTG() {
    _tg_level="$1"
    _tg_text="$2"
    _tg_token="${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
    _tg_chat="${TELEGRAM_CHAT_ID:-${TG_CHAT_ID:-}}"
    # 兼容旧版 .env: 未配置则静默跳过, 不影响主流程
    { [ -z "$_tg_token" ] || [ -z "$_tg_chat" ]; } && return 0

    # 节流: 按等级独立标记文件, 避免 warn 刷屏吞掉同窗口内的 error
    if [ "${_TG_THROTTLE_SEC:-0}" -gt 0 ] 2>/dev/null; then
        _tg_marker="${TMPDIR:-/tmp}/${_SCRIPT_NAME}.tg.${_tg_level}.throttle"
        _now=$(date +%s)
        _last=$(cat "$_tg_marker" 2>/dev/null || echo 0)
        [ $((_now - _last)) -lt "${_TG_THROTTLE_SEC}" ] && return 0
        echo "$_now" > "$_tg_marker" 2>/dev/null || true
    fi

    curl -sS --connect-timeout 5 --max-time 15 \
        --data-urlencode "chat_id=${_tg_chat}" \
        --data-urlencode "text=${_tg_text}" \
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
# ============================================================
# _Sha256File — 文件内容指纹 (sha256, 回退 md5/cksum);
#   不存在 → 输出空串 (调用方据此识别"首次新增"); 读失败 → 输出 "ERR:<size>:<mtime>" 兜底。
#   始终返回 0 (set -e 下 `var=$(...)` 赋值安全)。
#   SyncSSL 用它对比证书下载前后的【内容】是否真正变化:
#   只看 mtime 时, 若远程仅重写时间戳而内容未变 (如面板每日 touch 同一证书),
#   会误判为"已更新" → 每天无谓重启 xray。改用内容 hash: 仅当 .key/.pem 内容真正变化才重启。
# ============================================================
_Sha256File() {
    # 文件不存在 → 输出空串 (调用方据此识别"首次新增"场景); 始终返回 0 (set -e 安全)
    [ -f "$1" ] || return 0
    # 文件存在: 计算内容指纹, 优先 sha256 → md5 → cksum (同次调用 before/after 用同一算法, 不影响对比)
    if command -v sha256sum >/dev/null 2>&1; then
        _sh_out=$(sha256sum "$1" 2>/dev/null) || _sh_out=""
    elif command -v md5sum >/dev/null 2>&1; then
        _sh_out=$(md5sum "$1" 2>/dev/null) || _sh_out=""
    else
        _sh_out=$(cksum "$1" 2>/dev/null | awk '{print $1"-"$2}') || _sh_out=""
    fi
    # `|| _sh_out=""` 使哈希命令失败 (如文件被并发删除/权限异常) 时落入下方
    # size:mtime 兜底分支, 而不是被 set -e 放大为整个 nodeAgent 退出 —
    # 否则兜底分支永远不可达 (死代码), "始终返回 0" 的承诺不成立。
    # 正常: sha256/md5 输出 "<hash>  <path>", 取首字段; cksum 分支已是 "crc-size" (无空格, 取整串)。
    # 读失败 (_sh_out 为空) → 用 size:mtime 兜底: 避免"前后两次都读失败=都空串"被误判为
    # "内容未变"而漏掉真实更新 (证书真变时 size/mtime 必变, 仍能触发 before != after → 重启)。
    if [ -n "$_sh_out" ]; then
        printf '%s' "${_sh_out%% *}"
    else
        printf 'ERR:%s' "$(stat -c '%s:%Y' "$1" 2>/dev/null || echo '?')"
    fi
    return 0
}

# ============================================================
# RestartXrayWithHealthCheck — 重启 xray 并做健康验证
#
# 为什么需要这个函数 (历史 bug, 真实发生过静默停机):
#   xray (Xray-core) 不支持 SIGHUP 热重载 —— 收到 SIGHUP 会直接退出 (与 nginx 不同)。
#   早期 xray.service 错误配置了 ExecReload=/bin/kill -HUP $MAINPID, 于是
#   `systemctl reload xray` 实际是把 xray 杀死; 而 systemctl reload 的退出码只反映
#   "systemd 是否成功执行了 ExecReload 这条命令" (kill 本身恒返回 0), 并不反映服务
#   是否真的在运行。因此旧的 `if systemctl reload xray; then ... else 回退 restart fi`
#   永远走 then 分支, 回退 restart 是死代码 —— xray 被 reload 杀死后无人拉起, 静默停机。
#
# 正确做法:
#   证书每天才更新一次, 秒级断连完全可接受。直接 restart 加载新证书, 不再用 reload。
#   restart 后等待数秒, 用 is-active (+ 端口监听兜底) 确认确实起来了; 任一失败 →
#   log error (error 等级会自动推送 Telegram, 解决 "静默停机无人知晓" 的问题)。
#
# 容错/幂等:
#   * 无 systemctl 或未安装 xray.service → debug 记录后静默返回 (不阻断调用方)
#   * restart 失败 / 健康验证失败 → log error 并返回非 0
#   * 调用方建议用 `RestartXrayWithHealthCheck N || true` 包裹, 避免在 set -e 下放大退出
# 参数: $1 = restart 后等待秒数 (默认 3)
# 返回: 0 = 已重启且健康 (或本机无 xray 而跳过); 非 0 = restart/健康验证失败
# ============================================================
RestartXrayWithHealthCheck() {
    _rx_wait="${1:-3}"

    # 前置依赖: systemctl 存在 + xray.service 已安装; 缺一则静默跳过 (不阻断调用方)
    command -v systemctl >/dev/null 2>&1 \
        || { log debug "RestartXray: systemctl 不存在, 跳过"; return 0; }
    systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service' \
        || { log debug "RestartXray: xray.service 未安装, 跳过"; return 0; }

    # 直接 restart —— 不用 reload: xray 不支持 SIGHUP, reload 等同杀进程
    if ! systemctl restart xray 2>/dev/null; then
        log error "RestartXray: systemctl restart xray 失败 —— 请检查 xray.service / config.json / 证书格式"
        return 1
    fi
    log info "RestartXray: xray 已 restart, 等待 ${_rx_wait}s 做健康验证"

    # 轮询 is-active (sleep 是 shell 内置命令, set -e 下安全; 不会触发退出)
    _i=0
    while [ "$_i" -lt "$_rx_wait" ]; do
        sleep 1
        _i=$((_i + 1))
        [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && break
    done

    # 健康验证 1: is-active == active
    if [ "$(systemctl is-active xray 2>/dev/null)" = "active" ]; then
        log info "RestartXray: 健康验证通过 (active, PID=$(systemctl show -p MainPID --value xray 2>/dev/null || echo '?'))"
        return 0
    fi

    # 健康验证 2 (兜底): is-active 偶有滞后, 再用端口监听确认
    if command -v ss >/dev/null 2>&1 && ss -tlnp 2>/dev/null | grep -q xray; then
        log info "RestartXray: is-active 暂未刷新, 但端口监听正常, 视为健康"
        return 0
    fi

    log error "RestartXray: 健康验证失败 (is-active 非 active 且无端口监听) —— xray 可能未起来, 请人工介入"
    return 1
}

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

    # 4) 原子同步 — 下载到临时目录, 全部校验通过后才一次性落盘 /etc/ssl。
    #    不能分两次直接 wget -P /etc/ssl 覆盖: 若 .key 成功而 .pem 下载失败(节点网络
    #    不稳并非小概率), 会留下 "新 key + 旧 pem" 的不一致中间态 — 本次 return 0
    #    不 reload, 但磁盘状态已脏; 在下次 03:00 自愈前(最长约 24h), 任何重启
    #    (Restart=always 崩溃拉起 / 内核升级 reboot / 人工运维)都会加载到配对错误的
    #    证书 → TLS 握手失败。范式镜像 scripts/auto-renew-ssl.sh::RenewDomain。
    _ssl_tmp=$(mktemp -d 2>/dev/null) || { log warn "SyncSSL: 创建临时目录失败, 跳过"; return 0; }
    if ! wget --timeout=30 --tries=1 -O "${_ssl_tmp}/${_root_domain}.key" \
            "${NODEHUB_URL}/ssl/${_root_domain}.key" 2>/dev/null; then
        log warn "SyncSSL: ${_root_domain}.key 下载失败"
        rm -rf "$_ssl_tmp"; return 0
    fi
    if ! wget --timeout=30 --tries=1 -O "${_ssl_tmp}/${_root_domain}.pem" \
            "${NODEHUB_URL}/ssl/${_root_domain}.pem" 2>/dev/null; then
        log warn "SyncSSL: ${_root_domain}.pem 下载失败"
        rm -rf "$_ssl_tmp"; return 0
    fi

    # 5) 格式校验 — 镜像 proxyInstall.sh Step1_5_DownloadSSL
    if ! grep -q 'BEGIN CERTIFICATE' "${_ssl_tmp}/${_root_domain}.pem" 2>/dev/null; then
        log error "SyncSSL: ${_root_domain}.pem 不含 CERTIFICATE — 源文件可能损坏, 保持旧证书"
        rm -rf "$_ssl_tmp"; return 0
    fi
    if ! grep -q 'PRIVATE KEY' "${_ssl_tmp}/${_root_domain}.key" 2>/dev/null; then
        log error "SyncSSL: ${_root_domain}.key 不含 PRIVATE KEY — 源文件可能损坏, 保持旧证书"
        rm -rf "$_ssl_tmp"; return 0
    fi

    # 6) 配对校验 (openssl 可用时) — 证书公钥 ↔ 私钥公钥必须一致;
    #    只查文件头不查配对, 会漏掉 "新 key + 旧 pem" 这类半更新
    if command -v openssl >/dev/null 2>&1; then
        _cpk=$(openssl x509 -in "${_ssl_tmp}/${_root_domain}.pem" -pubkey -noout 2>/dev/null | openssl md5 2>/dev/null)
        _kpk=$(openssl pkey -in "${_ssl_tmp}/${_root_domain}.key" -pubout 2>/dev/null | openssl md5 2>/dev/null)
        if [ -z "$_cpk" ] || [ "$_cpk" != "$_kpk" ]; then
            log error "SyncSSL: ${_root_domain} 证书与私钥不配对 — 源文件可能损坏, 保持旧证书"
            rm -rf "$_ssl_tmp"; return 0
        fi
    fi

    # 7) 内容对比 (sha256, 非 mtime) — 仅当 key/pem 任一内容真正变化才部署 + 触发重启;
    #    远程仅重写时间戳/内容未变时不误判为已更新 (避免每天无谓重启 xray)
    _key_hash_before=$(_Sha256File "$_key_file")
    _pem_hash_before=$(_Sha256File "$_pem_file")
    _key_hash_after=$(_Sha256File "${_ssl_tmp}/${_root_domain}.key")
    _pem_hash_after=$(_Sha256File "${_ssl_tmp}/${_root_domain}.pem")
    if [ "$_key_hash_before" = "$_key_hash_after" ] && [ "$_pem_hash_before" = "$_pem_hash_after" ]; then
        log info "SyncSSL: ${_root_domain} 证书内容无变化, 保持现状"
        rm -rf "$_ssl_tmp"; return 0
    fi

    # 8) 原子部署 — install 单文件覆盖, 权限收紧 (key 600 / pem 644)
    if ! install -m 0600 "${_ssl_tmp}/${_root_domain}.key" "$_key_file" 2>/dev/null; then
        log error "SyncSSL: 写入 ${_key_file} 失败"
        rm -rf "$_ssl_tmp"; return 0
    fi
    if ! install -m 0644 "${_ssl_tmp}/${_root_domain}.pem" "$_pem_file" 2>/dev/null; then
        log error "SyncSSL: 写入 ${_pem_file} 失败"
        rm -rf "$_ssl_tmp"; return 0
    fi
    rm -rf "$_ssl_tmp"
    _updated=1
    log info "SyncSSL: ${_root_domain} 证书已原子更新 (key/pem 配对校验通过)"

    # 9) 全部通过
    log info "SyncSSL: ${_root_domain} 证书同步完成 (updated=${_updated})"

    # 10) 检测到更新 → reload nginx + 重启 xray, 让新证书生效
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

        # xray: 不支持 SIGHUP 热重载 (收到 SIGHUP 会直接退出), reload 等同杀进程;
        # 且 `systemctl reload` 退出码恒为 0 (只反映 kill 命令成功, 不反映服务存活),
        # 旧的 "reload 失败回退 restart" 判断永不触发 (死代码)。改为直接 restart +
        # 健康验证, 失败由 log error 上报 Telegram。秒级断连可接受 (证书每天才更新一次)。
        # 详细背景见 RestartXrayWithHealthCheck 函数注释。
        # `|| true`: 健康验证失败时也不放大为 set -e 退出 (告警已在函数内发出)。
        RestartXrayWithHealthCheck 3 || true
    fi
}

# ============================================================
# 端口被墙检测 + 快速换端口自愈 — 每日一次
#
# 背景: 检测到部分节点【IP 未被墙、仅端口被墙】(大陆三网对 node_port 的 TCP 握手
#   全部超时), 此时本机监听/证书/海外访问全部正常, 唯独用户侧连不上 ——
#   通过更换端口即可快速复活节点, 无需换 IP / 套 CDN。
#
# 流程 (复用 proxyDiagnose.sh NW10 大陆 tcping 被墙检测, 不重复造轮子):
#   1. 每日 (默认 05 点后的首个周期) 从 ${NODEHUB_URL} 下载 proxyDiagnose.sh,
#      以 --target net --json --no-notify 运行 (含主测 + 随机端口交叉验证, 约 1-3 分钟);
#   2. 解析结果码, 仅在【同时满足】以下两个条件时才自动重装换端口 (must):
#        · NODE_PORT_CN_BLOCKED      — 端口三网+云厂全断 且 海外正常 (端口被墙)
#        · NODE_PORT_CN_XCHECK_PORT  — 交叉验证: 随机新端口大陆可达 → IP 未被墙
#      任一不满足 (IP 级被墙 / 交叉验证无定论 / 单网部分被墙) → 只通知不重装;
#   3. 重装: 重新下载并执行 proxyInstall.sh, 以环境变量 NODE_PORT=<随机端口>
#      覆盖旧端口 (安装脚本四层优先级中环境变量层最高, 面板注册时会同步新端口);
#      随机端口取 20000-60000, 避开历史已用端口 (nodeAgent.portswap.log) /
#      当前端口 / hy2 port-hop 区间 30000-32000 / 已监听端口 (must: 新端口从未被占用过);
#   4. 无论是否重装, 均 Telegram 通知: 端口被墙情况 + 是否已自动重装 (must)。
#
# 开关 / 调参 (~/.env):
#   NODE_PORT_BLOCK_CHECK=0       关闭整个检测 (默认开)
#   NODE_PORT_CHECK_HOUR=5       每日最早执行小时 0-23 (错过窗口的当日可补跑)
#   NODE_PORT_SWAP_COOLDOWN=72000  换端口冷却秒数 (默认 20h, 防频繁重装)
#   NODE_CN_TCPING=0             (proxyDiagnose 侧) 关闭大陆 tcping → 本检测随之失效
#
# 状态: ~/nodeAgent.portcheck.state (date/attempts/done/last_swap)
#   · 当日 attempts 上限 3 — 探测服务 (tcp.ping.pe) 异常致无定论时下个小时重试,
#     最多 3 次避免空转; 得出定论 (未墙/已处置) 后当日不再跑
# 历史: ~/nodeAgent.portswap.log (每次换端口一行: 时间 旧端口→新端口 重装结果)
# ============================================================

# ---- 端口检测状态读写 (~/nodeAgent.portcheck.state, key=value 行) ----
_PortCheckStateGet() {  # <key> → 输出值 (空 = 未设置); 文件不存在输出空, 恒返回 0
    grep -E "^$1=" ~/nodeAgent.portcheck.state 2>/dev/null | tail -1 | sed "s/^$1=//"
    return 0
}

_PortCheckStateSet() {  # <key> <value> — 原子替换 (先写临时文件再 mv)
    _pcs_k="$1"; _pcs_v="$2"
    _pcs_f=~/nodeAgent.portcheck.state
    _pcs_t="${_pcs_f}.tmp.$$"
    grep -v "^${_pcs_k}=" "$_pcs_f" 2>/dev/null > "$_pcs_t" || true
    printf '%s=%s\n' "$_pcs_k" "$_pcs_v" >> "$_pcs_t"
    mv -f "$_pcs_t" "$_pcs_f" 2>/dev/null || true
    return 0
}

# ---- 当前 node_port 读取 (~/node.json > ~/node.env > 443; 与 proxyDiagnose 同源) ----
_PbcReadNodePort() {
    _p=""
    if [ -f ~/node.json ] && command -v jq >/dev/null 2>&1; then
        _p=$(jq -r '.node_port // empty' ~/node.json 2>/dev/null) || true
    fi
    if [ -z "$_p" ] && [ -f ~/node.env ]; then
        _p=$(grep -E '^node_port=' ~/node.env 2>/dev/null | tail -1 | sed 's/^node_port="//;s/"$//')
    fi
    case "$_p" in ''|*[!0-9]*) _p=443 ;; esac
    echo "$_p"
}

# ---- 随机端口选择: 20000-60000, 避开历史已用端口 / 当前端口 / 30000-32000 (hy2 port-hop) / 已监听端口 ----
#   历史已用端口 (~/nodeAgent.portswap.log 出现过的全部端口) 永久拉黑: 换下来的端口
#   大概率已被墙, 再次抽中会让节点上线即失联 (must: 新端口从未被占用过);
#   日志行中 5 位纯数字即历史端口 (日期/时间/重装结果均不足 5 位, 不会误取)
#   srand 种子 = 时间 + PID*7 + 迭代号: 同秒内多次重选也不会退化为同一候选值
_PbcRandomPort() {  # $1 = 当前端口; 成功 echo 随机端口, 失败 return 1
    _avoid="${1:-}"
    _hist=$(grep -oE '[0-9]{5}' ~/nodeAgent.portswap.log 2>/dev/null | sort -u | tr '\n' ' ') || true
    _i=0; _cand=""
    while [ "$_i" -lt 30 ]; do
        _cand=$(awk -v s="$(( $(date +%s) + $$ * 7 + _i ))" \
            'BEGIN{srand(s); printf "%d", int(20000 + rand() * 40001)}')
        case "$_cand" in ''|*[!0-9]*) _i=$((_i + 1)); continue ;; esac
        _skip=0
        for _u in $_avoid $_hist; do
            if [ "$_cand" = "$_u" ]; then _skip=1; break; fi
        done
        if [ "$_skip" = "1" ]; then _i=$((_i + 1)); continue; fi
        if [ "$_cand" -ge 30000 ] && [ "$_cand" -le 32000 ]; then
            _i=$((_i + 1)); continue
        fi
        if command -v ss >/dev/null 2>&1 \
           && ss -H -tuln 2>/dev/null | grep -qE "[:.]${_cand}([^0-9]|$)"; then
            _i=$((_i + 1)); continue
        fi
        echo "$_cand"
        return 0
    done
    return 1
}

# ---- 端口被墙 TG 通知 (专用节流桶 portcheck, 不与 log 等级混用) ----
_PbcNotify() {  # <正文>
    NotifyTG "portcheck" "🚨 [NodeHub] ${_SCRIPT_NAME} — 端口被墙检测与自动处置
节点ID: ${node_id:-${NODE_ID:-N/A}}
IP: $(_TgNodeIp)
时间: $(date '+%Y-%m-%d %H:%M:%S')
$1"
}

DailyPortBlockCheck() {
    # 总开关
    [ "${NODE_PORT_BLOCK_CHECK:-1}" = "0" ] && return 0

    # 每日窗口: 默认 05 点后的首个周期执行 (错过窗口的宕机机当日可补跑)
    _pbc_hour=$(date '+%H' | sed 's/^0//'); [ -z "$_pbc_hour" ] && _pbc_hour=0
    _pbc_min_h=$(printf '%s' "${NODE_PORT_CHECK_HOUR:-5}" | sed 's/^0*//')
    case "$_pbc_min_h" in ''|*[!0-9]*) _pbc_min_h=5 ;; esac
    if [ "$_pbc_hour" -lt "$_pbc_min_h" ]; then return 0; fi

    # 前置依赖: NODEHUB_URL (下载诊断/安装脚本) + jq (解析 JSON) + 已安装节点
    if [ -z "${NODEHUB_URL:-}" ]; then
        log debug "端口被墙检测: NODEHUB_URL 未设置, 跳过"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log warn "端口被墙检测: jq 不可用, 跳过"
        return 0
    fi
    if ! command -v wget >/dev/null 2>&1; then
        log warn "端口被墙检测: wget 不可用, 跳过"
        return 0
    fi
    if [ ! -f ~/node.json ]; then
        log debug "端口被墙检测: ~/node.json 不存在 (节点未安装?), 跳过"
        return 0
    fi

    # 当日调度: done=1 → 已有定论; attempts ≥ 3 → 当日不再试 (探测服务异常止损)
    _pbc_today=$(date '+%Y%m%d')
    _pbc_sdate=$(_PortCheckStateGet date)
    _pbc_satt=$(_PortCheckStateGet attempts)
    if [ "$_pbc_sdate" != "$_pbc_today" ]; then
        _pbc_sdate="$_pbc_today"; _pbc_satt=1
        _PortCheckStateSet date "$_pbc_sdate"
        _PortCheckStateSet attempts 1
        _PortCheckStateSet done 0   # 新一天首跑: 清除昨日 done=1, 否则今日无定论时的重试会被昨日残留标记吞掉
    else
        case "$_pbc_satt" in ''|*[!0-9]*) _pbc_satt=0 ;; esac
        if [ "$(_PortCheckStateGet "done")" = "1" ] || [ "$_pbc_satt" -ge 3 ]; then
            return 0
        fi
        _pbc_satt=$((_pbc_satt + 1))
        _PortCheckStateSet attempts "$_pbc_satt"
    fi

    # 下载诊断脚本 (与 SelfUpdate 同源; --no-notify 抑制其自带 TG, 由本函数统一通知)
    if ! ( cd /tmp && wget -N -T 30 -t 1 "${NODEHUB_URL}/proxyDiagnose.sh" 2>/dev/null ); then
        log warn "端口被墙检测: 下载 proxyDiagnose.sh 失败 — ${NODEHUB_URL}/proxyDiagnose.sh (下个周期重试)"
        return 0
    fi
    if [ ! -s /tmp/proxyDiagnose.sh ] || ! head -c 2 /tmp/proxyDiagnose.sh 2>/dev/null | grep -q '#!'; then
        log warn "端口被墙检测: proxyDiagnose.sh 校验失败 (空文件或非脚本), 跳过"
        return 0
    fi

    # 运行 net 诊断 (含 NW10 主测 + 随机端口交叉验证; stderr 留给 ~/nodeLogs 排障)
    log info "端口被墙检测: 运行 proxyDiagnose --target net (今日第 ${_pbc_satt} 次, 需 1-3 分钟)"
    _pbc_json=""
    if command -v timeout >/dev/null 2>&1; then
        _pbc_json=$(timeout 600 sh /tmp/proxyDiagnose.sh --target net --json --quiet --no-notify) || true
    else
        _pbc_json=$(sh /tmp/proxyDiagnose.sh --target net --json --quiet --no-notify) || true
    fi
    if [ -z "$_pbc_json" ] || ! printf '%s' "$_pbc_json" | jq -e '.results' >/dev/null 2>&1; then
        log warn "端口被墙检测: 诊断无有效 JSON 输出 (tcp.ping.pe 异常?), 下个周期重试"
        return 0
    fi

    # 解析结果码 (语义见 proxyDiagnose.sh _check_node_port_cn_tcping):
    #   NODE_PORT_CN_BLOCKED     FAIL  三网+云厂全断, 海外正常 (端口或 IP 被墙)
    #   NODE_PORT_CN_XCHECK_PORT PASS  交叉验证新端口大陆可达 → 端口级封锁, IP 未被墙 ★重装前提
    #   NODE_PORT_CN_IP_BLOCKED  FAIL  交叉验证新端口大陆亦全断 → IP 级被墙, 换端口无效
    _pbc_codes=$(printf '%s' "$_pbc_json" | jq -r '.results[]?.code' 2>/dev/null) || true
    _pbc_blocked=0; _pbc_xcport=0; _pbc_xcip=0
    for _c in $_pbc_codes; do
        case "$_c" in
            NODE_PORT_CN_BLOCKED)     _pbc_blocked=1 ;;
            NODE_PORT_CN_XCHECK_PORT) _pbc_xcport=1 ;;
            NODE_PORT_CN_IP_BLOCKED)  _pbc_xcip=1 ;;
        esac
    done

    # 未检出三网全断 (含未被墙/单网部分被墙/纯 UDP 端口跳过) → 定论, 当日收工
    if [ "$_pbc_blocked" = "0" ]; then
        log debug "端口被墙检测: NODE_PORT 未被三网全断 (未检出封锁), 明日复测"
        _PortCheckStateSet "done" 1
        return 0
    fi

    _pbc_cur_port=$(_PbcReadNodePort)
    _pbc_blk_title=$(printf '%s' "$_pbc_json" | jq -r '.results[]? | select(.code=="NODE_PORT_CN_BLOCKED") | .title' 2>/dev/null | head -1)
    _pbc_xc_title=$(printf '%s' "$_pbc_json" | jq -r '.results[]? | select(.code=="NODE_PORT_CN_XCHECK_PORT") | .title' 2>/dev/null | head -1)

    # ---- 检出三网+云厂全断, 按交叉验证结论分流 ----

    # 情形 A: IP 级被墙 — 换端口救不了, 只通知不重装 (must: 仅 IP 未被墙才重装)
    if [ "$_pbc_xcip" = "1" ]; then
        _PortCheckStateSet "done" 1
        log info "端口被墙检测: NODE_PORT=${_pbc_cur_port} 三网全断且交叉验证判定【IP 级被墙】— 换端口无效, 不重装"
        _PbcNotify "■ 被墙情况: NODE_PORT=${_pbc_cur_port} 三网+云厂全断, 海外正常
  ${_pbc_blk_title}
■ 交叉验证: 随机新端口大陆亦全断 → IP 级被墙
■ 处置: 未自动重装 (换端口无效)
■ 建议: 套 CDN / 中转 / 联系机房换 IP; 人工复核 https://tcp.ping.pe/$(_TgNodeIp):${_pbc_cur_port}"
        return 0
    fi

    # 情形 B: 未能确认端口级封锁 (交叉验证无定论/混合/被跳过) — 不满足重装前提, 稍后重试
    if [ "$_pbc_xcport" != "1" ]; then
        log info "端口被墙检测: NODE_PORT=${_pbc_cur_port} 三网全断, 但交叉验证未确认端口级封锁 — 暂不重装, 稍后重试"
        _PbcNotify "■ 被墙情况: NODE_PORT=${_pbc_cur_port} 三网+云厂全断, 海外正常
  ${_pbc_blk_title}
■ 交叉验证: 未能确认端口级封锁 (探测点不足 / 临时端口被安全组拦 / 混合封锁 / NODE_CN_TCPING_XCHECK=0)
■ 处置: 未自动重装 (不满足「IP 未被墙 + 端口级封锁」前提), 将自动重试 (当日最多 3 次)
■ 建议: 人工复核 https://tcp.ping.pe/$(_TgNodeIp):${_pbc_cur_port}"
        return 0
    fi

    # 情形 C: IP 未被墙 + 端口三网全屏蔽 (交叉验证新端口大陆可达) → 随机端口重装
    # 冷却: 距上次换端口 < NODE_PORT_SWAP_COOLDOWN 秒 → 只通知不重装 (防频繁重装)
    _pbc_cool=$(printf '%s' "${NODE_PORT_SWAP_COOLDOWN:-72000}" | sed 's/^0*//')
    case "$_pbc_cool" in ''|*[!0-9]*) _pbc_cool=72000 ;; esac
    _pbc_lswap=$(_PortCheckStateGet last_swap)
    case "$_pbc_lswap" in ''|*[!0-9]*) _pbc_lswap=0 ;; esac
    _pbc_since=$(( $(date +%s) - _pbc_lswap ))
    if [ "$_pbc_since" -lt "$_pbc_cool" ]; then
        _PortCheckStateSet "done" 1
        log info "端口被墙检测: 端口级封锁确认, 但距上次换端口仅 $((_pbc_since / 3600))h (冷却期) — 跳过重装"
        _PbcNotify "■ 被墙情况: NODE_PORT=${_pbc_cur_port} 三网+云厂全断, 海外正常
  ${_pbc_blk_title}
■ 交叉验证: ${_pbc_xc_title}
■ 处置: 未自动重装 — 距上次换端口仅 $((_pbc_since / 3600))h, 处于冷却期 (NODE_PORT_SWAP_COOLDOWN=${_pbc_cool}s), 避免频繁重装
■ 建议: 冷却期满后自动处置, 或人工重跑安装脚本换端口"
        return 0
    fi

    _pbc_new_port=$(_PbcRandomPort "$_pbc_cur_port") || {
        log error "端口被墙检测: 随机端口选择失败 (30 次均冲突?), 放弃本次重装"
        return 0
    }

    log info "端口被墙自愈: IP 未被墙 + NODE_PORT=${_pbc_cur_port} 三网全屏蔽 → 换随机端口 ${_pbc_new_port} 重装 proxyInstall.sh"
    _PortCheckStateSet "done" 1
    _PortCheckStateSet last_swap "$(date +%s)"

    # 重装: NODE_PORT 环境变量在 proxyInstall.sh 四层优先级中最高 → 覆盖旧端口;
    # 安装脚本注册时会将新端口上报面板并持久化到 ~/node.json / ~/node.env
    _pbc_ok=0
    if ( cd /tmp && wget -N -T 60 -t 3 "${NODEHUB_URL}/proxyInstall.sh" 2>/dev/null \
         && [ -s proxyInstall.sh ] \
         && NODE_PORT="$_pbc_new_port" sh proxyInstall.sh ); then
        _pbc_ok=1
    fi

    # 重装后实际端口 (面板回传值优先; 与请求的随机端口不一致时以实际为准)
    _pbc_final_port=$(_PbcReadNodePort)
    printf '%s 换端口 %s -> %s (请求随机 %s) 重装=%s\n' \
        "$(date '+%F %T')" "$_pbc_cur_port" "$_pbc_final_port" "$_pbc_new_port" "$_pbc_ok" \
        >> ~/nodeAgent.portswap.log 2>/dev/null || true

    if [ "$_pbc_ok" = "1" ]; then
        log info "端口被墙自愈: 重装完成, 端口 ${_pbc_cur_port} → ${_pbc_final_port}; 次日复测新端口"
    else
        log error "端口被墙自愈: proxyInstall.sh 重装失败 — 请查看 ~/nodeLogs 排障"
    fi

    _PbcNotify "■ 被墙情况: NODE_PORT=${_pbc_cur_port} 三网+云厂全断 (大陆探测点全超时), 海外正常
  ${_pbc_blk_title}
■ 交叉验证: 随机新端口大陆可达 → IP 未被墙, 端口级封锁
  ${_pbc_xc_title}
■ 处置: 已自动重装 proxyInstall.sh, 端口 ${_pbc_cur_port} → ${_pbc_final_port} (随机)
■ 重装结果: $([ "$_pbc_ok" = 1 ] && echo '✅ 成功 (新端口已生效并同步面板)' || echo '❌ 失败 (请查看 ~/nodeLogs 排障, 必要时人工重跑安装脚本)')"
    return 0
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
# 一次性流量校准: traffic_reset_day + traffic_used
#   * traffic_reset_day ← ~/.env NODE_TRAFFIC_RESETDAY (1-31)
#   * traffic_used      ← vnstat 当前计费周期 tx 总和 (GiB, 面板 gb 类型)
# 脚本: .patches/fix_traffic_reset_day_and_traffic_used.py
#   * 从 ${NODEHUB_URL}/.patches/ 用 wget -N 下载到 /tmp, 由 python3 执行
#   * wget -N 仅在远程更新时实际拉取; 文件保留在 /tmp 不删除, 供下次 -N 比对
#     (单文件 wget 按 basename 保存, 不创建 .patches/ 子目录)
#   * -N 不可与 -O 同用 (时间戳判定失效), 故用 cd /tmp 让其按原名保存
#   * 脚本自身解析 ~/.env + ~/node.env, 参考 V2ApiController::edit 上报
# 约束: 仅运行一次 (标记文件 nodeAgent.fix-traffic-reset-used.patch.done);
#       RunPatches 仍按日期窗口 (< 2026-08-08) 决定是否调用本函数
# 面板约定: traffic_used 走 EDITABLE_FIELDS['gb'] 类型, 上报 GiB (字节/2^30),
#   面板 round(gib*1024³)→字节, 等价 admin traffic_used_calibrate.
# ============================================================
PatchFixTrafficResetDayAndUsed() {
    # 1) 仅运行一次 — 标记文件存在则跳过。
    #    有意「先落标记再执行」: 即便本次因 NODEHUB_URL 缺失 / python3 缺失 / 下载或执行失败
    #    而未真正校准, 也绝不重复运行 (校准补丁非幂等, 重复上报会污染计费数据)。
    #    若事后发现某节点未跑成, 由人工另写一次性脚本单独处理, 而非靠本函数重试。
    _marker="${HOME}/nodeAgent.fix-traffic-reset-used3.patch.done"
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

    # 3) wget -N 下载到 /tmp (按 basename 保存; 文件保留不删除)
    #    下载在子 shell 内 cd /tmp, 不污染主流程 cwd (与 PatchXraySighupReloadBug 一致);
    #    执行用绝对路径, 与当前 cwd 解耦
    _patch_url="${NODEHUB_URL}/.patches/fix_traffic_reset_day_and_traffic_used.py"
    if ( cd /tmp && wget -N -T 30 "$_patch_url" 2>/dev/null ); then
        # 4) 执行 — 脚本自带 Telegram 通知 (直接读 ~/.env), 失败不阻断 nodeAgent
        #    vnstat 缺失 / 上报失败 均由脚本自身发 Telegram, 此处不再转发信号
        log info "执行流量校准补丁 (仅 traffic_used)"
        python3 /tmp/fix_traffic_reset_day_and_traffic_used.py || true
    else
        log warn "下载流量校准补丁失败: ${_patch_url}"
    fi
    return 0
}

# ============================================================
# 补丁调度器 — 集中管理所有一次性补丁 (日期窗口在此统一调度)
# 新增补丁只需追加一行, 无需改动 Main
# 过时补丁直接注释整行即可注销
# 各 Patch* 函数仅负责 "一次性标记 + 条件检测"
# ============================================================
# PatchXraySighupReloadBug — 一次性巡检 (2026-08-08 前): xray SIGHUP/reload 静默停机 bug
#
# 与其它 Patch* 一致: 一次性 (marker 保证仅执行一次), 由 RunPatches 在 2026-08-08 前
# 触发。脚本自身幂等 + 告警节流, 健康时静默, 仅在命中 bug 时自动修复并发 Telegram
# (含 IP / node_id / 发现 / 已修复 / 状态)。
#
# 覆盖三类问题 (对应 .patches/fix_xray_sighup_reload_bug.sh):
#   1) xray.service 含致命 ExecReload=/bin/kill -HUP (reload 会杀进程)  → 删除
#   2) Restart=on-failure/no (被信号杀死不兜底)                       → 升级 always
#   3) xray 当前未运行 (is-active != active, bug 症状或其它宕机)        → restart + 验证
#
# 部署: 从 ${NODEHUB_URL}/.patches/fix_xray_sighup_reload_bug.sh 下载到 /tmp 执行;
#   各节点独立巡检自身, 经 nodeAgent 调度即覆盖"所有服务器"。脚本亦可手动独立运行。
# ============================================================
PatchXraySighupReloadBug() {
    # 一次性: 成功执行后才写 marker (而非先写), 便于下载/执行失败时在下个周期重试;
    # 脚本只做 systemctl 操作, 不会重入 nodeAgent, 故无需"先落标记防重入"。
    _marker="${HOME}/nodeAgent.xray-sighup-bug.patch.done"
    [ -f "$_marker" ] && return 0

    if [ -z "${NODEHUB_URL:-}" ]; then
        log debug "PatchXraySighupReloadBug: NODEHUB_URL 未设置, 跳过"
        return 0
    fi
    _patch_url="${NODEHUB_URL}/.patches/fix_xray_sighup_reload_bug.sh"
    log info "PatchXraySighupReloadBug: 巡检 xray SIGHUP/reload 静默停机 bug (一次性)"
    # 子 shell 内 cd /tmp, 不污染主流程 cwd; 脚本幂等且恒 exit 0
    if ( cd /tmp && wget -N -T 30 "$_patch_url" 2>/dev/null && sh fix_xray_sighup_reload_bug.sh ); then
        : > "$_marker"   # 成功才落标记 (确保修复确实生效; 失败则下个周期重试)
    else
        log warn "PatchXraySighupReloadBug: 下载/执行失败 — ${_patch_url} (将在下个周期重试)"
    fi
    return 0
}

RunPatches() {
    _today=$(date '+%Y-%m-%d')
    _today_num=$(date '+%Y%m%d')

    # 日期 → 补丁 映射; 每行独立, 过时直接注释整行即可
    # [ "$_today" = "2026-07-09" ] && PatchAyjxDomainReinstall
    [ "$_today" = "2026-07-17" ] && PatchSspcccdnDomainReinstall
    [ "$_today" = "2026-07-31" ] && PatchDeprecatedDomainsReinstall

    # 窗口型: 2026-08-08 之前任意一天首次执行即跑一次 (标记文件保证仅一次)
    [ "$_today_num" -lt 20260808 ] && PatchFixTrafficResetDayAndUsed

    # 一次性 (2026-08-08 前): xray SIGHUP/reload 静默停机 bug 全节点巡检 + 自动修复 + Telegram 告警
    [ "$_today_num" -lt 20260808 ] && PatchXraySighupReloadBug

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
    DailyPortBlockCheck
    RunPatches
    trap - EXIT   # 成功完成, 清除错误捕获, 避免误触发 NotifyTG
}

Main "$@"
