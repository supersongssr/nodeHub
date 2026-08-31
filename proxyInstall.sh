#!/bin/sh
# ============================================================
# proxyInstall.sh — V2 瘦节点安装脚本
# 架构: 瘦节点、胖面板 — 节点仅做环境初始化 + API 生命周期 + 配置拉取
# 生命周期: apply_id → register → nginx → xray → resolve_dns → status(循环)
# ============================================================

set -eu

VERSION="v2.9.1-20260817"
ARIANG_VERSION="1.3.13"
ARIANG_URL="https://github.com/mayswind/AriaNg/releases/download/${ARIANG_VERSION}/AriaNg-${ARIANG_VERSION}.zip"
ARIANG_DIR="/var/www/ariang"
ARIANG_ZIP="/tmp/AriaNg-${ARIANG_VERSION}.zip"

# ============================================================
# 脚本身份 (供 Telegram 通知标注来源 / 安装成功后自删除)
# _SCRIPT_PATH 解析为绝对路径, 保证 rm 时不受当前工作目录影响
# ============================================================
_SCRIPT_NAME="${0##*/}"
case "$0" in
    /*) _SCRIPT_PATH="$0" ;;
    *)
        _sp_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || _sp_dir=""
        if [ -n "$_sp_dir" ]; then
            _SCRIPT_PATH="${_sp_dir}/${_SCRIPT_NAME}"
        else
            _SCRIPT_PATH="$0"
        fi
        ;;
esac

# ============================================================
# Telegram 通知 — 收敛到 log() 内统一触发
#   * 默认仅 error 等级推送; 通过 .env 设置 TG_NOTIFY_LEVEL 调整
#     可选: debug / info / warn / error (阈值越低越宽松)
#   * 节流: _TG_THROTTLE_SEC 秒内只推送一次 (防短时刷屏), 设 0 关闭
#   * 兼容旧版 .env: 未配置 TELEGRAM_BOT_TOKEN / TG_BOT_TOKEN 则静默跳过
#   * 变量优先级: TELEGRAM_BOT_TOKEN > TG_BOT_TOKEN (chat 同理)
# ============================================================
TG_NOTIFY_LEVEL="${TG_NOTIFY_LEVEL:-warn}"
_TG_THROTTLE_SEC="${TG_NOTIFY_THROTTLE:-15}"

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

# 用法: NotifyTG <level> <message>   (level 用于按等级独立节流, 避免 warn 刷屏吞掉后续 error)
NotifyTG() {
    _tg_level="$1"
    _tg_text="$2"
    _tg_token="${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
    _tg_chat="${TELEGRAM_CHAT_ID:-${TG_CHAT_ID:-}}"
    # 未配置则静默跳过, 不影响主流程
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

die() {
    log error "$*"
    _LAST_DIE_MSG="$*"   # 标记: die 已通过 log 推送, OnError 据此跳过重复推送
    exit 1
}

# ============================================================
# ERR Trap — set -e 未捕获失败时统一走 log error → NotifyTG
# 注意: Main() 正常完成时会 trap - EXIT 清除, 故仅在异常时触发
# ============================================================
OnError() {
    _exit_code=$?
    # die() 已通过 log error 推送过通知, 这里只负责退出, 不重复推送
    if [ -n "${_LAST_DIE_MSG:-}" ]; then
        exit "$_exit_code"
    fi
    log error "命令失败 — 退出码=${_exit_code} (set -e 触发, 未捕获的错误)"
    exit "$_exit_code"
}
trap 'OnError' EXIT

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
# 节点名清洗 — 生成可安全用于 API 调用 / URL / ServerStatus 的 slug
# 规则: 小写 | 空格/斜杠/点→'-' | 仅保留 [a-z0-9_-] | 压缩连续分隔符 | 去首尾分隔符
# ============================================================
SanitizeName() {
    printf '%s' "$1" \
        | tr 'A-Z' 'a-z' \
        | tr ' /.' '---' \
        | tr -cd 'a-z0-9_-' \
        | sed -E 's/([-_]){2,}/\1/g; s/^[-_]+//; s/[-_]+$//'
}

# ============================================================
# 节点名解析 — Step0_ApplyId 之后调用 (NODE_ID 已分配)
# 规则 (优先级):
#   1. 显式指定: 环境变量 NODE_NAME / ~/.env NODE_NAME / STAT_NAME (人工命名入口)
#   2. 动态节点: node_name = node_id ★面板分配的节点 ID, 稳定不变
#      — 对应 ServerStatus --alias (展示名): 面板上显示节点 ID, 与面板侧对齐
#      — node_id 由面板分配并持久化 (~/node.env), 重装不变
#      — alias 仅是展示名, 无唯一性约束 (stat 行主键是 -u=stat_user)
# 产出: node_name (非空保证: 极端情况下兜底 node_${NODE_ID})
# ============================================================
ResolveNodeName() {
    # 1. 显式指定 (人工命名入口): 环境变量 NODE_NAME > ~/.env NODE_NAME > STAT_NAME
    _nn="${NODE_NAME:-${STAT_NAME:-}}"

    # 2. 动态节点: node_name = node_id (面板分配, 与面板侧对齐)
    if [ -z "$_nn" ]; then
        _nn="${NODE_ID}"
        log info "动态生成 node_name: ${_nn} (= node_id)"
    fi

    node_name=$(SanitizeName "$_nn")
    [ -z "$node_name" ] && node_name="node_${NODE_ID}"   # 极端兜底: sanitize 后为空

    log info "node_name 已解析: ${node_name}"
}

# ============================================================
# 节点名持久化 — 三处同步, 供不同消费方式读取:
#   ~/node.env  → node_name="xxx"   (source ~/node.env 后直接用 $node_name)
#   ~/node.name → 单行纯文本        (cat ~/node.name 即可读, 供 systemd/监控/人工)
#   ~/node.json → node_name 字段     (jq -r '.node_name' ~/node.json)
# ============================================================
PersistNodeName() {
    [ -z "${node_name:-}" ] && { log warn "PersistNodeName: node_name 为空，跳过持久化"; return 0; }

    SetNodeEnv "node_name" "$node_name"
    # 节点类别显式化 — 与 STAT_USER 联动 (probeTask.sh IsDynamicNode 首选读此字段):
    #   STAT_USER 显式指定 → 固定节点 (人工命名, 不按 IP 检索, 探针采集跳过)
    #   未指定            → 动态节点 (-u=md5(IP), 探针采集; -g 检测仅作历史节点兜底)
    if [ -n "${STAT_USER:-}" ]; then
        SetNodeEnv "node_class" "static"
    else
        SetNodeEnv "node_class" "dynamic"
    fi

    printf '%s\n' "$node_name" > ~/node.name
    chmod 644 ~/node.name 2>/dev/null || true

    if [ -f ~/node.json ]; then
        _tmp_json=$(jq --arg nn "$node_name" '.node_name = $nn' ~/node.json 2>/dev/null) \
            && printf '%s\n' "$_tmp_json" > ~/node.json \
            || log warn "~/node.json 写入 node_name 失败 (文件可能损坏), 跳过"
    fi

    log info "node_name=${node_name} 已持久化 → ~/node.env | ~/node.name | ~/node.json"
}

# ============================================================
# stat 身份派生 (stat_user) — 外部项目"只知 IP"即可在公开 stat 数据中
# 定位本节点那一行: 检索主键 = -u (username 字段)
#   stat_user = md5(IP)  全量 32 位小写 hex ★IPv4 优先 (无 v4 用 v6), 零密钥
# 设计:
#   * 纯函数: 外部项目 hashlib.md5(IP) 一行代码即得 → 匹配公开数据的
#     username 字段命中本节点; 无需 pepper / NODE_ID / 面板信息
#   * 确定性: 重装 / 面板重置 / NODE_ID 复用 / 换组均不变 (只看 IP)
#   * 非粘性: 每次安装按当前 IP 重算 — 换 IP 自动换新身份,
#     服务端旧条目转 offline 待清理
#   * 已知取舍: md5(IPv4) 可被现成彩虹表反查 (代理 IP 本就是公开地址);
#     IP 不能从 stat 数据被"直接读出" — username 是 md5 值, 非明文 IP
#   * 零依赖: md5sum 属 coreutils (Debian 默认有), 无需 openssl
# IP 选择: node_ip (IPv4) 优先, 无则 node_ipv6; 归一化: 去空白/小写/去 %zone
#   (消费端必须用同样归一化与优先级, 见 plans/stat-ip-identity.md)
# 持久化 (仅为可读): ~/node.env (stat_user=) | ~/node.stat_user | ~/node.json (.stat_user)
# 失败策略: IP 为空 / md5sum 不可用 → 置空并告警, 不中断安装
#           (Step0_5 回退 USER=node_name, 代价: 外部无法按 IP 检索)
# ============================================================
DeriveStatIdentity() {
    stat_user=""

    _ident_ip="${node_ip:-${node_ipv6:-}}"
    [ -z "$_ident_ip" ] && { log error "DeriveStatIdentity: node_ip/node_ipv6 均为空, 跳过"; return 0; }

    # 归一化 — 消费端必须用同样规则 (小写/无空白/无 %zone)
    _ident_ip=$(printf '%s' "$_ident_ip" | tr -d '\n\r ' | tr 'A-F' 'a-f' | sed 's/%.*$//')

    if ! command -v md5sum >/dev/null 2>&1; then
        log error "md5sum 不可用 (coreutils 异常?) — stat_user 派生失败, USER 将回退 node_name"
        return 0
    fi

    _hex=$(printf '%s' "${_ident_ip}" | md5sum | awk '{print $1}')
    case "$_hex" in
        ''|*[!0-9a-f]*)
            log error "stat_user md5 计算异常 (hex='$_hex'), USER 将回退 node_name"
            return 0
            ;;
    esac

    stat_user="$_hex"

    # 持久化 (仅为可读; 真源始终是 IP, 每次安装重算覆盖)
    SetNodeEnv "stat_user" "$stat_user"
    printf '%s\n' "$stat_user" > ~/node.stat_user
    if [ -f ~/node.json ]; then
        _tmp_sj=$(jq --arg su "$stat_user" '.stat_user = $su' ~/node.json 2>/dev/null) \
            && printf '%s\n' "$_tmp_sj" > ~/node.json \
            || log warn "~/node.json 写入 stat_user 失败, 跳过"
    fi

    log info "stat_user=${stat_user} (= md5(${_ident_ip})) — 外部项目按 IP 同式派生即可检索; 已持久化到 node.env/node.stat_user/node.json"
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
# APT 锁清理 — 检测到 dpkg/apt 锁被占用时强制终止占用进程
# 策略: 停止服务 → 杀进程 → 清锁文件 → 修复 dpkg 状态
# ============================================================
WaitForAptLock() {
    log info "检查并清理 APT/dpkg 锁..."

    # ---- 1. 停止 unattended-upgrades 服务 ----
    if systemctl is-active unattended-upgrades >/dev/null 2>&1; then
        log warn "unattended-upgrades 正在运行，停止并禁用"
        systemctl stop unattended-upgrades 2>/dev/null || true
        systemctl disable unattended-upgrades 2>/dev/null || true
    fi

    # ---- 2. 查找并 SIGKILL 所有持有 apt/dpkg 锁的进程 ----
    _holders=$(ps aux 2>/dev/null | grep -E '(unattended-upgr|apt-get|apt |dpkg)' | grep -v grep || true)
    if [ -n "$_holders" ]; then
        log warn "发现占用 APT/dpkg 锁的进程，强制终止:"
        echo "$_holders" | while IFS= read -r _line; do
            _pid=$(echo "$_line" | awk '{print $2}')
            _cmd=$(echo "$_line" | awk '{for(i=11;i<=NF;i++) printf "%s ", $i; print ""}')
            log warn "  kill -9 PID=${_pid} (${_cmd})"
            kill -9 "$_pid" 2>/dev/null || true
        done
        sleep 1  # 等待内核回收资源
    fi

    # ---- 3. 清理残留锁文件 ----
    for _lock in \
        /var/lib/dpkg/lock-frontend \
        /var/lib/dpkg/lock \
        /var/lib/apt/lists/lock \
        /var/cache/apt/archives/lock; do
        if [ -f "$_lock" ]; then
            rm -f "$_lock"
            log debug "已清理锁文件: ${_lock}"
        fi
    done

    # ---- 4. 修复可能中断的 dpkg 状态 ----
    dpkg --configure -a >/dev/null 2>&1 || true

    # ---- 5. 最终验证 ----
    _holders=$(ps aux 2>/dev/null | grep -E '(unattended-upgr|apt-get|apt |dpkg)' | grep -v grep || true)
    if [ -n "$_holders" ]; then
        die "APT/dpkg 锁清理后仍有进程占用，请手动处理: ${_holders}"
    fi

    log info "APT/dpkg 锁已就绪"
}

# APT 安全包装器 — 先等待锁释放，再执行 apt-get 命令
# 用法: AptGet <apt-get 的所有参数>
# 例:   AptGet install -y -qq jq
AptGet() {
    WaitForAptLock
    DEBIAN_FRONTEND=noninteractive \
    apt-get -o Dpkg::Options::="--force-confold" "$@"
}

# ============================================================
# A. 环境读取与变量洗白映射
# ============================================================
LoadEnv() {
    log info "===== proxyInstall.sh ${VERSION} 启动 ====="

    # 0. 保存外部环境变量 (最高优先级)
    _ENV_NODE_ID="${NODE_ID:-}"
    _ENV_ROOT_DOMAIN="${ROOT_DOMAIN:-}"
    _ENV_NODE_LEVEL="${NODE_LEVEL:-}"
    _ENV_NODE_PORT="${NODE_PORT:-}"
    _ENV_V2_NAME="${V2_NAME:-}"
    _ENV_IS_NEW_VPS_INSTALL="${IS_NEW_VPS_INSTALL:-}"
    # ServerStatus 配置也支持 export 覆盖 .env
    _ENV_STAT_GID="${STAT_GID:-}"
    _ENV_STAT_USER="${STAT_USER:-}"
    _ENV_STAT_API_URL="${STAT_API_URL:-}"
    _ENV_STAT_API_PASSWORD="${STAT_API_PASSWORD:-}"
    _ENV_NODE_NAME="${NODE_NAME:-}"

    # 1. 加载 ~/.env (用户手工只读配置 — 全大写变量)
    if [ -f ~/.env ]; then
        # shellcheck disable=SC1090
        . ~/.env || die "加载 ~/.env 失败"
        log info "已加载 ~/.env"
    else
        die "~/.env 不存在，请先创建并填入必要配置"
    fi

    # 必需字段校验 — 缺失任何一个立即终止
    _missing=""
    [ -z "${API_TOKEN:-}" ]             && _missing="${_missing}  API_TOKEN             — 面板 API 认证 Token\n"
    [ -z "${API_URL:-}" ]               && _missing="${_missing}  API_URL               — 面板 API 地址\n"
    [ -z "${NODEHUB_URL:-}" ]           && _missing="${_missing}  NODEHUB_URL           — 节点资源下载地址\n"
    [ -z "${NODE_TRAFFIC_LIMIT:-}" ]    && _missing="${_missing}  NODE_TRAFFIC_LIMIT    — 月流量额度 (GB)\n"
    [ -z "${NODE_TRAFFIC_RESETDAY:-}" ] && _missing="${_missing}  NODE_TRAFFIC_RESETDAY — 流量重置日 (1-28)\n"
    [ -z "${NODE_COST:-}" ]             && _missing="${_missing}  NODE_COST             — 节点月成本\n"
    [ -z "${API_PANEL:-}" ]             && _missing="${_missing}  API_PANEL             — 面板类型 (ssp 或 srp)\n"
    if [ -n "$_missing" ]; then
        die "$(printf '%b' "以下必需环境变量未设置，请在 ~/.env 中配置:\n${_missing}")"
    fi

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

    # 外部环境变量 NODE_ID 为最高优先级，覆盖 ~/.env 和 ~/node.env 的值
    [ -n "${_ENV_NODE_ID}" ] && NODE_ID="${_ENV_NODE_ID}" && log info "环境变量 NODE_ID=${NODE_ID} (最高优先级)"

    # ServerStatus 配置: export 覆盖 ~/.env (支持运行时切 group/user 模式)
    [ -n "${_ENV_STAT_GID}" ]           && STAT_GID="${_ENV_STAT_GID}"
    [ -n "${_ENV_STAT_USER}" ]          && STAT_USER="${_ENV_STAT_USER}"
    [ -n "${_ENV_STAT_API_URL}" ]       && STAT_API_URL="${_ENV_STAT_API_URL}"
    [ -n "${_ENV_STAT_API_PASSWORD}" ]  && STAT_API_PASSWORD="${_ENV_STAT_API_PASSWORD}"
    [ -n "${_ENV_NODE_NAME}" ]         && NODE_NAME="${_ENV_NODE_NAME}" && log info "环境变量 NODE_NAME=${NODE_NAME} (最高优先级)"

    # ----------------------------------------------------------
    # ~/.env 大写变量 → 透传（无默认值，由 panel 下发）
    # 命名空间隔离: ~/.env 全大写 | ~/node.env 全小写
    # ----------------------------------------------------------

    # ===========================================================
    # v2_name 解析 — 四层优先级
    #   1. 外部环境变量 V2_NAME (最高)
    #   2. ~/.env 中的 V2_NAME
    #   3. ~/node.env 中的 v2_name
    #   4. ~/node.json 中的 v2_name (最低)
    #   默认: 空 (由 panel 下发)
    # ===========================================================
    v2_name=""

    # 来源 4: ~/node.json (最低优先级)
    if [ -f ~/node.json ]; then
        _v2nj=$(jq -r '.v2_name // empty' ~/node.json 2>/dev/null || true)
        if [ -n "$_v2nj" ]; then
            v2_name="$_v2nj"
            log debug "v2_name 来源: ~/node.json = ${v2_name}"
        fi
    fi

    # 来源 3: ~/node.env
    if [ -f ~/node.env ]; then
        _v2ne=$(grep '^v2_name=' ~/node.env 2>/dev/null | tail -1 | sed 's/^v2_name="//;s/"$//' || true)
        if [ -n "$_v2ne" ]; then
            v2_name="$_v2ne"
            log debug "v2_name 来源: ~/node.env = ${v2_name}"
        fi
    fi

    # 来源 2: ~/.env (已被 source，变量名 V2_NAME)
    if [ -n "${V2_NAME:-}" ]; then
        v2_name="${V2_NAME}"
        log debug "v2_name 来源: ~/.env = ${v2_name}"
    fi

    # 来源 1: 外部环境变量 (最高优先级)
    if [ -n "${_ENV_V2_NAME:-}" ]; then
        v2_name="${_ENV_V2_NAME}"
        log info "v2_name 来源: 环境变量 = ${v2_name} (最高优先级)"
    fi

    log info "v2_name 最终值: ${v2_name:-空}"

    # 计费模式 (可选) — API v2.0.2 参数名改为 node_rxtx
    node_rxtx="${NODE_RXTX:-${NODE_RXTX_MODE:-}}"

    # 节点分组 (可选)
    node_group="${NODE_GROUP:-}"

    # 访问等级 (可选) — 环境变量 NODE_LEVEL > ~/.env 中的 NODE_LEVEL
    node_level="${_ENV_NODE_LEVEL:-${NODE_LEVEL:-}}"
    [ -n "${_ENV_NODE_LEVEL}" ] && log info "环境变量 NODE_LEVEL=${node_level} (最高优先级)"

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

    # 节点名 (可选) — 显式指定优先; 动态节点默认 node_name = node_id (面板节点 ID)
    #   (对应 stat_client --alias 展示名; 按 IP 检索走 stat_user = md5(IP), 见 DeriveStatIdentity)
    # 优先级: 环境变量 NODE_NAME > ~/.env NODE_NAME > STAT_NAME > node_id
    # 解析在 Step1_Register 之后的 ResolveNodeName() 中完成
    # 节点侧随时读取: cat ~/node.name | source ~/node.env 后用 $node_name | jq .node_name ~/node.json

    # root_domain: 环境变量 ROOT_DOMAIN > ~/node.env (root_domain)
    root_domain="${root_domain:-${ROOT_DOMAIN:-}}"
    [ -n "${_ENV_ROOT_DOMAIN}" ] && root_domain="${_ENV_ROOT_DOMAIN}" && log info "环境变量 ROOT_DOMAIN=${root_domain} (最高优先级)"

    # node_level 三级优先级: 环境变量 > ~/.env > ~/node.json
    # (~/node.json 缓存在 Step1_Register 中读取，若当前 node_level 为空则用缓存值填充)

    # ===========================================================
    # NODE_PORT 解析 — 四层优先级
    #   1. 外部环境变量 NODE_PORT (最高)
    #   2. ~/.env 中的 NODE_PORT
    #   3. ~/node.env 中的 node_port
    #   4. ~/node.json 中的 node_port (最低)
    #   默认: 443
    # ===========================================================
    node_port="443"

    # 来源 4: ~/node.json (最低优先级)
    if [ -f ~/node.json ]; then
        _jp=$(jq -r '.node_port // empty' ~/node.json 2>/dev/null || true)
        if [ -n "$_jp" ]; then
            node_port="$_jp"
            log debug "NODE_PORT 来源: ~/node.json = ${node_port}"
        fi
    fi

    # 来源 3: ~/node.env
    if [ -f ~/node.env ]; then
        _nep=$(grep '^node_port=' ~/node.env 2>/dev/null | tail -1 | sed 's/^node_port="//;s/"$//' || true)
        if [ -n "$_nep" ]; then
            node_port="$_nep"
            log debug "NODE_PORT 来源: ~/node.env = ${node_port}"
        fi
    fi

    # 来源 2: ~/.env (已被 source，变量名 NODE_PORT)
    if [ -n "${NODE_PORT:-}" ]; then
        node_port="${NODE_PORT}"
        log debug "NODE_PORT 来源: ~/.env = ${node_port}"
    fi

    # 来源 1: 外部环境变量 (最高优先级)
    if [ -n "${_ENV_NODE_PORT}" ]; then
        node_port="${_ENV_NODE_PORT}"
        log info "NODE_PORT 来源: 环境变量 = ${node_port} (最高优先级)"
    fi

    # 数字校验
    node_port=$(sanitize_int "$node_port")
    [ -z "$node_port" ] && node_port=443

    log info "NODE_PORT 最终值: ${node_port}"

    log debug "透传变量汇总:"
    log debug "  v2_name=${v2_name:-空} node_rxtx=${node_rxtx:-空} node_group=${node_group:-空}"
    log debug "  node_level=${node_level:-空} node_sort=${node_sort:-空} node_traffic_rate=${node_traffic_rate:-空}"
    log debug "  node_bandwidth=${node_bandwidth:-空} node_info=${node_info:-空} root_domain=${root_domain:-空}"
    log debug "  node_traffic_limit=${node_traffic_limit} node_traffic_resetday=${node_traffic_resetday} node_cost=${node_cost} node_port=${node_port}"

    # ----------------------------------------------------------
    # 自动探测默认网卡并持久化到 ~/node.env
    # ----------------------------------------------------------
    _detected_net_card=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    NET_CARD="${net_card:-${_detected_net_card}}"
    [ -n "${NET_CARD}" ] && SetNodeEnv "net_card" "${NET_CARD}"

    log info "变量加载完成 — v2_name=${v2_name:-空} node_rxtx=${node_rxtx:-空} NET_CARD=${NET_CARD}"

    # 全新安装判定: ~/node.json 不存在 = 全新 (node.json 在 Step1_Register 才创建)
    # 后续步骤据此判断是否为首次安装, 避免重复安装时重复注入
    if [ -f ~/node.json ]; then
        IS_NEW_VPS_INSTALL=false
        log info "检测到 ~/node.json → 重复安装 (IS_NEW_VPS_INSTALL=false)"
    else
        IS_NEW_VPS_INSTALL=true
        log info "~/node.json 不存在 → 全新安装 (IS_NEW_VPS_INSTALL=true)"
    fi

    # 环境变量 IS_NEW_VPS_INSTALL 为最高优先级，覆盖自动探测结果
    # 支持值 (大小写不敏感): true/1/yes → true | false/0/no → false | 其他 → 忽略并告警
    if [ -n "${_ENV_IS_NEW_VPS_INSTALL:-}" ]; then
        case "$(echo "$_ENV_IS_NEW_VPS_INSTALL" | tr 'A-Z' 'a-z')" in
            true|1|yes)
                IS_NEW_VPS_INSTALL=true
                log info "环境变量 IS_NEW_VPS_INSTALL=true (最高优先级)"
                ;;
            false|0|no)
                IS_NEW_VPS_INSTALL=false
                log info "环境变量 IS_NEW_VPS_INSTALL=false (最高优先级)"
                ;;
            *)
                log warn "环境变量 IS_NEW_VPS_INSTALL 值无效: \"${_ENV_IS_NEW_VPS_INSTALL}\" (仅支持 true/false/yes/no/1/0)，忽略并使用自动探测值: ${IS_NEW_VPS_INSTALL}"
                ;;
        esac
    fi
    log info "IS_NEW_VPS_INSTALL 最终值: ${IS_NEW_VPS_INSTALL}"

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
# 系统版本探测 — 输出 node_os 变量, 格式: "发行版名 主版本号"
# 例: debian 12 / debian 13 / centos 7 / centos 8 / ubuntu 22.04 /
#     rocky 9 / almalinux 9 / fedora 39 / amzn 2
# 探测链 (依次兜底):
#   1. /etc/os-release  (systemd 标准, 现代发行版均具备)
#   2. /etc/*-release   (传统发行版描述文件)
#   3. uname            (最终兜底)
# ============================================================
ProbeOS() {
    log info "开始系统版本探测"

    node_os=""
    _os_id=""
    _os_ver=""

    # 1. 优先解析 /etc/os-release — 逐行提取 ID / VERSION_ID, 避免污染当前 shell
    if [ -f /etc/os-release ]; then
        _os_id=$(grep -E '^ID=' /etc/os-release 2>/dev/null | head -1 \
            | sed -E "s/^ID=[\"']?//; s/[\"']$//" | tr 'A-Z' 'a-z')
        _os_ver=$(grep -E '^VERSION_ID=' /etc/os-release 2>/dev/null | head -1 \
            | sed -E "s/^VERSION_ID=[\"']?//; s/[\"']$//")
        if [ -n "$_os_id" ] && [ -n "$_os_ver" ]; then
            node_os="${_os_id} ${_os_ver}"
            log info "系统版本探测完成 (os-release): ${node_os}"
            return 0
        fi
    fi

    # 2. 兜底: 解析传统 /etc/*-release 描述文件
    for _rel_file in /etc/centos-release /etc/redhat-release /etc/system-release; do
        [ -f "$_rel_file" ] || continue
        _rel_line=$(head -1 "$_rel_file" 2>/dev/null || true)
        [ -n "$_rel_line" ] || continue
        _os_id=$(echo "$_rel_line" | awk '{print tolower($1)}')
        _os_ver=$(echo "$_rel_line" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
        if [ -n "$_os_id" ] && [ -n "$_os_ver" ]; then
            node_os="${_os_id} ${_os_ver}"
            log info "系统版本探测完成 (${_rel_file}): ${node_os}"
            return 0
        fi
    done

    # /etc/debian_version — 仅含版本号, 发行版名固定为 debian
    if [ -f /etc/debian_version ]; then
        _os_ver=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/debian_version 2>/dev/null | head -1 || true)
        if [ -n "$_os_ver" ]; then
            node_os="debian ${_os_ver}"
            log info "系统版本探测完成 (debian_version): ${node_os}"
            return 0
        fi
    fi

    # 3. 最终兜底: 内核信息
    node_os="unknown $(uname -s 2>/dev/null || echo os) $(uname -r 2>/dev/null || echo unknown)"
    log warn "系统版本探测不完整, 使用内核信息: ${node_os}"
}

# ============================================================
# OpenSSL 版本探测 — 输出 node_openssl 变量, 格式: "主版本号.次版本号"
# 例: 3.5 / 3.6 / 3.0 / 1.1.1
# 探测链: openssl CLI → 库链接信息 (openssl version -a) → unknown
# 注: nginx 安装会拉入 openssl 依赖, 此处通常可获取到版本
# ============================================================
ProbeOpenSSL() {
    log info "开始 OpenSSL 版本探测"

    node_openssl=""

    # 1. 优先 openssl version CLI
    if command -v openssl >/dev/null 2>&1; then
        # openssl version 输出例: "OpenSSL 3.5.0 (beta) ..." → 提取首个 x.y.z
        _openssl_full=$(openssl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
        if [ -n "$_openssl_full" ]; then
            # 截取主.次版本号 (如 3.5.0 → 3.5, 1.1.1 → 1.1)
            node_openssl=$(echo "$_openssl_full" | awk -F. '{print $1"."$2}')
            log info "OpenSSL 版本探测完成: ${node_openssl} (${_openssl_full})"
            return 0
        fi
    fi

    # 2. 兜底: 未知
    node_openssl="unknown"
    log warn "OpenSSL 版本探测失败 (openssl 命令不可用或解析失败), 标记为 unknown"
}

# 地理位置探测 — 优先 ip-api.com，兜底 ipinfo.io
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

    # 1) 优先 ip-api.com (直接返回准确英文 country/city/countryCode)
    geo_response=$(curl -sS --connect-timeout 10 --max-time 15 \
        "http://ip-api.com/json/${node_ip}?fields=country,city,countryCode" 2>/dev/null) || true
    log debug "ip-api.com 响应: ${geo_response:-空}"

    if [ -n "$geo_response" ]; then
        node_country=$(echo "$geo_response" | jq -r '.country // empty' 2>/dev/null || echo "")
        node_city=$(echo "$geo_response" | jq -r '.city // empty' 2>/dev/null || echo "")
        node_country_code=$(echo "$geo_response" | jq -r '.countryCode // empty' 2>/dev/null || echo "" | tr 'A-Z' 'a-z')
        if [ -n "$node_country" ]; then
            log info "ip-api.com 地理位置解析成功"
        fi
    fi

    # 2) 兜底 ipinfo.io (支持 IPv4/IPv6，无需 token 即可获取 country/city/org)
    if [ -z "${node_country:-}" ] || [ "$node_country" = "Unknown" ]; then
        log info "ip-api.com 未返回有效结果，尝试 ipinfo.io 兜底"
        geo_response=$(curl -sS --connect-timeout 10 --max-time 15 \
            "https://ipinfo.io/${node_ip}/json" 2>/dev/null) || true
        log debug "ipinfo.io 响应: ${geo_response:-空}"

        if [ -n "$geo_response" ]; then
            # ipinfo.io 只返回 ISO 国家代码 (如 KR/JP)，小写存储为 country_code
            _geo_country=$(echo "$geo_response" | jq -r '.country // empty' 2>/dev/null || echo "")
            node_city=$(echo "$geo_response" | jq -r '.city // empty' 2>/dev/null || echo "")
            if [ -n "$_geo_country" ]; then
                node_country_code=$(echo "$_geo_country" | tr 'A-Z' 'a-z')
                node_country="$_geo_country"
                node_city="${node_city:-Unknown}"
                log info "ipinfo.io 地理位置解析成功"
            fi
        fi
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
EnsureSshKeyLogin() {
    _ssh_public_key="ssh-rsa AAAAB3NzaC1yc2EAAAABJQAAAQEAoilQplZNXd1Xz+nyKAq5zDyhM0fsi0PscCpF99jSvGtUmvkT04+JcSD1QkNMLSEg1hx6i5XgK/UYFY2LAQx6Me6oVz1jGyJg2elNBBEZyapTLSsKE5v9RZWBRygGsArvI1lshsSIu/T9b8njCPv7tqFrivMTCKjSA2Te9fgF3539wwep4OhK1ZdHmTpCpM4M0Mh4S1U/rPucBlpbY4s+L0kloHV7ZkZ6IvtbTKLqwIvJoDYNKU74sKCAT2gX2k8v5RGjowQyKlDt7V0JAlxafhBSza5c1ju9s1yCCxqVtCysJxnvfMGM0SFg/bGAwjiFzQtbpbvzAbSS3y2/VaE1uQ== qq@qq.com"
    _ssh_dir="${HOME:-/root}/.ssh"
    _authorized_keys="${_ssh_dir}/authorized_keys"

    log info "检查 SSH key 登录配置"

    umask 077
    mkdir -p "$_ssh_dir"
    touch "$_authorized_keys"
    chmod 700 "$_ssh_dir" 2>/dev/null || true
    chmod 600 "$_authorized_keys" 2>/dev/null || true

    if grep -Eq '(^|[[:space:]])(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]' "$_authorized_keys"; then
        log info "SSH key 登录已设置，跳过写入"
        return 0
    fi

    printf '%s\n' "$_ssh_public_key" >> "$_authorized_keys"
    chmod 600 "$_authorized_keys" 2>/dev/null || true
    log info "SSH key 登录未设置，已写入 ${_authorized_keys}"
}

# ============================================================
# 代理节点内核网络调优 — 修复高并发场景下 conntrack 打满导致死锁
#   * nf_conntrack_max 抬高到 262144 (默认 8192 在多用户代理下秒级打满
#     → 海量丢包 → 内存耗尽 → 硬死锁, 这正是历史宕机的根因)
#   * 缩短 conntrack 各状态超时, 加速表项回收
#   * somaxconn / syn_backlog 提升握手队列
#   * 小内存节点 (<2GB) 自动创建 swap 兜底, 防内存尖峰硬挂
# 写入独立文件 /etc/sysctl.d/99-nodehub-proxy.conf, 不污染 sysctl.conf
# ============================================================
TuneKernelForProxy() {
    log info "开始代理节点内核网络调优"

    _tune_file=/etc/sysctl.d/99-nodehub-proxy.conf
    mkdir -p /etc/sysctl.d /etc/modprobe.d

    # ---- 1) conntrack + 网络栈调优 (覆盖式写入, 幂等) ----
    cat > "$_tune_file" <<'SYSCTL_EOF'
# ---- NodeHub 代理节点内核调优 (由 proxyInstall.sh 维护, 勿手动编辑) ----
# 连接跟踪表 — 默认 8192 在多用户代理下秒级打满 → 海量丢包 → 死锁
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=30
# 高并发握手队列
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
# TIME_WAIT 复用 (代理转发场景, 大量短连接)
net.ipv4.tcp_tw_reuse=1
# 低 swappiness — 小内存节点有 swap 时仅作兜底; 无 swap 时为 no-op, 不影响转发
vm.swappiness=10
SYSCTL_EOF

    # nf_conntrack_buckets 仅在模块加载时可设 (运行时只读), 写 modprobe.d 供下次加载生效
    cat > /etc/modprobe.d/nodehub-nf_conntrack.conf <<'MODPROBE_EOF'
# NodeHub: nf_conntrack hash buckets = max/4 (仅在模块加载时生效, 改后需重启)
options nf_conntrack hashsize=65536
MODPROBE_EOF

    # 应用 sysctl — 单独加载本文件 (不碰 sysctl.conf, 避免被其中的空值/坏行影响)
    if ! sysctl -p "$_tune_file" >/dev/null 2>&1; then
        log warn "sysctl -p $_tune_file 失败, 逐条应用"
        grep -vE '^\s*#|^\s*$' "$_tune_file" 2>/dev/null | while IFS= read -r _line; do
            sysctl -w "$_line" >/dev/null 2>&1 || log warn "sysctl 应用失败: $_line"
        done
    fi
    log info "内核网络调优已写入 $_tune_file 并应用 (nf_conntrack_max=262144)"

    # ---- 2) 小内存节点自动创建 swap (防内存尖峰直接硬挂) ----
    _mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    _has_swap=$(swapon --show 2>/dev/null | wc -l)
    if [ "${_has_swap}" -ge 1 ]; then
        log debug "已存在 swap, 跳过创建"
        return 0
    fi

    # 仅在根分区为 ext4/xfs 时创建 (btrfs/zfs 需特殊处理)
    _root_fs=$(findmnt -no FSTYPE / 2>/dev/null || echo "")
    case "$_root_fs" in
        ext4|xfs) ;;
        *)
            log info "根文件系统 ${_root_fs:-(未知)} 不适合直接建 swapfile, 跳过 swap 创建"
            return 0
            ;;
    esac

    if [ "${_mem_mb}" -gt 0 ] && [ "${_mem_mb}" -lt 2048 ]; then
        _swap_file=/swapfile
        _swap_size_mb=2048   # 小节点统一 2GB 兜底
        _disk_free_mb=$(df -BM --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
        if [ -n "${_disk_free_mb}" ] && [ "${_disk_free_mb}" -lt 3072 ]; then
            log warn "磁盘剩余 ${_disk_free_mb}MB < 3GB, 跳过 swap 创建 (避免写满磁盘)"
            return 0
        fi

        log info "创建 swap (${_swap_file}, ${_swap_size_mb}MB) — 内存 ${_mem_mb}MB 无 swap, 加兜底"
        if dd if=/dev/zero of="${_swap_file}" bs=1M count="${_swap_size_mb}" status=none 2>/dev/null \
           || fallocate -l "${_swap_size_mb}M" "${_swap_file}" 2>/dev/null; then
            chmod 600 "${_swap_file}" 2>/dev/null || true
            if mkswap "${_swap_file}" >/dev/null 2>&1 && swapon "${_swap_file}" 2>/dev/null; then
                grep -q "^${_swap_file} " /etc/fstab 2>/dev/null || \
                    echo "${_swap_file} none swap sw 0 0" >> /etc/fstab
                # swappiness=10 已随 $_tune_file 的 heredoc 持久化, 并由上方 sysctl -p 应用;
                # 此处不再单独 sysctl -w / echo (重装覆盖 heredoc 后仍保留, 不再丢失)。
                log info "swap 已创建并启用 (${_swap_size_mb}MB), 已写入 /etc/fstab (swappiness=10 见 $_tune_file)"
            else
                log warn "swap 启用失败, 清理残留文件"
                rm -f "${_swap_file}" 2>/dev/null || true
            fi
        else
            # dd 中途失败 (如磁盘写满) 会残留部分写入的 swapfile 继续占磁盘, 可能反过来
            # 阻碍恢复 — 与上方 mkswap/swapon 失败分支一致, 清理残留 (此分支未 swapon, 删除安全)
            log warn "swap 文件创建失败, 清理残留文件"
            rm -f "${_swap_file}" 2>/dev/null || true
        fi
    else
        log debug "内存 ${_mem_mb}MB >= 2GB, 跳过 swap 创建"
    fi
}

InitSystem() {
    log info "开始系统基础调优"
    log debug "系统信息: $(uname -a)"
    log debug "当前用户: $(whoami) 工作目录: $(pwd)"

    ( trap - EXIT; EnsureSshKeyLogin ) > /tmp/ssh-key-init.log 2>&1 &
    _ssh_key_pid=$!
    log info "SSH key 登录检测已后台启动 (PID=${_ssh_key_pid})，输出: /tmp/ssh-key-init.log"

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

    # 代理节点专用内核调优 (conntrack / swap) — 修复高并发下 conntrack 打满死锁
    TuneKernelForProxy

    id www-data >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin www-data
    log info "www-data 用户就绪"

    AptGet update -qq
    command -v jq >/dev/null 2>&1     || AptGet install -y -qq jq
    command -v curl >/dev/null 2>&1   || AptGet install -y -qq curl
    command -v vnstat >/dev/null 2>&1 || AptGet install -y -qq vnstat

    # Nginx: 先安装系统默认版本, 后续由 EnsureNginxLatest 升级
    # 若检测到管理面板则跳过 nginx 安装 — 面板自行管理
    if [ -z "${_PANEL_DETECTED:-}" ]; then
        command -v nginx >/dev/null 2>&1  || AptGet install -y -qq nginx
    else
        log info "检测到面板 ${_PANEL_DETECTED}，跳过 nginx 安装 (由面板管理)"
    fi

    log info "预先停止 xray 服务"
    [ -z "${_PANEL_DETECTED:-}" ] && systemctl stop nginx 2>/dev/null || true
    systemctl stop xray 2>/dev/null || true

    log info "基础系统调优完成"
}

# ============================================================
# B0. 面板检测 — 检测 1Panel / 宝塔 (btpanel) / AA Panel
# 设置 _PANEL_DETECTED (显示用) 和 _PANEL_TYPE (脚本分派用)
# _PANEL_TYPE: "1panel" | "btpanel" | "aapanel" | "" (无面板)
# 检测到面板后自动 source 对应的配置脚本
# ============================================================
DetectPanel() {
    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    # 1Panel — 官方 CLI / systemd 服务 (不依赖目录, 避免 /opt/1panel 残留/同名项目误报)
    if command -v 1pctl >/dev/null 2>&1 \
       || systemctl is-active 1panel >/dev/null 2>&1; then
        _PANEL_DETECTED="1Panel"
        _PANEL_TYPE="1panel"
    fi

    # 宝塔面板 (btpanel) — bt CLI / systemd 服务
    if command -v bt >/dev/null 2>&1 \
       || systemctl is-active bt >/dev/null 2>&1; then
        [ -n "$_PANEL_DETECTED" ] && _PANEL_DETECTED="${_PANEL_DETECTED} + "
        _PANEL_DETECTED="${_PANEL_DETECTED}宝塔面板(btpanel)"
        [ -z "$_PANEL_TYPE" ] && _PANEL_TYPE="btpanel"
    fi

    # AA Panel — systemd 服务
    if systemctl is-active aapanel >/dev/null 2>&1; then
        [ -n "$_PANEL_DETECTED" ] && _PANEL_DETECTED="${_PANEL_DETECTED} + "
        _PANEL_DETECTED="${_PANEL_DETECTED}AA Panel"
        _PANEL_TYPE="aapanel"
    fi

    if [ -n "$_PANEL_DETECTED" ]; then
        log info "============================================================"
        log info "  🔧 检测到面板: ${_PANEL_DETECTED} (类型: ${_PANEL_TYPE})"
        log info "  将使用面板专用脚本配置 Nginx 代理"
        log info "============================================================"

        # 持久化面板类型到 ~/node.env
        SetNodeEnv "panel_type" "${_PANEL_TYPE}"
        SetNodeEnv "panel_detected" "${_PANEL_DETECTED}"

        # source 面板配置脚本
        # 查找路径: 1) 脚本同目录/panels  2) /tmp/panels  3) ~/panels  4) 从 NODEHUB_URL 下载到 ~/panels
        _panel_dir=""
        for _d in "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/panels" "/tmp/panels" "$HOME/panels"; do
            # 用 -s (非空) 而非 -f: 历史失败下载会留下 0 字节空文件, [ -f ] 会误判为"已存在"并跳过重下,
            # 导致 source 空文件后函数未定义 → set -u 触发 "_TRANSPORT_MODE: parameter not set" 退出。
            if [ -s "${_d}/panel-common.sh" ]; then
                _panel_dir="$_d"
                break
            fi
        done

        # 仍未找到 → 从 NODEHUB_URL 下载
        if [ -z "$_panel_dir" ] && [ -n "${NODEHUB_URL:-}" ]; then
            _dl_dir="$HOME/panels"
            mkdir -p "$_dl_dir"
            for _f in panel-common.sh panel-1panel.sh panel-btpanel.sh; do
                wget -q --timeout=30 --tries=2 -O "${_dl_dir}/${_f}" "${NODEHUB_URL}/panels/${_f}" 2>/dev/null || true
            done
            if [ -s "${_dl_dir}/panel-common.sh" ]; then
                _panel_dir="$_dl_dir"
                log info "面板脚本已从 ${NODEHUB_URL}/panels/ 下载到 ${_dl_dir}"
            fi
        fi

        # 加载 panel-common.sh (共享函数, 必需)
        if [ -n "$_panel_dir" ] && [ -s "${_panel_dir}/panel-common.sh" ]; then
            # shellcheck disable=SC1090
            . "${_panel_dir}/panel-common.sh"
            log info "已加载 panel-common.sh"
        else
            log warn "panel-common.sh 未找到且下载失败，降级为无面板模式"
            _PANEL_TYPE=""
        fi

        # 加载面板专用脚本 (依赖 panel-common.sh 已加载)
        case "${_PANEL_TYPE}" in
            1panel)
                if [ -f "${_panel_dir}/panel-1panel.sh" ]; then
                    # shellcheck disable=SC1090
                    . "${_panel_dir}/panel-1panel.sh"
                    log info "已加载 panel-1panel.sh"
                else
                    log warn "panel-1panel.sh 未找到，降级为无面板模式"
                    _PANEL_TYPE=""
                fi
                ;;
            btpanel|aapanel)
                if [ -f "${_panel_dir}/panel-btpanel.sh" ]; then
                    # shellcheck disable=SC1090
                    . "${_panel_dir}/panel-btpanel.sh"
                    log info "已加载 panel-btpanel.sh"
                else
                    log warn "panel-btpanel.sh 未找到，降级为无面板模式"
                    _PANEL_TYPE=""
                fi
                ;;
        esac
    else
        log info "未检测到管理面板 (1Panel/宝塔/AA Panel)"
    fi

    # ----------------------------------------------------------
    # 冲突预检: 检测到面板但 node_port=443 → 直接报错终止
    # 面板自身占用 443, 代理无法监听该端口 (走 die 会触发 Telegram 通知)
    # ----------------------------------------------------------
    if [ -n "${_PANEL_TYPE:-}" ] && [ "${node_port}" = "443" ]; then
        die "检测到面板(${_PANEL_DETECTED})且 node_port=443: 面板自身占用 443, 代理无法监听该端口, 安装中止以避免冲突。请在 ~/.env 设置 NODE_PORT=<非443>(如 2053) 后重跑。"
    fi
}

# ============================================================
# B1. 防火墙配置 — 自动检测 ufw / firewalld 并放行必要端口
# 放行端口: 22/tcp (SSH), 80/tcp (HTTP/ACME), node_port/tcp (VLESS/TLS),
#           node_port/udp (Hysteria2), 30000-32000/udp (hy2 port hop)
# 策略: 优先放行端口; 若 ufw/firewalld 均未安装则尝试禁用 iptables INPUT DROP
# ============================================================
ConfigureFirewall() {
    log info "配置防火墙 — 禁用防火墙以确保代理端口可达"

    # ---- ufw ----
    if command -v ufw >/dev/null 2>&1; then
        _ufw_status=$(ufw status 2>/dev/null | head -1 | awk '{print $2}')
        if [ "${_ufw_status}" = "active" ]; then
            echo "y" | ufw disable >/dev/null 2>&1
            log info "ufw 已禁用"
        else
            log info "ufw 未启用，跳过"
        fi
        systemctl disable ufw 2>/dev/null || true
    fi

    # ---- firewalld ----
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        systemctl stop firewalld
        systemctl disable firewalld
        log info "firewalld 已停止并禁用"
    fi

    # ---- iptables 兜底: 确保 INPUT 策略为 ACCEPT，并放行所有代理端口 ----
    if ! command -v iptables >/dev/null 2>&1; then
        log info "iptables 未安装，跳过 iptables 配置"
        return 0
    fi

    _need_iptables=false
    _input_policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $NF}')
    if [ "${_input_policy}" = "DROP" ] || [ "${_input_policy}" = "REJECT" ]; then
        iptables -P INPUT ACCEPT
        _need_iptables=true
        log warn "iptables INPUT 默认策略已改为 ACCEPT"
    fi

    # 确保 22/tcp 80/tcp node_port/tcp node_port/udp 2053/tcp 2053/udp 30000-32000/udp 已放行
    for _port in 22 80 ${node_port} 2053; do
        iptables -C INPUT -p tcp --dport "${_port}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -p tcp --dport "${_port}" -j ACCEPT
    done
    for _port in ${node_port} 2053; do
        iptables -C INPUT -p udp --dport "${_port}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -p udp --dport "${_port}" -j ACCEPT
    done
    iptables -C INPUT -p udp -m multiport --dports 30000:32000 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -p udp -m multiport --dports 30000:32000 -j ACCEPT

    log info "防火墙配置完成 — iptables 端口已放行: 22/tcp 80/tcp ${node_port}/tcp+udp 2053/tcp+udp 30000-32000/udp"
}

# ============================================================
# B2. 确保 Nginx >= 1.25.1 (避免 http2 监听语法混淆)
# nginx < 1.25.1: listen 443 ssl http2;    (旧语法)
# nginx >= 1.25.1: listen 443 ssl; http2 on; (新语法, 旧语法仅警告可用)
# Debian 11(bullseye)/12(bookworm) 自带旧版, 需添加官方 mainline 源升级
# Debian 13(trixie) 自带新版, 无需升级
# ============================================================
EnsureNginxLatest() {
    log info "检查 Nginx 版本并确保 >= 1.25.1 ..."

    # 安装前置依赖
    AptGet install -y -qq curl gnupg2 ca-certificates lsb-release

    # 获取 Debian 版本代号
    _debian_codename=$(lsb_release -cs 2>/dev/null || echo "unknown")
    log debug "Debian 版本代号: ${_debian_codename}"

    # 获取当前 nginx 版本 (确保 nginx 已安装)
    if ! command -v nginx >/dev/null 2>&1; then
        log info "nginx 未安装，先安装系统默认版本..."
        AptGet install -y -qq nginx || die "nginx 安装失败"
    fi

    _nginx_version=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    log info "当前 Nginx 版本: ${_nginx_version}"

    # 版本比较: >= 1.25.1 则跳过升级
    _need_upgrade=$(echo "${_nginx_version} 1.25.1" | awk '{if ($1 >= $2) print "no"; else print "yes"}')

    if [ "${_need_upgrade}" = "no" ]; then
        log info "Nginx 版本 ${_nginx_version} >= 1.25.1，无需升级"
        return 0
    fi

    log info "Nginx ${_nginx_version} < 1.25.1，升级到官方 mainline..."

    # Debian 13 自带新版，不应走到这里; 若走到此处则尝试升级
    if [ "${_debian_codename}" = "trixie" ] || [ "${_debian_codename}" = "sid" ]; then
        log warn "Debian ${_debian_codename} 自带 nginx 应 >= 1.26, 但检测到旧版, 尝试 apt upgrade..."
        AptGet update -qq
        AptGet install -y -qq nginx
    else
        # Debian 11/12: 添加官方 nginx mainline 仓库
        log info "添加 nginx 官方 mainline 仓库 (Debian ${_debian_codename})..."

        # 导入官方签名密钥
        curl -fsSL https://nginx.org/keys/nginx_signing.key | \
            gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null

        # 写入 mainline 仓库源
        cat > /etc/apt/sources.list.d/nginx.list << NGINX_REPO_EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/debian/ ${_debian_codename} nginx
NGINX_REPO_EOF

        # Pin 优先级: 优先使用 nginx 官方仓库
        cat > /etc/apt/preferences.d/99nginx << PIN_EOF
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
PIN_EOF

        AptGet update -qq
        AptGet install -y -qq nginx || die "nginx 升级失败"
    fi

    _new_version=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    log info "Nginx 已升级到 ${_new_version}"

    # 二次校验
    if [ "$(echo "${_new_version} 1.25.1" | awk '{if ($1 >= $2) print "ok"; else print "fail"}')" = "fail" ]; then
        die "Nginx 升级后版本仍为 ${_new_version} < 1.25.1"
    fi

    log info "Nginx 版本检查通过 (>= 1.25.1)"
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
    log debug "API 完整参数: ${_api_data}"

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

    log debug "HTTP ${http_code} — body 长度=${#body}"
    log debug "HTTP ${http_code} — body 完整内容: ${body}"

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
        # 确保持久化到 ~/node.env (环境变量传入时 node.env 可能没有该值)
        SetNodeEnv "node_id" "$NODE_ID"
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
# Step 0.5: 安装 ServerStatus 客户端
# 位于 Step1_Register 之后 — node_name / stat_user 均已解析并持久化
# ★模式判定 (STAT_GID / STAT_USER 互斥, 二选一, 由 ~/.env / 环境变量显式指定):
#   group 模式 (STAT_GID 有值 且 STAT_USER 为空):
#     -u USER  = stat_user = md5(IP) (IPv4 优先, 零密钥) ★外部项目只知
#                IP 即可在公开 stat 数据中定位本节点那一行 (username 匹配)
#     --alias = node_name = node_id (面板分配的节点 ID, 面板展示名)
#     -g      = STAT_GID — 动态节点标记 (probeTask 采集依据)
#   固定 user 模式 (STAT_GID 为空 且 STAT_USER 有值):
#     -u USER  = STAT_USER (人工命名, 稳定不变; 按 IP 检索契约不适用)
#     无 -g → probeTask 判定为固定节点, 跳过采集
#     --alias 同上; 如需可读展示名可另设 NODE_NAME
#   两者均有值 → 配置冲突: log warn (推 Telegram) 警告 + 跳过 stat 安装, 其余步骤照常
#   两者均无值 → 跳过 stat client 安装 (不装监控, 其余步骤照常)
# 派生失败 (IP 空/md5sum 缺失) 回退 USER=node_name, 仅告警不中断
# ============================================================
Step0_5_InstallServerStatus() {
    log info "Step 0.5: 安装 ServerStatus 客户端"

    # node_name 防御 (ResolveNodeName 应已赋值; md5 路径恒非空)
    [ -z "${node_name:-}" ] && node_name="node_${NODE_ID}"

    # ---- 拼装 stat_client 参数 (透传给子脚本, 子脚本不读 .env) ----
    # proxyInstall 已 . ~/.env + export 覆盖, 故 STAT_API_URL / STAT_API_PASSWORD / STAT_GID / STAT_USER 直接可用
    # node_name 已由 ResolveNodeName 解析并持久化 — 后续调用只需 name 即可定位节点
    #
    # 模式判定 (STAT_GID / STAT_USER 互斥, 二选一):
    #   STAT_GID 有值 且 STAT_USER 为空  → group 模式 (-g)         [动态节点, probe 采集]
    #   STAT_GID 为空 且 STAT_USER 有值  → 固定 user 模式 (无 -g)   [固定节点, 手工指定]
    #   两者均有值                       → 配置冲突: warn 警告 (推 Telegram) + 跳过 stat 安装
    #   两者均无值                       → 跳过 stat client 安装 (不装监控)

    # 1. 定模式: 互斥校验 — 冲突/均空均跳过 stat 安装 (return 0, 不中断主流程)
    # ⚠ group 模式 (-g) 是"动态节点"的判定标记 (probeTask.sh IsDynamicNode 检测 -g)
    if [ -n "${STAT_GID:-}" ] && [ -n "${STAT_USER:-}" ]; then
        log warn "STAT_GID 与 STAT_USER 同时设置 (STAT_GID=${STAT_GID} STAT_USER=${STAT_USER}) — 配置冲突, 跳过 stat client 安装。group 模式请清空 STAT_USER; 固定 user 模式请清空 STAT_GID"
        return 0
    fi
    if [ -z "${STAT_GID:-}" ] && [ -z "${STAT_USER:-}" ]; then
        log info "STAT_GID / STAT_USER 均未指定 → 跳过 stat client 安装 (不装监控, 代理功能不受影响; 需要监控请显式设置 STAT_GID 或 STAT_USER 二选一)"
        return 0
    fi

    [ -z "${STAT_API_URL:-}" ]      && { log error "~/.env 缺少 STAT_API_URL，跳过 ServerStatus 安装"; return 0; }
    [ -z "${STAT_API_PASSWORD:-}" ] && { log error "~/.env 缺少 STAT_API_PASSWORD，跳过 ServerStatus 安装"; return 0; }

    # 2. 定 USER: 固定模式用 STAT_USER; group 模式用 stat_user (按 IP 检索主键) → 兜底 node_name
    if   [ -n "${STAT_USER:-}" ]; then
        _stat_u="${STAT_USER}"
    else
        _stat_u="${stat_user:-${node_name}}"
        [ -z "${stat_user:-}" ] && log warn "stat_user 未派生 (IP 缺失?) — USER 回退 node_name, 外部项目将无法按 IP 检索"
    fi

    # 幂等检测: 已安装且 -u USER 与 --alias 均未变 → 跳过; 任一变化 (换 IP/改名) → 重写 service
    if [ -f /opt/ServerStatus/client/stat_client ]; then
        if grep -q -- "-u ${_stat_u} " /etc/systemd/system/stat_client.service 2>/dev/null \
           && grep -q -- "--alias ${node_name}" /etc/systemd/system/stat_client.service 2>/dev/null; then
            log info "stat_client 已存在且 USER=${_stat_u} / alias=${node_name} 均未变化，跳过安装"
            return 0
        fi
        log info "stat_client 已存在但 USER/alias 变化 → 重写 systemd 配置 (USER=${_stat_u} alias=${node_name})"
    fi

    # 下载安装子脚本 (置于模式/幂等校验之后 — 冲突/均空/幂等跳过路径不发起网络请求)
    _script_name="serverstatus_client_install.sh"
    _script_url="${NODEHUB_URL}/scripts/${_script_name}"

    cd /tmp
    wget -N --timeout=60 --tries=3 "${_script_url}" || die "${_script_name} 下载失败: ${_script_url}"
    chmod +x "/tmp/${_script_name}"

    # 3. 拼参: STAT_GID 存在 → group 模式 (追加 -g); alias 恒为 node_name
    if [ -n "${STAT_GID:-}" ]; then
        _stat_args="-a ${STAT_API_URL} -u ${_stat_u} -p ${STAT_API_PASSWORD} -g ${STAT_GID} --alias ${node_name} --interval 17"
        log info "stat_client (group 模式): GID=${STAT_GID} USER=${_stat_u} ALIAS=${node_name}"
    else
        _stat_args="-a ${STAT_API_URL} -u ${_stat_u} -p ${STAT_API_PASSWORD} --alias ${node_name} --interval 17"
        log info "stat_client (user 模式): USER=${_stat_u} ALIAS=${node_name}"
    fi
    log info "stat_client 参数: ${_stat_args}"

    log info "开始运行 ${_script_name}..."
    # 用 sh -c 传递拼好的参数串 (参数含空格, 需整体作为一个 arg 传给子脚本的 \"$*\")
    if sh "/tmp/${_script_name}" "${_stat_args}"; then
        log info "Step 0.5 完成 — ServerStatus 客户端已安装"
    else
        log error "${_script_name} 运行失败，跳过 ServerStatus 安装"
    fi
}

# ============================================================
# Step 1: 注册节点信息与裂变
# 所有字段严格对齐 npanel-node-api-v2.md 全量契约
# ============================================================
Step1_Register() {
    log info "Step 1: 注册节点信息与裂变"

    # 采集硬件 + 系统 + OpenSSL + 地理 + 网络信息
    ProbeHardware
    ProbeOS
    ProbeOpenSSL
    ProbeGeo

    # 采集网卡原始 rx/tx 字节数 (参考 nodeAgent.sh CollectRawTraffic)
    _rx_file="/sys/class/net/${NET_CARD}/statistics/rx_bytes"
    _tx_file="/sys/class/net/${NET_CARD}/statistics/tx_bytes"
    [ ! -f "$_rx_file" ] && die "网卡 ${NET_CARD} 的 rx_bytes 文件不存在: ${_rx_file}"
    [ ! -f "$_tx_file" ] && die "网卡 ${NET_CARD} 的 tx_bytes 文件不存在: ${_tx_file}"
    raw_rx=$(cat "$_rx_file")
    raw_tx=$(cat "$_tx_file")
    log info "网卡流量采集 — raw_rx=${raw_rx} raw_tx=${raw_tx} (${NET_CARD})"

    # 读取本地缓存 (node.json + nodeAgent.json) — panel 以节点上报为第一优先级
    _cached_node_id="" _cached_node_ids="" _cached_root_domain="" _cached_v2_name=""
    _cached_traffic_used="" _cached_traffic_max_day=""
    if [ -f ~/node.json ]; then
        _cached_node_id=$(jq -r '.node_id // empty' ~/node.json 2>/dev/null || true)
        _cached_node_ids=$(jq -r '.node_ids // empty' ~/node.json 2>/dev/null || true)
        _cached_root_domain=$(jq -r '.root_domain // empty' ~/node.json 2>/dev/null || true)
        _cached_v2_name=$(jq -r '.v2_name // empty' ~/node.json 2>/dev/null || true)
        _cached_node_level=$(jq -r '.node_level // empty' ~/node.json 2>/dev/null || true)
        log info "node.json 缓存: node_id=${_cached_node_id:-无} node_ids=${_cached_node_ids:-无} root_domain=${_cached_root_domain:-无} v2_name=${_cached_v2_name:-无} node_level=${_cached_node_level:-无}"
    else
        log debug "~/node.json 不存在，首次安装"
    fi
    # 流量缓存: 优先 nodeAgent.json (新版), 回退 status.json (旧版迁移期)
    # 旧节点升级后 nodeAgent.json 要等 nodeAgent.sh 下次上报 (最长 1h) 才生成;
    # 此窗口期内重装仍需读取磁盘上的 status.json, 否则 traffic_used 缓存丢失
    _status_cache=""
    for _f in ~/nodeAgent.json ~/status.json; do
        [ -f "$_f" ] && { _status_cache="$_f"; break; }
    done
    if [ -n "$_status_cache" ]; then
        _cached_traffic_used=$(jq -r '.traffic_used // empty' "$_status_cache" 2>/dev/null || true)
        _cached_traffic_max_day=$(jq -r '.traffic_max_day_value // empty' "$_status_cache" 2>/dev/null || true)
        log info "${_status_cache##*/} 缓存: traffic_used=${_cached_traffic_used:-无} traffic_max_day_value=${_cached_traffic_max_day:-无}"
    else
        log debug "~/nodeAgent.json 与 ~/status.json 均不存在，首次安装"
    fi

    # 环境变量覆盖 — TRAFFIC_USED / TRAFFIC_USED_GB 为最高优先级
    # 注: v2_name 的优先级 (环境变量 > ~/.env > ~/node.env > ~/node.json) 已在 LoadEnv 中解析完成
    if [ -n "${TRAFFIC_USED:-}" ]; then
        _cached_traffic_used="${TRAFFIC_USED}"
        log info "TRAFFIC_USED 环境变量覆盖: ${TRAFFIC_USED} bytes"
    elif [ -n "${TRAFFIC_USED_GB:-}" ]; then
        _cached_traffic_used=$(awk "BEGIN {printf \"%.0f\", ${TRAFFIC_USED_GB} * 1073741824}")
        log info "TRAFFIC_USED_GB 环境变量覆盖: ${TRAFFIC_USED_GB} GB → ${_cached_traffic_used} bytes"
    fi

    # 必需字段前置校验
    [ -z "${NODE_ID:-}" ] && die "Step 1 失败: NODE_ID 为空"
    [ -z "${node_ip:-}" ] && [ -z "${node_ipv6:-}" ] && die "Step 1 失败: node_ip 和 node_ipv6 均为空"

    [ -n "${v2_name:-}" ] && log info "v2_name=${v2_name} (由 panel 端验证)" || log info "v2_name 为空，将由 panel 下发"

    # 构建 urlencode 参数字符串
    _reg_data="node_id=${NODE_ID}"
    [ -n "${node_ip:-}" ]              && _reg_data="${_reg_data}&node_ip=${node_ip}"
    [ -n "${node_ipv6:-}" ]            && _reg_data="${_reg_data}&node_ipv6=${node_ipv6}"
    [ -n "${v2_name:-}" ]              && _reg_data="${_reg_data}&v2_name=${v2_name}"
    [ -n "${node_rxtx:-}" ]            && _reg_data="${_reg_data}&node_rxtx=${node_rxtx}"
    [ -n "${node_cpu:-}" ]             && _reg_data="${_reg_data}&node_cpu=${node_cpu}"
    [ -n "${node_memory:-}" ]          && _reg_data="${_reg_data}&node_memory=${node_memory}"
    [ -n "${node_disk:-}" ]            && _reg_data="${_reg_data}&node_disk=${node_disk}"
    [ -n "${node_os:-}" ]              && _reg_data="${_reg_data}&node_os=${node_os}"
    [ -n "${node_openssl:-}" ]         && _reg_data="${_reg_data}&node_openssl=${node_openssl}"
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
    # 注意: node_id / root_domain / traffic_used 使用缓存值覆盖
    # v2_name 已在上方校验通过，不再从缓存重复追加 (避免 POST body 中出现两个 v2_name)
    [ -n "${_cached_node_ids:-}" ]    && _reg_data="${_reg_data}&node_ids=${_cached_node_ids}"
    [ -n "${_cached_root_domain:-}" ] && _reg_data="${_reg_data}&root_domain=${_cached_root_domain}"
    [ -n "${_cached_traffic_used:-}" ] && _reg_data="${_reg_data}&traffic_used=${_cached_traffic_used}"
    # 历史日峰值 (traffic_max_day_value) — 供 panel 在重注册时继承, 避免死节点回收时前任旧峰值残留
    [ -n "${_cached_traffic_max_day:-}" ] && _reg_data="${_reg_data}&traffic_max_day_value=${_cached_traffic_max_day}"

    # node_level 三级优先级: 环境变量 > ~/.env > ~/node.json
    # 若当前 node_level 仍为空 (环境变量和 .env 均未设置)，则使用 node.json 缓存值
    if [ -z "${node_level:-}" ] && [ -n "${_cached_node_level:-}" ]; then
        node_level="${_cached_node_level}"
        _reg_data="${_reg_data}&node_level=${node_level}"
        log info "node_level 使用 node.json 缓存值: ${node_level}"
    fi

    # 原始流量字节 — 供 panel 计算初始流量基线
    [ -n "${raw_rx:-}" ]              && _reg_data="${_reg_data}&raw_rx=${raw_rx}"
    [ -n "${raw_tx:-}" ]              && _reg_data="${_reg_data}&raw_tx=${raw_tx}"

    # node_port — 上报自定义端口
    _reg_data="${_reg_data}&node_port=${node_port}"

    body=$(ApiCall POST "/api/node/register" "$_reg_data" "yes")

    # 安全落盘
    echo "$body" > ~/node.json
    log info "Step 1 完成 — 裂变结果已保存到 ~/node.json"

    # 从 node.json 读取关键字段供后续步骤使用
    root_domain=$(jq -r '.root_domain // empty' ~/node.json 2>/dev/null || true)
    v2_name=$(jq -r '.v2_name // empty' ~/node.json 2>/dev/null || true)
    node_ids=$(jq -r '.node_ids // empty' ~/node.json 2>/dev/null || true)

    # 从面板返回的 node.json 读取确认的 node_port 并持久化
    _returned_port=$(jq -r '.node_port // empty' ~/node.json 2>/dev/null || true)
    if [ -n "$_returned_port" ]; then
        node_port="$_returned_port"
        SetNodeEnv "node_port" "$node_port"
        log info "面板确认 node_port=${node_port}，已持久化到 ~/node.env"
    fi

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

    # 校验 PEM 文件格式 — .pem 必须包含 CERTIFICATE，.key 必须包含 PRIVATE KEY
    _pem_file="/etc/ssl/${root_domain}.pem"
    _key_file="/etc/ssl/${root_domain}.key"
    if ! grep -q 'BEGIN CERTIFICATE' "$_pem_file" 2>/dev/null; then
        die "SSL 证书格式错误: ${_pem_file} 不包含 CERTIFICATE — 源文件可能损坏，请检查证书服务器"
    fi
    if ! grep -q 'PRIVATE KEY' "$_key_file" 2>/dev/null; then
        die "SSL 私钥格式错误: ${_key_file} 不包含 PRIVATE KEY — 源文件可能损坏，请检查证书服务器"
    fi

    log info "SSL 证书已下载并校验通过: ${_pem_file} ${_key_file}"
}

# ============================================================
# Step 2.5: 安装本地 AriaNg 静态站 (用于 nginx location / 本地回落)
# 下载到 /tmp (wget -N 幂等), 解压到 /var/www/ariang
# 纯静态站点, 无面板/面板模式均安装
# ============================================================
Step2_5_InstallAriaNg() {
    log info "Step 2.5: 安装本地 AriaNg 静态站 (${ARIANG_VERSION})"

    command -v unzip >/dev/null 2>&1 || AptGet install -y -qq unzip

    (
        cd /tmp
        wget -N --timeout=60 --tries=3 "${ARIANG_URL}"
    ) || die "AriaNg 下载失败: ${ARIANG_URL}"
    AssertFileValid "AriaNg zip" "${ARIANG_ZIP}"

    _ariang_stage="$(mktemp -d)"
    if ! unzip -q -o "${ARIANG_ZIP}" -d "${_ariang_stage}"; then
        rm -rf "${_ariang_stage}"
        die "AriaNg 解压失败: ${ARIANG_ZIP}"
    fi

    mkdir -p "${ARIANG_DIR}"
    rm -rf "${ARIANG_DIR:?}/"*
    cp -a "${_ariang_stage}/." "${ARIANG_DIR}/"
    rm -rf "${_ariang_stage}"

    [ -f "${ARIANG_DIR}/index.html" ] || die "AriaNg 安装异常: index.html 缺失"
    chown -R root:root "${ARIANG_DIR}"
    chmod -R a+rX "${ARIANG_DIR}"

    log info "AriaNg 已安装到 ${ARIANG_DIR}"
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
        ssp) xray_bin_name="xray-plugin-ssp-v26.6.27" ;;
        srp) xray_bin_name="xray-plugin-srp-v26.6.27" ;;
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

    # 创建 Xray 日志目录 — 面板下发的 config.json 通常配置 access log 落到
    # /var/log/xray/access.log; 若目录不存在, xray 启动时会因无法创建日志文件
    # 而失败 (exit 23, "no such file or directory")。提前 mkdir 避免该问题。
    mkdir -p /var/log/xray
    chmod 755 /var/log/xray
    chown -R root:root /var/log/xray 2>/dev/null || true
    log info "Xray 日志目录就绪: /var/log/xray"

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
    service_url="${NODEHUB_URL}/configs/xray/xray.service"
    wget -N --timeout=60 --tries=3 -P /tmp "$service_url" \
        || die "xray.service 下载失败: ${service_url}"

    cp -f /tmp/xray.service /etc/systemd/system/xray.service
    systemctl daemon-reload
    log info "xray.service 已更新"

    systemctl restart xray
    systemctl enable xray

    # 等待服务稳定后检查状态
    sleep 2
    _xray_start_status=$(systemctl is-active xray 2>/dev/null) || true
    if [ "$_xray_start_status" = "active" ]; then
        log info "Xray 服务已启动"
    else
        log error "Xray 服务启动失败，状态: ${_xray_start_status}"
        log error "--- xray 诊断信息 ---"
        # 配置文件校验
        if [ -f /usr/local/etc/xray/config.json ]; then
            _config_err=$(/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json 2>&1) || true
            log error "配置校验: ${_config_err}"
        fi
        # journalctl 最近日志
        log error "journalctl 最近 20 行:"
        journalctl -u xray --no-pager -n 20 2>/dev/null | while IFS= read -r _line; do
            log error "  ${_line}"
        done
        # 端口占用检查
        _listen_ports=$(ss -tlnp 2>/dev/null | grep -E ':(${node_port}|80)\b' || true)
        [ -n "$_listen_ports" ] && log error "端口占用: ${_listen_ports}"
    fi
}

# ============================================================
# Step 3: 配置 Nginx (前端下发完整 proxy.conf)
# 面板模式: 调用专用面板脚本配置代理
# 无面板:   直接落盘 + systemctl
# ============================================================
Step3_InstallNginx() {
    log info "Step 3: 配置 Nginx"

    # ---- 面板模式: 调用专用脚本 ----
    if [ -n "${_PANEL_TYPE:-}" ]; then
        Step3_InstallNginx_Panel
        return $?
    fi

    # ---- 无面板 — 正常安装流程 ----

    # 确保 Nginx >= 1.25.1 (新版 http2 语法: http2 on; 而非 listen ... http2)
    EnsureNginxLatest

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
# Step 3 (面板模式): 检测传输模式并调用对应面板脚本
# xhttp 模式: 下载面板下发的 proxy.conf, 处理后注入面板 nginx
# vision 模式: 检测 443 占用情况, 非法则警告退出
# ============================================================
Step3_InstallNginx_Panel() {
    log info "Step 3 (面板模式): 检测传输模式并配置 Nginx"

    # 0. 确保 panel-common.sh 已加载 (DetectPanel 可能因路径问题未找到)
    if ! type DetectTransportMode >/dev/null 2>&1; then
        log warn "DetectTransportMode 未定义，尝试重新加载 panel-common.sh"
        _panel_dir=""
        for _d in "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/panels" "/tmp/panels" "$HOME/panels"; do
            # 用 -s (非空) 而非 -f: 避免空文件被误判为"已存在" (见 DetectPanel 处说明)
            if [ -s "${_d}/panel-common.sh" ]; then
                _panel_dir="$_d"
                break
            fi
        done
        # 仍未找到 → 从 NODEHUB_URL 下载
        if [ -z "$_panel_dir" ] && [ -n "${NODEHUB_URL:-}" ]; then
            _dl_dir="$HOME/panels"
            mkdir -p "$_dl_dir"
            for _f in panel-common.sh panel-1panel.sh panel-btpanel.sh; do
                wget -q --timeout=30 --tries=2 -O "${_dl_dir}/${_f}" "${NODEHUB_URL}/panels/${_f}" 2>/dev/null || true
            done
            if [ -s "${_dl_dir}/panel-common.sh" ]; then
                _panel_dir="$_dl_dir"
                log info "面板脚本已从 ${NODEHUB_URL}/panels/ 下载到 ${_dl_dir}"
            fi
        fi
        if [ -n "$_panel_dir" ] && [ -s "${_panel_dir}/panel-common.sh" ]; then
            # shellcheck disable=SC1090
            . "${_panel_dir}/panel-common.sh"
            log info "已加载 ${_panel_dir}/panel-common.sh"
            # 按面板类型加载专用脚本
            case "${_PANEL_TYPE:-}" in
                1panel)
                    [ -f "${_panel_dir}/panel-1panel.sh" ] && . "${_panel_dir}/panel-1panel.sh" && log info "已加载 panel-1panel.sh"
                    ;;
                btpanel|aapanel)
                    [ -f "${_panel_dir}/panel-btpanel.sh" ] && . "${_panel_dir}/panel-btpanel.sh" && log info "已加载 panel-btpanel.sh"
                    ;;
            esac
        else
            # 最后兜底: 内联实现核心函数
            log warn "panel-common.sh 无法加载，使用内联兜底实现"
            _TRANSPORT_MODE="other"
            if [ -f ~/node.json ]; then
                _v2_name=$(jq -r '.v2_name // empty' ~/node.json 2>/dev/null || true)
                case "$_v2_name" in
                    *xhttp*) _TRANSPORT_MODE="xhttp" ;;
                    *vision*|*reality*) _TRANSPORT_MODE="vision" ;;
                esac
            fi
        fi
    fi

    # 1. 从 ~/node.json 的 v2_name 判断传输模式
    DetectTransportMode 2>/dev/null || true
    # 防御: DetectTransportMode 因故未赋值时给默认值, 避免 set -u 直接退出
    _PANEL_TRANSPORT="${_TRANSPORT_MODE:-other}"
    log info "面板传输模式: ${_PANEL_TRANSPORT} (由 v2_name 判定)"

    # 2. vision 模式: xray 直接监听 node_port, 不需要 nginx
    #    node_port=443 与面板冲突有两道防线:
    #      (1) DetectPanel() 预检 — 拦截 LoadEnv 解析出的 node_port=443
    #      (2) 此处补检 — Step1_Register 会用面板回传值覆盖 node_port
    #          (重装场景: 面板侧仍存有旧 node_port=443), 此时 (1) 已放行, 必须在此拦截
    if [ "${_PANEL_TRANSPORT}" = "vision" ]; then
        if [ "${node_port}" = "443" ]; then
            die "vision+面板: node_port=443 与面板自身 443 冲突 (Step1_Register 回传了 node_port=443?)。请在 ~/.env 设置 NODE_PORT=<非443>(如 2053) 后重跑。"
        fi
        log info "vision 模式: xray 直接监听 ${node_port}, 不需要 nginx 配置"
        return 0
    fi

    # 3. xhttp 模式: 从面板 API 下载 proxy.conf
    if [ "${_PANEL_TRANSPORT}" != "xhttp" ]; then
        log warn "未知传输模式 (${_PANEL_TRANSPORT})，跳过 Nginx 配置"
        return 0
    fi

    _panel_proxy_conf="/tmp/panel-proxy.conf"
    _conf_http_code=$(curl -sS --connect-timeout 30 --max-time 60 \
        -o "${_panel_proxy_conf}" \
        -w "%{http_code}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -d "node_id=${NODE_ID}" \
        "${API_URL}/api/node/nginx_config") || true

    log info "面板 nginx_config API 返回: HTTP ${_conf_http_code}"

    if [ "${_conf_http_code}" != "200" ]; then
        log error "xhttp 模式需要 nginx 配置，但面板 API 返回 HTTP ${_conf_http_code}"
        return 1
    fi

    # 4. 确认 SSL 证书 (由 Step1_5_DownloadSSL 下载)
    _cert_path="/etc/ssl/${root_domain}.pem"
    _key_path="/etc/ssl/${root_domain}.key"

    if [ ! -f "${_cert_path}" ] || [ ! -f "${_key_path}" ]; then
        log error "SSL 证书不存在: ${_cert_path} 或 ${_key_path}"
        log error "请确保 Step 1.5 已正常执行"
        return 1
    fi

    # 5. 从面板下发的 proxy.conf 提取 xray upstream 端口
    if type ParsePanelProxyConf >/dev/null 2>&1; then
        ParsePanelProxyConf "${_panel_proxy_conf}"
    else
        # 兜底: 内联解析 proxy.conf
        _extracted_upstream=$(grep -oP 'server\s+127\.0\.0\.1:\K[0-9]+' "${_panel_proxy_conf}" 2>/dev/null | head -1 || true)
        [ -z "$_extracted_upstream" ] && _extracted_upstream=$(grep -oP 'proxy_pass\s+http://127\.0\.0\.1:\K[0-9]+' "${_panel_proxy_conf}" 2>/dev/null | head -1 || true)
        [ -z "$_extracted_upstream" ] && _extracted_upstream="8443"
        log info "proxy.conf 解析 (内联): upstream_port=${_extracted_upstream}"
    fi
    _xray_upstream_port="${_extracted_upstream}"
    log info "xray upstream 端口: ${_xray_upstream_port}"

    # 6. 按面板类型调用专用脚本
    case "${_PANEL_TYPE}" in
        1panel)
            Panel1Panel_Setup "${root_domain}" "${_cert_path}" "${_key_path}" "${_xray_upstream_port}" "${_panel_proxy_conf}"
            ;;
        btpanel|aapanel)
            PanelBtPanel_Setup "${root_domain}" "${_cert_path}" "${_key_path}" "${_xray_upstream_port}" "${_panel_proxy_conf}"
            ;;
        *)
            log error "未知面板类型: ${_PANEL_TYPE}，跳过 Nginx 配置"
            return 1
            ;;
    esac
    return $?
}

# ============================================================
# Step 3.5: hy2 动态端口 UDP 映射 (30000-32000 → node_port)
# 自动检测 nftables / iptables 后端，无需手动开关
# ============================================================
Step3_5_SetupHy2PortHop() {
    # ---- 守卫: 仅当 v2_name 含 hy2 时才需要 UDP 端口跳跃映射 ----
    # 背景: hy2 已不再是默认协议; 非 hy2 节点 (vision/xhttp/reality 等) 无需把
    #       30000-32000/UDP 聚合到 node_port, 故不再无条件写入 NAT 重定向规则。
    #       v2_name 在 LoadEnv 解析、Step1_Register 由面板回传覆盖后, 此处已是最终值。
    case "${v2_name:-}" in
        *hy2*)
            log info "Step 3.5: v2_name='${v2_name}' 含 hy2 → 配置端口跳跃映射"
            ;;
        *)
            log info "Step 3.5: v2_name='${v2_name:-空}' 不含 hy2 → 跳过 UDP 端口转发到 ${node_port}"
            return 0
            ;;
    esac

    _hop_start="${HY2_PORT_HOP_START:-30000}"
    _hop_end="${HY2_PORT_HOP_END:-32000}"
    _hop_target="${HY2_PORT_HOP_TARGET:-${node_port}}"

    # 自动检测可用的防火墙后端，均不可用时尝试安装
    if command -v nft >/dev/null 2>&1; then
        _backend="nft"
    elif command -v iptables >/dev/null 2>&1; then
        _backend="iptables"
    else
        log info "Step 3.5: nft 和 iptables 均不可用，尝试自动安装 nftables"
        if AptGet install -y -qq nftables 2>/dev/null && command -v nft >/dev/null 2>&1; then
            _backend="nft"
            log info "nftables 安装成功"
        elif AptGet install -y -qq iptables 2>/dev/null && command -v iptables >/dev/null 2>&1; then
            _backend="iptables"
            log info "iptables 安装成功"
        else
            log error "Step 3.5: nft 和 iptables 安装均失败，跳过端口映射"
            return 1
        fi
    fi

    log info "Step 3.5: 配置 hy2 动态端口映射 ${_hop_start}-${_hop_end}/UDP → ${_hop_target}/UDP (后端: ${_backend})"

    # ============================================================
    # nftables 分支 — 使用 inet 协议族，一条规则同时处理 IPv4+IPv6
    # ============================================================
    if [ "${_backend}" = "nft" ]; then
        # 创建表和链 (幂等: 已存在不报错)
        nft add table inet nat
        nft add chain inet nat prerouting '{ type nat hook prerouting priority -100 ; }'

        # 检查规则是否已存在
        if nft list chain inet nat prerouting 2>/dev/null | grep -q "udp dport ${_hop_start}-${_hop_end} redirect to :${_hop_target}"; then
            log info "nftables 规则已存在，跳过"
        else
            nft add rule inet nat prerouting udp dport "${_hop_start}-${_hop_end}" redirect to :"${_hop_target}"
            log info "nftables 规则已添加 (inet, IPv4+IPv6)"
        fi

        # 持久化: 写入 systemd service
        _rule_script="/usr/local/bin/hy2-port-hop-rules.sh"
        cat > "$_rule_script" << RULE_EOF
#!/bin/sh
nft add table inet nat
nft add chain inet nat prerouting '{ type nat hook prerouting priority -100 ; }'
nft list chain inet nat prerouting 2>/dev/null | grep -q 'udp dport ${_hop_start}-${_hop_end} redirect to :${_hop_target}' || \\
    nft add rule inet nat prerouting udp dport ${_hop_start}-${_hop_end} redirect to :${_hop_target}
RULE_EOF
        chmod +x "$_rule_script"

        _service_file="/etc/systemd/system/hy2-port-hop.service"
        cat > "$_service_file" << SVC_EOF
[Unit]
Description=Hysteria2 Port Hopping nftables rules (${_hop_start}-${_hop_end} → ${_hop_target}/UDP)
After=network.target

[Service]
Type=oneshot
ExecStart=${_rule_script}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC_EOF

        systemctl daemon-reload
        systemctl enable hy2-port-hop
        log info "hy2-port-hop systemd service 已启用 (nftables)"

    # ============================================================
    # iptables 分支 — 保持原有逻辑
    # ============================================================
    else
        # 安装 iptables-persistent — 预先注入 debconf 应答，避免交互式弹窗阻塞自动化脚本
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null || true
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive AptGet install -y -qq iptables-persistent

        # IPv4 规则 (幂等: -C 检查存在则跳过)
        if ! iptables -t nat -C PREROUTING -p udp --dport "${_hop_start}:${_hop_end}" -j REDIRECT --to-port "${_hop_target}" 2>/dev/null; then
            iptables -t nat -A PREROUTING -p udp --dport "${_hop_start}:${_hop_end}" -j REDIRECT --to-port "${_hop_target}"
            log info "IPv4 iptables 规则已添加"
        else
            log info "IPv4 iptables 规则已存在，跳过"
        fi

        # IPv6 规则 (幂等)
        if ! ip6tables -t nat -C PREROUTING -p udp --dport "${_hop_start}:${_hop_end}" -j REDIRECT --to-port "${_hop_target}" 2>/dev/null; then
            ip6tables -t nat -A PREROUTING -p udp --dport "${_hop_start}:${_hop_end}" -j REDIRECT --to-port "${_hop_target}"
            log info "IPv6 iptables 规则已添加"
        else
            log info "IPv6 iptables 规则已存在，跳过"
        fi

        # 持久化
        netfilter-persistent save
        log info "iptables 规则已持久化 (netfilter-persistent)"

        # 备用: 写入 systemd service 确保重启后生效
        _rule_script="/usr/local/bin/hy2-port-hop-rules.sh"
        cat > "$_rule_script" << RULE_EOF
#!/bin/sh
iptables -t nat -C PREROUTING -p udp --dport ${_hop_start}:${_hop_end} -j REDIRECT --to-port ${_hop_target} 2>/dev/null || \\
    iptables -t nat -A PREROUTING -p udp --dport ${_hop_start}:${_hop_end} -j REDIRECT --to-port ${_hop_target}
ip6tables -t nat -C PREROUTING -p udp --dport ${_hop_start}:${_hop_end} -j REDIRECT --to-port ${_hop_target} 2>/dev/null || \\
    ip6tables -t nat -A PREROUTING -p udp --dport ${_hop_start}:${_hop_end} -j REDIRECT --to-port ${_hop_target}
RULE_EOF
        chmod +x "$_rule_script"

        _service_file="/etc/systemd/system/hy2-port-hop.service"
        cat > "$_service_file" << SVC_EOF
[Unit]
Description=Hysteria2 Port Hopping iptables rules (${_hop_start}-${_hop_end} → ${_hop_target}/UDP)
After=network.target

[Service]
Type=oneshot
ExecStart=${_rule_script}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC_EOF

        systemctl daemon-reload
        systemctl enable hy2-port-hop
        log info "hy2-port-hop systemd service 已启用 (iptables)"
    fi

    log info "Step 3.5 完成 — 后端: ${_backend}, 端口映射: ${_hop_start}-${_hop_end}/UDP → ${_hop_target}/UDP"
}

# ============================================================
# Step 4: 部署 nodeAgent.sh 到 /etc/crontab
# ============================================================
Step4_DeployCrontab() {
    log info "Step 4: 部署定时任务"

    # ------------------------------------------------------------
    # 0. 确保 cron 守护进程已安装并运行
    # 最小化 Debian/Ubuntu 镜像 (容器/云主机) 可能未预装 cron,
    # 导致 /etc/crontab 不存在 → sed -i 报 "can't read /etc/crontab"
    # ------------------------------------------------------------
    if [ ! -x /usr/sbin/cron ] && [ ! -x /usr/sbin/crond ]; then
        log info "cron 未安装，安装中..."
        AptGet install -y -qq cron || die "cron 安装失败"
    fi

    # 双保险: 即使已安装 cron 也确保 /etc/crontab 存在 (touch 幂等)
    if [ ! -f /etc/crontab ]; then
        log warn "/etc/crontab 不存在，创建空文件"
        touch /etc/crontab
    fi

    # 下载 nodeAgent.sh (每小时执行)
    wget -N --timeout=60 --tries=3 -P ~ "${NODEHUB_URL}/nodeAgent.sh" \
        || die "nodeAgent.sh 下载失败: ${NODEHUB_URL}/nodeAgent.sh"
    chmod +x ~/nodeAgent.sh

    # 校验 nodeAgent.sh 下载完整性 (与前端通信的关键文件)
    # why: nodeAgent.sh 是与前端通信的关键文件, 缺失/为空会导致节点无法使用。
    #   某些网络异常下 wget 仍可能返回成功但写入空文件或 HTML 错误页,
    #   仅靠 wget 退出码无法识别, 故必须显式校验: 文件非空 且 以 #! 开头。
    #   另: wget -N 在本地已存在脏文件且服务器时间戳未更新时会跳过下载,
    #   导致历史脏文件永久残留, 故校验失败时强制删除后重新下载修复。
    _agent_file=~/nodeAgent.sh
    if [ ! -s "$_agent_file" ] || [ "$(head -c 2 "$_agent_file" 2>/dev/null)" != "#!" ]; then
        log warn "nodeAgent.sh 校验失败 (空文件或非 #! 开头), 强制删除后重新下载"
        rm -f "$_agent_file"
        wget --timeout=60 --tries=3 -O "$_agent_file" "${NODEHUB_URL}/nodeAgent.sh" \
            || die "nodeAgent.sh 强制重新下载失败: ${NODEHUB_URL}/nodeAgent.sh"
        chmod +x "$_agent_file"
        if [ ! -s "$_agent_file" ] || [ "$(head -c 2 "$_agent_file" 2>/dev/null)" != "#!" ]; then
            log error "nodeAgent.sh 文件内容前 200 字符: $(head -c 200 "$_agent_file" 2>/dev/null)"
            die "nodeAgent.sh 校验失败: 文件为空或未以 #! 开头 (${_agent_file}) — 下载源可能损坏: ${NODEHUB_URL}/nodeAgent.sh"
        fi
    fi
    log info "nodeAgent.sh 已下载并校验通过 (以 #! 开头, $(wc -c < "$_agent_file") bytes)"

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

    # ------------------------------------------------------------
    # 启用并重启 cron 服务, 使新条目立即生效
    # Debian/Ubuntu: cron.service | RHEL 系: crond.service
    # ------------------------------------------------------------
    _cron_started=""
    for _cron_svc in cron crond; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${_cron_svc}\.service"; then
            systemctl enable "$_cron_svc" 2>/dev/null || true
            systemctl restart "$_cron_svc" 2>/dev/null || true
            _cron_started="$_cron_svc"
            break
        fi
    done
    if [ -n "$_cron_started" ]; then
        log info "${_cron_started} 服务已启用并重启"
    else
        log warn "未找到 cron/crond systemd 服务单元，请手动确认定时任务守护进程在运行"
    fi

    log info "/etc/crontab 已配置: nodeAgent 每小时第 ${install_min} 分钟 | nodeMonitor 每分钟"
}

# ============================================================
# Step 4.5: 下载并后台启动 unlockCheck.sh
# ============================================================
Step4_5_LaunchUnlockCheck() {
    log info "Step 4.5: 下载并后台启动 unlockCheck.sh"

    wget -N --timeout=60 --tries=3 -P /tmp "${NODEHUB_URL}/unlockCheck.sh" \
        || { log error "unlockCheck.sh 下载失败"; return 1; }
    chmod +x /tmp/unlockCheck.sh
    log info "unlockCheck.sh 已下载到 /tmp/"

    nohup sh /tmp/unlockCheck.sh > /tmp/unlockCheck.out 2>&1 &
    _pid=$!
    log info "unlockCheck.sh 已后台启动 (PID=${_pid})，输出: /tmp/unlockCheck.out"
}

# ============================================================
# Step 4.6: 部署 manage.sh 到 ~/ (节点运维菜单)
# 职责: 重新测试流媒体解锁 / 节点故障自检 / 手动重启服务 / 同步 SSL 等
# 镜像 nodeAgent.sh 的下载完整性校验 (非空 + #! 开头), 失败时强制重下
# 容错: 运维脚本非节点运行必需, 下载失败仅告警不中断安装
# ============================================================
Step4_6_DeployManageScript() {
    log info "Step 4.6: 部署 manage.sh 到 ~/"

    _manage_file=~/manage.sh

    # 首次下载: wget -N 仅在远程更新时拉取
    wget -N --timeout=60 --tries=3 -P ~ "${NODEHUB_URL}/manage.sh" \
        || { log warn "manage.sh 下载失败: ${NODEHUB_URL}/manage.sh (节点可正常运行, 稍后可手动重试)"; return 0; }
    chmod +x "$_manage_file"

    # 完整性校验: 非空 且 以 #! 开头 (防脏文件/HTML 错误页)
    # 校验失败 → 强制删除后重新下载一次
    if [ ! -s "$_manage_file" ] || [ "$(head -c 2 "$_manage_file" 2>/dev/null)" != "#!" ]; then
        log warn "manage.sh 校验失败 (空文件或非 #! 开头), 强制删除后重新下载"
        rm -f "$_manage_file"
        wget --timeout=60 --tries=3 -O "$_manage_file" "${NODEHUB_URL}/manage.sh" \
            || { log warn "manage.sh 强制重新下载失败, 跳过 (节点可正常运行)"; return 0; }
        chmod +x "$_manage_file"
        if [ ! -s "$_manage_file" ] || [ "$(head -c 2 "$_manage_file" 2>/dev/null)" != "#!" ]; then
            log warn "manage.sh 校验仍失败, 跳过部署 (节点可正常运行)"
            return 0
        fi
    fi

    log info "manage.sh 已部署到 ~/ ($(wc -c < "$_manage_file") bytes) — 用法: sh ~/manage.sh"
}


# ============================================================
# Step Final: 安装成功后自删除脚本本体 — 避免安装方式泄漏
# 触发: 仅 Main() 全部步骤成功后调用 (失败路径不删, 便于重跑/排查)
# 跳过: KEEP_INSTALLER=1 (保留脚本供调试) | 管道安装 ($0=sh, 无实体文件)
# 安全: 仅当文件存在且以 #! 开头才删, 避免误删无关文件; 删除失败仅告警不中断
# 注: 父 shell 内存中的执行命令 (history) 无法由本脚本清除, 如需彻底抹除
#       请在安装命令前加空格 (HISTCONTROL=ignorespace) 或事后手动清理 history
# ============================================================
SelfDestruct() {
    if [ "${KEEP_INSTALLER:-0}" = "1" ]; then
        log info "KEEP_INSTALLER=1, 保留安装脚本: ${_SCRIPT_PATH}"
        return 0
    fi

    # 管道方式安装 (curl ... | sh) 时 $0 是解释器名, 无实体脚本可删
    case "${_SCRIPT_NAME}" in
        sh|bash|dash|ash|zsh)
            log debug "管道方式安装 (${_SCRIPT_NAME}), 无脚本文件可删, 跳过自删除"
            return 0
            ;;
    esac

    if [ -f "${_SCRIPT_PATH}" ] && [ "$(head -c 2 "${_SCRIPT_PATH}" 2>/dev/null)" = "#!" ]; then
        if rm -f "${_SCRIPT_PATH}" 2>/dev/null; then
            log info "安装成功, 安装脚本已自删除: ${_SCRIPT_PATH}"
        else
            log warn "安装脚本自删除失败: ${_SCRIPT_PATH} (可手动删除)"
        fi
    else
        log debug "未找到脚本实体 (${_SCRIPT_PATH}), 跳过自删除"
    fi
}


# ============================================================
# 主流程
# ============================================================
Main() {
    LoadEnv
    DetectPanel
    InitSystem
    Step0_ApplyId
    Step1_Register
    # node_name 解析与持久化 (= node_id, alias 展示名)
    ResolveNodeName
    PersistNodeName
    # stat_user = md5(IP): stat 检索主键 (-u), 须在 ProbeHardware 采集 node_ip 之后
    DeriveStatIdentity
    # ServerStatus 移至注册后安装: -u=stat_user=md5(IP) (按 IP 检索) / alias=node_name=node_id
    Step0_5_InstallServerStatus
    Step1_5_DownloadSSL
    Step2_5_InstallAriaNg
    Step3_InstallNginx
    Step3_InstallXray
    Step3_5_SetupHy2PortHop
    ConfigureFirewall
    Step2_ResolveDns
    Step4_DeployCrontab
    Step4_5_LaunchUnlockCheck
    Step4_6_DeployManageScript

    log info "===== 安装完成 ====="
    log info "node_id=${NODE_ID}"
    log info "node_name=${node_name:-无} (= node_id, alias 展示名); 读取: cat ~/node.name | grep node_name ~/node.env | jq -r .node_name ~/node.json"
    log info "stat_user=${stat_user:-未派生} = md5(IP) (IPv4 优先) — 外部项目按 IP 算 md5 匹配 username 即可检索; 读取: grep stat_user ~/node.env | cat ~/node.stat_user"
    log info "node_ids=${node_ids:-无}"
    log info "node_port=${node_port}"
    log info "API_PANEL=${API_PANEL}"
    log info "配置文件: ~/node.env | ~/node.json | ~/config.json"

    # 面板信息
    if [ -n "${_PANEL_DETECTED:-}" ]; then
        log info "面板: ${_PANEL_DETECTED} (${_PANEL_TYPE:-未知})"
        [ -n "${_PANEL_TRANSPORT:-}" ] && log info "传输模式: ${_PANEL_TRANSPORT}"

        # 写入备注到 ~/node.env
        SetNodeEnv "panel_detected" "${_PANEL_DETECTED}"
        SetNodeEnv "panel_type" "${_PANEL_TYPE:-unknown}"
        [ -n "${_PANEL_TRANSPORT:-}" ] && SetNodeEnv "panel_transport" "${_PANEL_TRANSPORT}"
        SetNodeEnv "panel_remark" "auto-detected-by-proxyInstall"
    fi

    # 服务状态 — 异常时红色标注
    _xray_status=$(systemctl is-active xray 2>/dev/null) || true
    _nginx_status=$(systemctl is-active nginx 2>/dev/null) || true
    _stat_status=$(systemctl is-active stat_client 2>/dev/null) || true
    [ -z "$_xray_status" ]  && _xray_status="未知"
    [ -z "$_nginx_status" ] && _nginx_status="未知"
    [ -z "$_stat_status" ]  && _stat_status="未安装"

    # 面板模式下 nginx 状态不做异常判断 (由面板管理)
    if [ -n "${_PANEL_DETECTED:-}" ]; then
        log info "服务状态: xray=${_xray_status} nginx=${_nginx_status} (面板管理) stat_client=${_stat_status}"
    elif [ "$_xray_status" = "active" ] && [ "$_nginx_status" = "active" ] && [ "$_stat_status" = "active" ]; then
        log info "服务状态: xray=${_xray_status} nginx=${_nginx_status} stat_client=${_stat_status}"
    else
        [ "$_xray_status" != "active" ]  && log error "服务状态: xray=${_xray_status}"
        [ "$_nginx_status" != "active" ] && log error "服务状态: nginx=${_nginx_status}"
        [ "$_stat_status" != "active" ]  && log error "服务状态: stat_client=${_stat_status}"
    fi

    # 安装成功，清除 EXIT trap
    trap - EXIT

    # 安装成功后自删除脚本本体 (避免安装方式泄漏; KEEP_INSTALLER=1 可保留调试)
    SelfDestruct
}

Main "$@"
