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
        die "以下必需环境变量未设置，请在 ~/.env 中配置:\n$_missing"
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



# 地理位置探测 — 优先 ipinfo.io，兜底 ip-api.com
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

    # 1) 优先 ipinfo.io (支持 IPv4/IPv6，无需 token 即可获取 country/city/org)
    geo_response=$(curl -sS --connect-timeout 10 --max-time 15 \
        "https://ipinfo.io/${node_ip}/json" 2>/dev/null) || true
    log debug "ipinfo.io 响应: ${geo_response:-空}"

    if [ -n "$geo_response" ]; then
        _geo_country=$(echo "$geo_response" | jq -r '.country // empty' 2>/dev/null || echo "")
        _geo_city=$(echo "$geo_response" | jq -r '.city // empty' 2>/dev/null || echo "")
        # ipinfo.io 返回 ISO 国家代码 (如 KR/JP)，转小写存储
        if [ -n "$_geo_country" ]; then
            node_country_code=$(echo "$_geo_country" | tr 'A-Z' 'a-z')
            # 将 ISO 代码映射为完整国家名 (常见国家)
            case "$node_country_code" in
                kr) node_country="South Korea";;
                jp) node_country="Japan";;
                us) node_country="United States";;
                hk) node_country="Hong Kong";;
                tw) node_country="Taiwan";;
                sg) node_country="Singapore";;
                de) node_country="Germany";;
                gb) node_country="United Kingdom";;
                *)  node_country="$_geo_country";;
            esac
            node_city="${_geo_city:-Unknown}"
            log info "ipinfo.io 地理位置解析成功"
        fi
    fi

    # 2) 兜底 ip-api.com (仅支持 IPv4)
    if [ -z "${node_country:-}" ] || [ "$node_country" = "Unknown" ]; then
        log info "ipinfo.io 未返回有效结果，尝试 ip-api.com 兜底"
        geo_response=$(curl -sS --connect-timeout 10 --max-time 15 \
            "http://ip-api.com/json/${node_ip}?fields=country,city,countryCode" 2>/dev/null) || true
        log debug "ip-api.com 响应: ${geo_response:-空}"

        if [ -n "$geo_response" ]; then
            node_country=$(echo "$geo_response" | jq -r '.country // empty' 2>/dev/null || echo "")
            node_city=$(echo "$geo_response" | jq -r '.city // empty' 2>/dev/null || echo "")
            node_country_code=$(echo "$geo_response" | jq -r '.countryCode // empty' 2>/dev/null || echo "" | tr 'A-Z' 'a-z')
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

    AptGet update -qq
    command -v jq >/dev/null 2>&1     || AptGet install -y -qq jq
    command -v curl >/dev/null 2>&1   || AptGet install -y -qq curl
    command -v vnstat >/dev/null 2>&1 || AptGet install -y -qq vnstat

    # Nginx: 先安装系统默认版本, 后续由 EnsureNginxLatest 升级
    command -v nginx >/dev/null 2>&1  || AptGet install -y -qq nginx

    log info "预先停止 nginx xray 服务"
    systemctl stop nginx 2>/dev/null || true
    systemctl stop xray 2>/dev/null || true

    log info "基础系统调优完成"
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
# 在 Step0 获取 node_id 之后，下载并运行 serverstatus_client_install.sh
# ============================================================
Step0_5_InstallServerStatus() {
    log info "Step 0.5: 安装 ServerStatus 客户端"

    # 已安装则跳过
    if [ -f /opt/ServerStatus/client/stat_client ]; then
        log info "stat_client 已存在，跳过安装"
        return 0
    fi

    _script_name="serverstatus_client_install.sh"
    _script_url="${NODEHUB_URL}/scripts/${_script_name}"

    cd /tmp
    wget -N --timeout=60 --tries=3 "${_script_url}" || die "${_script_name} 下载失败: ${_script_url}"
    chmod +x "/tmp/${_script_name}"

    log info "开始运行 ${_script_name}..."
    if sh "/tmp/${_script_name}"; then
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

    # 采集硬件 + 地理 + 网络信息
    ProbeHardware
    ProbeGeo

    # 采集网卡原始 rx/tx 字节数 (参考 nodeAgent.sh CollectRawTraffic)
    _rx_file="/sys/class/net/${NET_CARD}/statistics/rx_bytes"
    _tx_file="/sys/class/net/${NET_CARD}/statistics/tx_bytes"
    [ ! -f "$_rx_file" ] && die "网卡 ${NET_CARD} 的 rx_bytes 文件不存在: ${_rx_file}"
    [ ! -f "$_tx_file" ] && die "网卡 ${NET_CARD} 的 tx_bytes 文件不存在: ${_tx_file}"
    raw_rx=$(cat "$_rx_file")
    raw_tx=$(cat "$_tx_file")
    log info "网卡流量采集 — raw_rx=${raw_rx} raw_tx=${raw_tx} (${NET_CARD})"

    # 读取本地缓存 (node.json + status.json) — panel 以节点上报为第一优先级
    _cached_node_id="" _cached_node_ids="" _cached_root_domain="" _cached_v2_name=""
    _cached_traffic_used=""
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
    if [ -f ~/status.json ]; then
        _cached_traffic_used=$(jq -r '.traffic_used // empty' ~/status.json 2>/dev/null || true)
        log info "status.json 缓存: traffic_used=${_cached_traffic_used:-无}"
    else
        log debug "~/status.json 不存在，首次安装"
    fi

    # 环境变量覆盖 — V2_NAME / TRAFFIC_USED / TRAFFIC_USED_GB 为最高优先级
    if [ -n "${V2_NAME:-}" ]; then
        _cached_v2_name="${V2_NAME}"
        v2_name="${V2_NAME}"
        log info "V2_NAME 环境变量覆盖: v2_name=${V2_NAME}"
    fi
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
# ============================================================
Step3_InstallNginx() {
    log info "Step 3: 配置 Nginx"

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
# Step 3.5: hy2 动态端口 UDP 映射 (30000-32000 → node_port)
# 自动检测 nftables / iptables 后端，无需手动开关
# ============================================================
Step3_5_SetupHy2PortHop() {
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
# 主流程
# ============================================================
Main() {
    LoadEnv
    InitSystem
    Step0_ApplyId
    Step0_5_InstallServerStatus
    Step1_Register
    Step1_5_DownloadSSL
    Step3_InstallNginx
    Step3_InstallXray
    Step3_5_SetupHy2PortHop
    ConfigureFirewall
    Step2_ResolveDns
    Step4_DeployCrontab
    Step4_5_LaunchUnlockCheck

    log info "===== 安装完成 ====="
    log info "node_id=${NODE_ID}"
    log info "node_ids=${node_ids:-无}"
    log info "node_port=${node_port}"
    log info "API_PANEL=${API_PANEL}"
    log info "配置文件: ~/node.env | ~/node.json | ~/config.json"

    # 服务状态 — 异常时红色标注
    _xray_status=$(systemctl is-active xray 2>/dev/null) || true
    _nginx_status=$(systemctl is-active nginx 2>/dev/null) || true
    _stat_status=$(systemctl is-active stat_client 2>/dev/null) || true
    [ -z "$_xray_status" ]  && _xray_status="未知"
    [ -z "$_nginx_status" ] && _nginx_status="未知"
    [ -z "$_stat_status" ]  && _stat_status="未安装"
    if [ "$_xray_status" = "active" ] && [ "$_nginx_status" = "active" ] && [ "$_stat_status" = "active" ]; then
        log info "服务状态: xray=${_xray_status} nginx=${_nginx_status} stat_client=${_stat_status}"
    else
        [ "$_xray_status" != "active" ]  && log error "服务状态: xray=${_xray_status}"
        [ "$_nginx_status" != "active" ] && log error "服务状态: nginx=${_nginx_status}"
        [ "$_stat_status" != "active" ]  && log error "服务状态: stat_client=${_stat_status}"
    fi

    # 安装成功，清除 EXIT trap
    trap - EXIT
}

Main "$@"
