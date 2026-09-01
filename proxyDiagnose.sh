#!/bin/sh
# ============================================================
# proxyDiagnose.sh — 代理服务 (xray / nginx / 代理安装环境) 故障诊断脚本
#
# 职责: 一键检查 xray / nginx / 代理无法【安装】或【运行】的各种可能原因。
#       覆盖真实生产故障场景, 包括但不限于:
#         · 端口冲突 (nginx 与 xray 【同协议同端口】抢占 443/80; 注意 TCP/UDP 是两个
#           独立命名空间, xray UDP:443 + nginx TCP:443 属正常共存非冲突 —
#           本次 179.61.138.177 故障根因, 详见 _PortOverlapCheck)
#         · 配置文件 JSON 语法错误 / 缺失
#         · 二进制缺失 / 无执行权限 / 架构不匹配 (ARM vs x86)
#         · systemd 服务文件缺失 / 被 mask / 重启风暴放弃
#         · TLS 证书缺失 / 过期 / 权限不可读
#         · geo 数据文件缺失 (geoip.dat / geosite.dat)
#         · 内存不足 OOM / 磁盘满 / 包管理器锁占用
#         · 系统时间不同步 (TLS 握手失败)
#         · 防火墙拦截 (iptables / ufw / firewalld / SELinux)
#         · DNS 解析失败 / 关键依赖缺失
#         · 面板辅助脚本 0 字节空文件 (source 静默成功但函数未定义 → set -u 崩溃,
#           本次 198.12.124.74 "_TRANSPORT_MODE: parameter not set" 故障根因)
#         · 出站 IPv4 web 端口被上游封锁, 但 xray freedom 强制 IPv4 → 代理"假活"
#           (服务/端口/TLS握手/认证全 PASS、唯独收不到数据; curl 默认走 IPv6 极具迷惑性,
#            本次 38.45.72.223 故障根因, 详见 check_outbound)
#         · NODE_PORT 只 bind 127.0.0.1 → 端口本地"在监听"但外部无法访问
#           (详见 _check_node_port_external)
#         · NODE_PORT 大陆方向被墙 — 本机监听/证书/海外访问全正常, 唯大陆方向 TCP
#           握手全部超时 (借 tcp.ping.pe 大陆探测点 tcping, 与海外探测点对照判定,
#            详见 _check_node_port_cn_tcping)
#         · conntrack 连接跟踪表打满 → 海量丢包 → 内存耗尽【硬死锁】
#           (nf_conntrack_max 默认 8192 在多用户代理下秒级打满; 常因 /etc/sysctl.conf
#            写了 conntrack 调优键但【值为空】→ sysctl -p 静默失败回退默认; 无 swap 的小
#            VPS 尤甚, 内存尖峰直接硬挂。本次 103.173.155.212 死机根因, 详见 check_net NW7/NW8/NW9)
#         · 本周期出站流量统计 (vnstat tx × ~/.env NODE_TRAFFIC_RESETDAY, 起点几月几号
#           显式标注; 配 NODE_TRAFFIC_LIMIT 时顺带限额用量提醒, 详见 check_traffic)
#
# 设计原则:
#   1. 只读诊断, 默认绝不修改系统 (只查询 + 报告), 修复动作需显式 --fix (预留)
#   2. 每项检查独立 (一项失败不阻断其它检查), 永不 set -e 中途退出
#   3. 输出三级结论: PASS(正常) / WARN(潜在风险) / FAIL(直接故障原因)
#   4. 支持 --json 机器可读输出, 供面板/nodeAgent 调用
#
# 用法:
#   ./proxyDiagnose.sh                      # 全量检查 (xray + nginx + 环境 + 网络)
#   ./proxyDiagnose.sh --target xray        # 只查 xray
#   ./proxyDiagnose.sh --target nginx       # 只查 nginx
#   ./proxyDiagnose.sh --target env         # 只查安装环境 (磁盘/内存/DNS/依赖/锁)
#   ./proxyDiagnose.sh --target net         # 只查网络与防火墙 (含 NODE_PORT 对外可达性 + 大陆 tcping 被墙检测,
#                                            #   检出封锁时自动随机开临时端口交叉验证 端口级/IP级 被墙)
#   ./proxyDiagnose.sh --target cert        # 只查 TLS 证书 (root_domain + nginx .conf 引用证书)
#   ./proxyDiagnose.sh --target outbound    # 只查出站连通性 (IPv4/IPv6 web + domainStrategy)
#   ./proxyDiagnose.sh --target traffic     # 只查本周期流量 (vnstat tx, 自上一个 NODE_TRAFFIC_RESETDAY)
#   ./proxyDiagnose.sh --json               # 输出 JSON (供程序解析)
#   ./proxyDiagnose.sh --no-notify           # 抑制 Telegram 推送 (供 nodeAgent 程序化调度,
#                                            #   由调用方自行组织通知, 避免双重告警)
#   ./proxyDiagnose.sh --quiet              # 只输出 FAIL/WARN, 不输出 PASS
#   ./proxyDiagnose.sh --no-color           # 关闭颜色
#   ./proxyDiagnose.sh --host root@1.2.3.4  # 远程诊断 (ssh 执行, 本地无需登录)
#   NODE_TARGET_IP=5.6.7.8 NODE_PORT=443 ./proxyDiagnose.sh --target net
#                                          # 在任意第三方服务器上远程测【别的】节点是否被墙
#                                          #   (探测由 ping.pe 代测, 与运行位置无关;
#                                          #    自动跳过本机监听类检查与交叉验证)
#
# 退出码: 失败项数 (上限 99), 0 = 全部通过
# ============================================================

# ---- 脚本身份 (供 Telegram 通知标注来源) ----
_SCRIPT_PATH="$0"
_SCRIPT_NAME="${0##*/}"

# ---- 加载配置 (兼容 .env / node.env, 与 nodeAgent.sh 一致) ----
[ -f ~/.env ] && . ~/.env
[ -f ~/node.env ] && . ~/node.env 2>/dev/null || true
[ -f ./.env ] && . ./.env 2>/dev/null || true

# ---- 解析 NODE_PORT (代理对外端口, 默认 443; 与 proxyInstall.sh 同源) ----
#   优先级: 环境变量 NODE_PORT > ~/.env(已 source) > ~/node.json > ~/node.env > 默认 443
#   运行时调用 _resolve_node_port, 结果写入全局 _NODE_PORT
_NODE_PORT="443"
_resolve_node_port() {
    [ -n "${NODE_PORT:-}" ] && { _NODE_PORT="$NODE_PORT"; return; }
    if [ -f "$HOME/node.json" ] && has jq; then
        _jp=$(jq -r '.node_port // empty' "$HOME/node.json" 2>/dev/null)
        [ -n "$_jp" ] && { _NODE_PORT="$_jp"; return; }
    fi
    if [ -f "$HOME/node.env" ]; then
        _ep=$(grep -E '^[[:space:]]*node_port[[:space:]]*=' "$HOME/node.env" 2>/dev/null | tail -1 | sed -E "s/^[^=]*=//; s/[\"' ]//g")
        [ -n "$_ep" ] && { _NODE_PORT="$_ep"; return; }
    fi
}

# ============================================================
# 命令行参数解析
# ============================================================
TARGET="all"
JSON_OUTPUT=0
QUIET=0
USE_COLOR=1
REMOTE_HOST=""
NO_NOTIFY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --json)   JSON_OUTPUT=1; USE_COLOR=0; shift ;;
        --no-notify) NO_NOTIFY=1; shift ;;
        --quiet)  QUIET=1; shift ;;
        --no-color) USE_COLOR=0; shift ;;
        --host)   REMOTE_HOST="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "未知参数: $1 (用 --help 查看用法)" >&2; exit 2 ;;
    esac
done

# ---- --target 白名单前置校验 ----
# 必须在远程分支之前: 远程分支会把 $TARGET 拼入远程命令串, 若不在入口处校验,
# 未校验值既是注入面 (脚本声明可供面板/nodeAgent 程序化调用), 也会把非法值
# 原样透传到远端。Main() 里的同款 case 仅作本地分发的双保险。
case "$TARGET" in
    all|xray|nginx|env|net|cert|outbound|traffic) ;;
    *) echo "未知 --target: $TARGET (可选: all|xray|nginx|env|net|cert|outbound|traffic)" >&2; exit 2 ;;
esac
# ============================================================
# 远程模式: 把自身推送到远程主机执行 (保证远程环境一致)
# 远程主机必须有 bash/sh + 基础工具; 无需预装本脚本
# ($TARGET 已在入口白名单校验, 拼接安全)
# ============================================================
if [ -n "$REMOTE_HOST" ]; then
    # 通过 ssh 执行自身 (stdin 传入脚本内容, 远程用 sh 跑; 剥离 --host 避免递归)
    # 远程为非 TTY, 颜色由 [ -t 1 ] 自动关闭, 无需转发 --no-color
    # TARGET 虽已经入口白名单校验, 仍以单引号包裹传递 (纵深防御, 保证只作为单个 argv)。
    # --no-notify 必须转发: 否则远端仍会推送 TG, 与调用方自行组织的通知双重告警
    # StrictHostKeyChecking=accept-new (OpenSSH>=7.6): 首次连接记录主机密钥、之后
    #   指纹变化即拒绝 — 比 =no 抗 DNS 劫持/中间人; 本脚本以登录身份在远端执行,
    #   信道可信度重要。老版 OpenSSH 不识别 accept-new 时可 DIAG_SSH_STRICT=no 回退。
    ssh -o "StrictHostKeyChecking=${DIAG_SSH_STRICT:-accept-new}" -o ConnectTimeout=10 "$REMOTE_HOST" \
        "sh -s -- --target '$TARGET' $( [ "$JSON_OUTPUT" = 1 ] && echo --json ) $( [ "$QUIET" = 1 ] && echo --quiet ) $( [ "$NO_NOTIFY" = 1 ] && echo --no-notify )" \
        < "$0"
    exit $?
fi

# ============================================================
# 日志/结果输出系统 — 与 nodeAgent.sh 风格一致
#   三级: PASS / WARN / FAIL, 每项独立累计, 支持汇总 + JSON
# ============================================================
_FAIL=0; _WARN=0; _PASS=0
# 结果收集到临时文件 (TSV: level \t code \t title \t detail), 供 JSON 汇总
_RESULTS_FILE="${TMPDIR:-/tmp}/${_SCRIPT_NAME}.$$"
: > "$_RESULTS_FILE"
trap 'rm -f "$_RESULTS_FILE" 2>/dev/null' EXIT INT TERM

# ---- 颜色 (可关闭 / 非 TTY 自动关闭) ----
if [ "$USE_COLOR" = 1 ] && [ -t 1 ]; then
    _C_RED='\033[31m'; _C_YELLOW='\033[33m'; _C_GREEN='\033[32m'
    _C_CYAN='\033[36m'; _C_DIM='\033[2m'; _C_BOLD='\033[1m'; _C_RESET='\033[0m'
else
    _C_RED=''; _C_YELLOW=''; _C_GREEN=''; _C_CYAN=''; _C_DIM=''; _C_BOLD=''; _C_RESET=''
fi

# ---- 计数 + 输出单项结果 ----
# 用法: result <PASS|WARN|FAIL> <code> <title> [detail...]
result() {
    _lvl="$1"; _code="$2"; _title="$3"; shift 3
    _detail="$*"
    case "$_lvl" in
        PASS) _pass=$((_PASS + 1)); _PASS=$_pass ;;
        WARN) _warn=$((_WARN + 1)); _WARN=$_warn ;;
        FAIL) _fail=$((_FAIL + 1)); _FAIL=$_fail ;;
    esac
    # 写入结果文件 (TSV, tab 分隔; detail 里换行转义)
    _safe_detail=$(printf '%s' "$_detail" | tr '\n' ' ' | tr '\t' ' ')
    printf '%s\t%s\t%s\t%s\n' "$_lvl" "$_code" "$_title" "$_safe_detail" >> "$_RESULTS_FILE"

    # 实时彩色输出 (--quiet 时跳过 PASS)
    [ "$QUIET" = 1 ] && [ "$_lvl" = "PASS" ] && return 0
    if [ "$JSON_OUTPUT" != 1 ]; then
        case "$_lvl" in
            PASS) _c="$_C_GREEN"; _mark="✅" ;;
            WARN) _c="$_C_YELLOW"; _mark="⚠️ " ;;
            FAIL) _c="$_C_RED"; _mark="❌" ;;
        esac
        printf '%b[%s] %s %s%b\n' "$_c" "$_lvl" "$_mark" "$_title" "$_C_RESET"
        [ -n "$_detail" ] && printf '%b    └ %s%b\n' "$_C_DIM" "$_detail" "$_C_RESET"
    fi
}

# ---- 简化版 log (用于非结果性的说明性输出) ----
say() {  # say <header text>
    [ "$JSON_OUTPUT" = 1 ] && return 0
    printf '\n%b=== %s ===%b\n' "$_C_BOLD$_C_CYAN" "$1" "$_C_RESET"
}

# ============================================================
# Telegram 通知 — 复用 nodeAgent.sh 的节流推送 (仅 FAIL 时推送)
#   --no-notify 时全部抑制: 供 nodeAgent 等程序化调度使用,
#   由调用方按自身语义组织通知 (避免一次事件双重告警刷屏)
# ============================================================
_NotifyTG() {
    [ "$NO_NOTIFY" = 1 ] && return 0
    [ "$_FAIL" = 0 ] && return 0   # 无失败不推送
    _token="${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
    _chat="${TELEGRAM_CHAT_ID:-${TG_CHAT_ID:-}}"
    { [ -z "$_token" ] || [ -z "$_chat" ]; } && return 0
    _ip=$(hostname -I 2>/dev/null | awk '{print $1}'); [ -z "$_ip" ] && _ip=$(hostname)
    _text="🚨 [NodeHub] ${_SCRIPT_NAME} 诊断告警
主机: ${_ip}
失败 ${_FAIL} 项 / 警告 ${_WARN} 项
$(grep '^FAIL' "$_RESULTS_FILE" | head -8 | cut -f3 | sed 's/^/• /')"
    curl -sS --connect-timeout 5 --max-time 15 \
        --data-urlencode "chat_id=${_chat}" --data-urlencode "text=${_text}" \
        "https://api.telegram.org/bot${_token}/sendMessage" >/dev/null 2>&1 || true
}

# 直接发送一条 Telegram (不依赖 _FAIL 计数, 供单项检查中途即时告警)
# 用法: _TgSend <message>
_TgSend() {
    [ "$NO_NOTIFY" = 1 ] && return 0
    _token="${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
    _chat="${TELEGRAM_CHAT_ID:-${TG_CHAT_ID:-}}"
    { [ -z "$_token" ] || [ -z "$_chat" ]; } && return 0
    curl -sS --connect-timeout 5 --max-time 15 \
        --data-urlencode "chat_id=${_chat}" --data-urlencode "text=$1" \
        "https://api.telegram.org/bot${_token}/sendMessage" >/dev/null 2>&1 || true
}

# ============================================================
# 通用检测小工具
# ============================================================
# 命令是否存在
has() { command -v "$1" >/dev/null 2>&1; }

# 安全读取数字 (失败返回默认值)
_num() {  # _num <value> <default>
    case "$1" in
        ''|*[!0-9-]*) echo "$2" ;;
        *) echo "$1" ;;
    esac
}

# ============================================================
# 基础环境检查 (env) — 影响安装能否成功
# ============================================================
check_env() {
    say "基础环境 (磁盘 / 内存 / 时间 / DNS / 依赖 / 包锁)"

    # E1. 磁盘空间 — 根分区使用率
    _root_use=$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    _root_use=$(_num "$_root_use" 0)
    if [ "$_root_use" -ge 95 ]; then
        result FAIL "ENV_DISK_FULL" "根分区已使用 ${_root_use}% (≥95%)" \
            "磁盘满会导致: 写不了日志/临时文件/证书, 安装中断, 服务启动失败。清理: apt clean / 删旧日志 / du -sh /* | sort -h"
    elif [ "$_root_use" -ge 85 ]; then
        result WARN "ENV_DISK_HIGH" "根分区已使用 ${_root_use}% (≥85%)" "建议清理, 逼近 95% 将影响服务"
    else
        result PASS "ENV_DISK_OK" "根分区使用率 ${_root_use}%"
    fi

    # E2. 内存 — free -m, swap
    _mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')   # available
    _swap=$(free -m 2>/dev/null | awk '/^Swap:/{print $4}')
    _mem=$(_num "$_mem" 0); _swap=$(_num "$_swap" 0)
    if [ "$_mem" -lt 50 ] && [ "$_swap" -lt 50 ]; then
        result FAIL "ENV_OOM_RISK" "可用内存 ${_mem}MB + swap ${_swap}MB 严重不足 (<50MB)" \
            "极易触发 OOM Killer 杀掉 xray/nginx。检查: dmesg | grep -i 'killed process'"
    elif [ "$_mem" -lt 128 ]; then
        result WARN "ENV_MEM_LOW" "可用内存仅 ${_mem}MB" "高峰期可能 OOM, 建议加 swap"
    else
        result PASS "ENV_MEM_OK" "可用内存 ${_mem}MB / swap ${_swap}MB"
    fi

    # E3. 系统时间同步 (TLS 握手关键依赖, 时钟偏差>5min 会握手失败)
    if has timedatectl; then
        _sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
        _offset=$(timedatectl timesync-status 2>/dev/null | sed -n 's/.*Offset= *\([0-9.-]*\).*/\1/p' | head -1)
        _offset=$(_num "${_offset%.*}" 0)
        if [ "$_sync" = "no" ] || [ -z "$_sync" ]; then
            result WARN "ENV_TIME_NOSYNC" "NTP 未同步 (NTPSynchronized=$_sync)" \
                "时钟偏差过大会导致: TLS 握手失败 (cert not yet valid/expired), 证书校验异常。修复: systemctl enable --now systemd-timesyncd"
        else
            _abs=${_offset#-}
            if [ "$_abs" -gt 300 ]; then
                result FAIL "ENV_TIME_SKEW" "系统时间偏差约 ${_offset}秒 (绝对值>300s)" "TLS 会因证书时间校验失败而无法握手"
            else
                result PASS "ENV_TIME_OK" "NTP 已同步, 偏差约 ${_offset}s"
            fi
        fi
    else
        result WARN "ENV_TIME_UNKNOWN" "无 timedatectl, 无法确认时间同步状态" "请手动确认 date 输出是否准确"
    fi

    # E4. DNS 解析 — 能否解析公共域名 (装包/下载二进制前提)
    if has getent; then
        if getent hosts github.com >/dev/null 2>&1; then
            result PASS "ENV_DNS_OK" "DNS 解析正常 (github.com 可解析)"
        else
            result FAIL "ENV_DNS_FAIL" "DNS 解析失败 (getent hosts github.com 失败)" \
                "会导致 apt/yum 装包失败, xray 二进制下载失败。检查: /etc/resolv.conf 是否有 nameserver"
        fi
    else
        result WARN "ENV_DNS_UNKNOWN" "无 getent, 跳过 DNS 检测"
    fi

    # E5. 包管理器锁占用 — apt/dpkg 正在被占用会卡住安装
    if has fuser; then
        _locks=""
        for _l in /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/run/yum.pid; do
            if [ -e "$_l" ] && fuser "$_l" >/dev/null 2>&1; then
                _locks="$_locks $_l"
            fi
        done
        if [ -n "$_locks" ]; then
            result WARN "ENV_PKG_LOCK" "包管理器锁被占用:$_locks" \
                "可能有 apt/dpkg 正在运行; 若卡死: ps aux | grep apt, 必要时 rm 锁文件并 dpkg --configure -a"
        else
            result PASS "ENV_PKG_LOCK_OK" "包管理器锁空闲"
        fi
    fi

    # E6. 关键依赖 — 代理安装脚本常用工具
    _missing=""
    for _t in curl wget unzip tar jq; do
        has "$_t" || _missing="$_missing $_t"
    done
    if [ -n "$_missing" ]; then
        result WARN "ENV_DEPS_MISSING" "缺少依赖工具:$_missing" \
            "安装脚本可能依赖这些工具; 缺 jq 会无法解析 xray JSON 配置。修复: apt install -y$_missing"
    else
        result PASS "ENV_DEPS_OK" "关键依赖 (curl/wget/unzip/tar/jq) 齐全"
    fi

    # E7. 架构识别 — 防止下错二进制 (exec format error)
    _arch=$(uname -m)
    case "$_arch" in
        x86_64|amd64) result PASS "ENV_ARCH_OK" "CPU 架构: $_arch (x86_64)" ;;
        aarch64|arm64) result PASS "ENV_ARCH_OK" "CPU 架构: $_arch (arm64)" ;;
        *) result WARN "ENV_ARCH_UNK" "CPU 架构: $_arch (非主流 x86/arm)" "确认安装脚本下载了对应架构的二进制, 否则启动报 'exec format error'" ;;
    esac

    # E8. 面板辅助脚本完整性 — 0 字节空文件会让 source 静默成功但函数未定义
    #   真实故障 (2026-08-05, 198.12.124.74):
    #     /root/panels/panel-common.sh 等为 0 字节空文件 (6/12 一次失败下载 wget -O 残留)。
    #     install 脚本用 [ -f ] 只判【存在】→ 误判“已存在”并跳过“从 NODEHUB_URL 重下”兜底分支 →
    #     source 空文件静默成功但 DetectTransportMode 未定义 → _TRANSPORT_MODE 从未赋值 →
    #     第 1603 行 set -eu 触发 "_TRANSPORT_MODE: parameter not set" 退出码 2。
    #   教训: 判“文件可用”必须用 [ -s ](非空) 而非 [ -f ](存在);
    #         wget -O 失败仍会创建 0 字节目标文件, 需显式校验大小。
    _panel_found=""
    for _d in "$HOME/panels" "/tmp/panels" "/root/panels"; do
        [ -d "$_d" ] && { _panel_found="$_d"; break; }
    done
    if [ -n "$_panel_found" ]; then
        _empty_p=""; _ok_p=""
        for _f in panel-common.sh panel-1panel.sh panel-btpanel.sh; do
            _p="$_panel_found/$_f"
            if [ -e "$_p" ]; then
                if [ ! -s "$_p" ]; then _empty_p="$_empty_p $_p"; else _ok_p="$_ok_p $_f"; fi
            fi
        done
        if [ -n "$_empty_p" ]; then
            result FAIL "ENV_PANEL_SCRIPT_EMPTY" "面板辅助脚本为 0 字节空文件:$_empty_p" \
                "空文件让安装脚本 source 静默成功但【不定义任何函数】(如 DetectTransportMode), 后续 set -u 访问未赋值变量直接退出 (典型报错 '_TRANSPORT_MODE: parameter not set' 退出码 2)。成因: 历史失败下载 wget -O 残留 0 字节文件, install 用 [ -f ] 只判存在误判'已存在'而跳过重下。修复: rm -f$_empty_p 后重跑安装 (会从 NODEHUB_URL 重新下载真实文件)"
        elif [ -n "$_ok_p" ]; then
            result PASS "ENV_PANEL_SCRIPT_OK" "面板辅助脚本完整 ($_panel_found):$_ok_p"
        fi
    fi

    # E9. 小内存代理节点无 swap — 把"可恢复的 OOM"恶化为"整机硬死锁"
    #   真实故障 (2026-08-08, 103.173.155.212): 1核1GB 无 swap 的节点, conntrack 打满引发
    #   内存耗尽时, 内核来不及触发 OOM Killer、也来不及写任何日志 → 整机硬挂 (宕机 10h 才
    #   人工重启)。有 swap 兜底则多数情况能 OOM-kill 掉元凶进程后自愈, 而非死锁。
    #   判定: 本机部署了 xray(代理) + 内存<2GB + 无 swap → 风险。
    _has_xray=0
    if [ -x "${_XRAY_BIN:-/usr/local/bin/xray}" ] \
       || [ -f /etc/systemd/system/xray.service ] \
       || [ -f /lib/systemd/system/xray.service ]; then
        _has_xray=1
    fi
    if [ "$_has_xray" = 1 ]; then
        _tot_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
        _tot_mb=$(_num "$_tot_mb" 0)
        _swap_tot=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')   # swap 总量(MB)
        _swap_tot=$(_num "$_swap_tot" 0)
        if [ "$_tot_mb" -gt 0 ] && [ "$_tot_mb" -lt 2048 ] && [ "$_swap_tot" -eq 0 ]; then
            result WARN "ENV_NO_SWAP_PROXY" "代理节点内存 ${_tot_mb}MB 且【无 swap】" \
                "小内存代理节点无 swap 时, 内存尖峰(conntrack 打满/连接暴增)会从 'OOM-kill 自愈' 恶化为 '整机硬死锁'(本次 103.173.155.212 死机的放大器: 宕机 10h)。修复: fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile, 并写入 /etc/fstab (proxyInstall.sh 的 TuneKernelForProxy 已对小节点自动处理)"
        else
            result PASS "ENV_SWAP_OK" "内存 ${_tot_mb}MB / swap ${_swap_tot}MB"
        fi
    fi
}

# ============================================================
# xray 检查
# ============================================================
_XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
_XRAY_CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"
_XRAY_DIR="${_XRAY_CONF%/*}"
_XRAY_SERVICE="xray"

check_xray() {
    say "xray (二进制 / 配置 / 服务 / 端口冲突 / 证书 / geo / OOM)"

    # X1. 二进制存在 + 可执行
    if [ ! -e "$_XRAY_BIN" ]; then
        result FAIL "XRAY_BIN_MISSING" "xray 二进制不存在: $_XRAY_BIN" \
            "重新安装 xray-core (下载对应架构二进制到 $_XRAY_BIN 并 chmod +x)"
        return  # 二进制都没有, 后续检查无意义
    fi
    if [ ! -x "$_XRAY_BIN" ]; then
        result FAIL "XRAY_BIN_NOEXEC" "xray 二进制无执行权限: $_XRAY_BIN" "修复: chmod +x $_XRAY_BIN"
    else
        result PASS "XRAY_BIN_OK" "xray 二进制存在且可执行"
    fi

    # X2. 二进制能运行 (架构不匹配会报 exec format error)
    _ver=$("$_XRAY_BIN" -version 2>&1 | head -1)
    case "$_ver" in
        *Xray*) result PASS "XRAY_VER_OK" "xray 版本: $(echo "$_ver" | awk '{print $2,$3}')" ;;
        *"exec format error"*|*"cannot execute binary file"*)
            result FAIL "XRAY_BIN_ARCH" "二进制架构不匹配, 无法执行: $_ver" \
                "下载了错误 CPU 架构的 xray。本机: $(uname -m), 请重新下载对应架构版本" ;;
        *) result WARN "XRAY_VER_UNK" "xray -version 输出异常: $_ver" ;;
    esac

    # X3. 配置文件存在
    if [ ! -f "$_XRAY_CONF" ]; then
        result FAIL "XRAY_CONF_MISSING" "配置文件不存在: $_XRAY_CONF" \
            "生成配置 (x-ui/3x-ui 面板或手写), 或从备份恢复"
        return
    fi
    result PASS "XRAY_CONF_OK" "配置文件存在: $_XRAY_CONF"

    # X4. JSON 语法 + xray 自检
    _test=$("$_XRAY_BIN" -test -config "$_XRAY_CONF" 2>&1)
    case "$_test" in
        *"Configuration OK"*) result PASS "XRAY_CONF_OK2" "xray -test 通过 (Configuration OK)" ;;
        *)
            _err=$(echo "$_test" | grep -iE 'error|invalid|failed' | head -1)
            result FAIL "XRAY_CONF_BAD" "xray 配置语法/校验失败" "${_err:-$_test}" ;;
    esac

    # X5. systemd 单元存在 + 未被 mask
    if ! has systemctl; then
        result WARN "XRAY_NO_SYSTEMD" "无 systemctl, 跳过服务检查 (非 systemd 系统)" ; return
    fi
    if ! systemctl list-unit-files "$_XRAY_SERVICE.service" >/dev/null 2>&1 \
       && [ ! -f "/etc/systemd/system/$_XRAY_SERVICE.service" ] \
       && [ ! -f "/lib/systemd/system/$_XRAY_SERVICE.service" ]; then
        result FAIL "XRAY_UNIT_MISSING" "systemd 单元不存在: $_XRAY_SERVICE.service" \
            "创建 /etc/systemd/system/$_XRAY_SERVICE.service 并 systemctl daemon-reload"
    fi
    _masked=$(systemctl is-enabled "$_XRAY_SERVICE.service" 2>/dev/null)
    case "$_masked" in
        masked) result FAIL "XRAY_MASKED" "服务被 mask (systemctl unmask $_XRAY_SERVICE)" "" ;;
        enabled|disabled|static) : ;;
    esac

    # X6. 当前服务状态 + 失败详情
    _state=$(systemctl is-active "$_XRAY_SERVICE.service" 2>/dev/null)
    if [ "$_state" = "active" ]; then
        result PASS "XRAY_ACTIVE" "xray 服务运行中 (active)"
    else
        # X7. 失败原因诊断
        _result=$(systemctl show "$_XRAY_SERVICE.service" -p Result --value 2>/dev/null)
        _exec_status=$(systemctl show "$_XRAY_SERVICE.service" -p ExecMainStatus --value 2>/dev/null)
        _nrestart=$(systemctl show "$_XRAY_SERVICE.service" -p NRestarts --value 2>/dev/null)
        # 取最近一条 xray 错误日志
        _lasterr=$(journalctl -u "$_XRAY_SERVICE.service" -n 80 --no-pager 2>/dev/null \
                   | grep -iE 'failed to|error|bind|address already in use|exec format|no such file|permission' \
                   | tail -1)
        _detail="状态=$_state Result=$_result ExecMainStatus=$_exec_status NRestarts=$_nrestart"
        [ -n "$_lasterr" ] && _detail="$_detail | 日志: $_lasterr"
        result FAIL "XRAY_INACTIVE" "xray 未运行 (state=$_state)" "$_detail"
    fi

    # X8. 重启风暴 — systemd 因反复失败放弃拉起 (本次故障现象)
    _nrestart=$(_num "$(systemctl show "$_XRAY_SERVICE.service" -p NRestarts --value 2>/dev/null)" 0)
    if [ "$_nrestart" -ge 5 ]; then
        _storm=$(journalctl -u "$_XRAY_SERVICE.service" --no-pager 2>/dev/null | grep -i 'repeated too quickly' | tail -1)
        if [ -n "$_storm" ]; then
            result WARN "XRAY_RESTART_STORM" "systemd 因重启风暴放弃拉起 (NRestarts=$_nrestart)" \
                "systemctl reset-failed $_XRAY_SERVICE 后再 start。根因通常是: 端口占用/配置错误/证书缺失, 见其它 FAIL 项"
        fi
    fi

    # X9. 端口冲突 — nginx↔xray 同协议同端口抢占 (协议感知) + xray 端口运行时占用
    _PortOverlapCheck
    _XrayPortRuntimeCheck

    # X10. 证书文件存在 + 可读 (扫描配置里的 certificateFile / keyFile)
    _check_cert_refs_in_xray "$_XRAY_CONF"

    # X11. geo 数据文件 (geoip.dat / geosite.dat)
    _check_geo_files "$_XRAY_DIR"

    # X12. 近期 OOM 杀进程记录
    _check_oom_for xray
}

# ============================================================
# 端口声明与冲突检测 (核心: nginx ↔ xray 抢占; 协议感知)
#
# 关键认知 (本机实测修正旧逻辑的假阳性):
#   · "端口号" 不是端口的唯一身份 —— (协议, 端口) 才是。
#     TCP 与 UDP 是【两个独立命名空间】: TCP:443 与 UDP:443 可同时被不同进程监听,
#     互不冲突。典型: nginx listen 443 ssl (TCP) + xray hysteria (UDP) 同处 443,
#     这是【正常共存】而非抢占 (本机正是此态)。
#   · 旧逻辑只比端口号 → 把 "xray UDP:443 + nginx TCP:443" 误报为冲突 (假阳性)。
#     新逻辑按 (proto, port) 元组判定, 才能真正区分下列 4 类抢占实况。
#
# 设计:
#   · 允许 xray 占用其自身声明的 (proto, port)
#   · 允许 nginx 占用其自身声明的 (proto, port)
#   · 真冲突 = 双方【同协议同端口】声明 → 只能存活一个, 抢失败者
#     'bind: address already in use' 退出。再按【当前谁实际占用】细分 4 类根因。
#   · 次要风险 = 某服务声明的 (proto, port) 被【无关第三方进程】占用
#
# 三类检查 (每个 (proto,port) 只报告一次):
#   1) _PortOverlapCheck     : 同协议同端口双重声明 → FAIL, 并按运行时占用者细分根因
#   2) _XrayPortRuntimeCheck : xray 独占 (proto,port) 的运行时占用 (跳过已报告的重叠项)
#   3) _NginxPortRuntimeCheck: nginx 独占 (proto,port) 的运行时占用 (跳过已报告的重叠项)
# 另: 同端口号不同协议 (跨协议共存) → PASS, 显式标注 (回答 "到底有没有冲突")
# ============================================================

# ---- 返回 xray 声明的 (协议, 端口): 每行 "proto port", 去重 ----
# 协议判定:
#   protocol ∈ {hysteria, hysteria2, tuic}        → UDP
#   streamSettings.network ∈ {kcp, quic}          → UDP  (mKCP / QUIC 走 UDP)
#   其余 (vless/vmess/trojan/shadowsocks/dokodemo) → TCP
# inbound.port 仅取纯数字 (丢弃 "1000-2000" 范围)
_XrayDeclaredProtoPorts() {
    [ -f "$_XRAY_CONF" ] && has jq || return 0
    jq -r '
      .inbounds[]?
      | (.protocol // "") as $pr
      | (.streamSettings.network // "") as $nw
      | ((.port // "") | tostring) as $p
      | select($p | test("^[0-9]+$"))
      | (if ($pr=="hysteria" or $pr=="hysteria2" or $pr=="tuic"
             or $nw=="kcp" or $nw=="quic")
          then "udp" else "tcp" end) + " " + $p
    ' "$_XRAY_CONF" 2>/dev/null | sort -u
}

# ---- 返回 nginx 声明的 (协议, 端口): 每行 "proto port", 去重 ----
# listen 形态: `80` / `443 ssl` / `[::]:443 ssl` / `1234 udp` / `127.0.0.1:8088`
# → listen 后第一个 token 取最后冒号后部分 (剥离 IP 前缀) = port;
#   同行含 ` udp ` 关键字 → UDP, 否则 TCP (nginx 默认 TCP)。
#   HTTP/3 的 `listen ... quic` 同样监听 UDP (仅写法不带 udp 字样), 必须一并判为 UDP,
#   否则 nginx QUIC 的 UDP:443 会被误判为 TCP → 与 xray UDP:443 的真实抢占漏报。
# 先剥离 # 注释, 否则 `# listen 443 ssl;` 会被误判为真实声明。
_NginxDeclaredProtoPorts() {
    has nginx || return 0
    if nginx -T >/dev/null 2>&1; then
        nginx -T 2>/dev/null
    else
        grep -rhE '.' "$_NGINX_CONF_DIR" 2>/dev/null
    fi | sed 's/#.*//' | awk '
        /[[:space:]]listen[[:space:]]/ || /^listen[[:space:]]/ {
            line=$0
            proto = (line ~ /[[:space:]](udp|quic)([[:space:];]|$)/) ? "udp" : "tcp"
            sub(/.*listen[[:space:]]+/, "", line)
            token=line; sub(/[[:space:];].*/, "", token); sub(/.*:/, "", token)
            if (token ~ /^[0-9]+$/) print proto" "token
        }
    ' | sort -u
}

# ---- 某 (协议, 端口) 的运行时占用进程名 (换行分隔, 去重) ----
# 精确匹配: netid 前缀 = proto (tcp 匹配 tcp/tcp6), 本地地址【最后冒号后】= port。
# 避免旧 `grep "[:.]$port\b"" 把 :443 误匹到 :8443 / IPv6 地址段等子串。
_RuntimeHoldersProto() {  # $1 = tcp|udp , $2 = port
    ss -H -tulnp 2>/dev/null | awk -v p="$1" -v port="$2" '
        $1 ~ "^"p {
            la=$5; sub(/.*:/, "", la)        # port = 最后冒号后部分
            if (la == port) {
                l=$0; sub(/.*users:\(\("/, "", l); sub(/".*/, "", l); print l
            }
        }
    ' | sort -u
}

# ---- (proto,port) 是否在 "proto:port proto:port ..." 列表中 ----
_ProtoPortIn() {  # _ProtoPortIn <proto> <port> <"tcp:443 udp:443 ...">
    case " $3 " in *" $1:$2 "*) return 0 ;; esac
    return 1
}

# ---- 缓存声明 (proto,port) (避免重复解析 nginx -T / jq) ----
# _XPP / _NPP = 空格分隔的 "proto:port" token 串
_EnsureProtoPorts() {
    [ -n "${_XPP+set}" ] || _XPP=$(_XrayDeclaredProtoPorts  | awk '{print $1":"$2}' | tr '\n' ' ')
    [ -n "${_NPP+set}" ] || _NPP=$(_NginxDeclaredProtoPorts | awk '{print $1":"$2}' | tr '\n' ' ')
}

# ---- 核心: 同协议同端口双重声明抢占检查 (幂等, 全程仅报告一次) ----
# 命中后按【当前谁实际占用】细分 4 类根因, 给出针对性修复建议。
_PORT_OVERLAP_DONE=0
_PortOverlapCheck() {
    [ "$_PORT_OVERLAP_DONE" = 1 ] && return 0
    _PORT_OVERLAP_DONE=1
    has nginx && has jq && [ -f "$_XRAY_CONF" ] || { _ReportCrossProtoCoexist; return 0; }
    _EnsureProtoPorts
    [ -n "$_XPP" ] && [ -n "$_NPP" ] || { _ReportCrossProtoCoexist; return 0; }

    for _tok in $_XPP; do
        _proto=${_tok%%:*}; _port=${_tok#*:}
        # 只看 nginx 也【同协议同端口】声明的项
        _ProtoPortIn "$_proto" "$_port" "$_NPP" || continue
        _h=$(_RuntimeHoldersProto "$_proto" "$_port")
        # 统计占用者类别 (xray / nginx / 第三方)
        _hx=0; _hn=0; _ho=""
        while IFS= read -r _pn; do
            [ -n "$_pn" ] || continue
            case "$_pn" in
                xray|xray-core) _hx=1 ;;
                nginx)          _hn=1 ;;
                *)              _ho="${_ho:+$_ho,}$_pn" ;;
            esac
        done <<__H
$_h
__H
        _tag="$_proto/$_port"
        if [ "$_hx" = 1 ]; then
            # xray 抢到了 → nginx 是 bind 失败方
            result FAIL "PORT_DUAL_DECL_XRAY_WON_${_port}" \
                "${_tag} 同时被 xray 与 nginx 声明 → 抢占冲突 (当前 xray 占用, nginx bind 失败)" \
                "根因: 同协议同端口只能有一个监听者; xray 先启动已抢到, nginx 启动必然 'address already in use' 失败。修复: 让 nginx 让出 ${_tag} (改 listen 端口如 8443; 或 xray 走 nginx 反代 / SNI 分流, 二者只留一个对外)"
        elif [ "$_hn" = 1 ]; then
            # nginx 抢到了 → xray 是 bind 失败方
            result FAIL "PORT_DUAL_DECL_NGINX_WON_${_port}" \
                "${_tag} 同时被 xray 与 nginx 声明 → 抢占冲突 (当前 nginx 占用, xray bind 失败)" \
                "根因: nginx 先启动已抢到 ${_tag}, xray 启动必然 'address already in use' 失败退出。修复: 让 xray 让出 ${_tag} (改 inbound.port; 或 nginx 反代到 xray, xray 改 listen 127.0.0.1)"
        elif [ -n "$_ho" ]; then
            # 第三方占用 → xray 和 nginx 都会失败
            result FAIL "PORT_DUAL_DECL_3RD_${_port}" \
                "${_tag} 同时被 xray 与 nginx 声明, 但已被无关进程 [${_ho}] 占用 → 两边都会 bind 失败" \
                "根因: 真正占住端口的是第三方 [${_ho}], xray 与 nginx 谁也抢不到。修复: 先查清 [${_ho}] 是什么 (ss -tulnp / lsof -i :${_port}), 停掉或迁移它, 再重启 xray/nginx; 切勿盲目重启 xray/nginx"
        else
            # 没人占用 → 两边都没起来 (服务 down / 配置错 / 反复 bind 失败被 systemd 放弃)
            result FAIL "PORT_DUAL_DECL_NONE_${_port}" \
                "${_tag} 同时被 xray 与 nginx 声明, 但当前无任何进程占用 → 二者均未成功监听" \
                "根因: 端口本身空闲, 说明 xray 和 nginx 都没跑起来 (而非互相抢占)。看 X6/X7 服务状态项与 journalctl: 可能服务 down、配置语法错、证书缺失、或反复 bind 失败被 systemd 'start-limit hit' 放弃。先 systemctl reset-failed 再 start"
        fi
    done

    _ReportCrossProtoCoexist
}

# ---- 同端口号不同协议 = 跨协议共存 (非冲突), 显式 PASS ----
# 回答疑问: "xray 和 nginx 都用 443, 到底有没有冲突? 叫什么?"
#   → 若二者协议不同 (一 TCP 一 UDP), 这是【跨协议共存】, 完全正常。
#     每个 (proto,port) 只报一次, 以 xray 侧为准。
_ReportCrossProtoCoexist() {
    [ -n "$_XPP" ] && [ -n "$_NPP" ] || return 0
    _reported=""
    for _tok in $_XPP; do
        _xp=${_tok%%:*}; _xport=${_tok#*:}
        # 跳过同协议同端口 (已在 _PortOverlapCheck 处理)
        _ProtoPortIn "$_xp" "$_xport" "$_NPP" && continue
        # 该端口号是否已报告过 (避免 xray 多 inbound 重复)
        case " $_reported " in *" $_xport "*) continue ;; esac
        # nginx 是否声明了同端口号 (但不同协议)?
        for _ntok in $_NPP; do
            _nport=${_ntok#*:}
            [ "$_nport" = "$_xport" ] || continue
            _np=${_ntok%%:*}
            [ "$_np" = "$_xp" ] && continue
            _reported="$_reported $_xport"
            result PASS "PORT_CROSS_PROTO_${_xport}" \
                "端口 ${_xport} 跨协议共存: xray=${_xp}/${_xport} + nginx=${_np}/${_xport} → 非冲突" \
                "TCP 与 UDP 是独立命名空间, 同端口号可分别被监听, 互不影响 (典型: nginx TCP:443 ssl + xray UDP:443 hysteria)。这是健康状态, 无需处理"
        done
    done
}

# ---- xray 独占 (proto,port) 的运行时占用检查 (允许 xray 自身占用) ----
_XrayPortRuntimeCheck() {
    [ -f "$_XRAY_CONF" ] && has jq || return 0
    _EnsureProtoPorts
    for _tok in $_XPP; do
        _proto=${_tok%%:*}; _port=${_tok#*:}
        # 跳过与 nginx 同协议同端口 (已由 _PortOverlapCheck 报告)
        _ProtoPortIn "$_proto" "$_port" "$_NPP" && continue
        _h=$(_RuntimeHoldersProto "$_proto" "$_port")
        if printf '%s\n' "$_h" | grep -qx 'xray'; then
            result PASS "PORT_XRAY_LISTEN_${_proto}_${_port}" "${_proto}/${_port}: xray 正在监听 (允许占用)"
        elif [ -z "$_h" ]; then
            result PASS "PORT_FREE_${_proto}_${_port}" "${_proto}/${_port}: 空闲, 可供 xray 使用"
        else
            _how=$(printf '%s' "$_h" | tr '\n' ',' | sed 's/,$//')
            result FAIL "PORT_OCCUPIED_${_proto}_${_port}" "${_proto}/${_port}: xray 需要该端口, 但被无关进程 [$_how] 占用" \
                "停止 [$_how] 或让 xray 改用空闲端口 (注意: 仅【同协议同端口】才算占用; 若仅另一协议占用同端口号则不冲突)"
        fi
    done
}

# ---- nginx 独占 (proto,port) 的运行时占用检查 (允许 nginx 自身占用) ----
_NginxPortRuntimeCheck() {
    has nginx || return 0
    _EnsureProtoPorts
    for _tok in $_NPP; do
        _proto=${_tok%%:*}; _port=${_tok#*:}
        _ProtoPortIn "$_proto" "$_port" "$_XPP" && continue   # 跳过重叠项
        _h=$(_RuntimeHoldersProto "$_proto" "$_port")
        if printf '%s\n' "$_h" | grep -qx 'nginx'; then
            result PASS "PORT_NGINX_LISTEN_${_proto}_${_port}" "${_proto}/${_port}: nginx 正在监听"
        elif [ -z "$_h" ]; then
            result PASS "PORT_NGINX_FREE_${_proto}_${_port}" "${_proto}/${_port}: 空闲, 可供 nginx 使用"
        else
            _how=$(printf '%s' "$_h" | tr '\n' ',' | sed 's/,$//')
            result FAIL "NGINX_PORT_OCCUPIED_${_proto}_${_port}" "${_proto}/${_port}: nginx 需要该端口, 但被无关进程 [$_how] 占用" \
                "停止 [$_how] 或修改 nginx listen 端口"
        fi
    done
}

# ---- 扫描 xray 配置中的证书引用, 检查存在/可读/过期 ----
_check_cert_refs_in_xray() {
    _cfg="$1"; [ -f "$_cfg" ] || return 0; has jq || return 0
    _certs=$(jq -r '.. | .certificateFile? // empty' "$_cfg" 2>/dev/null | sort -u)
    _keys=$(jq -r '.. | .keyFile? // empty' "$_cfg" 2>/dev/null | sort -u)
    for _f in $_certs; do
        [ -n "$_f" ] || continue
        case "$_f" in /*) : ;; *) continue ;; esac   # 只查绝对路径
        _check_cert_file "$_f" XRAY_CERT
    done
    # 密钥文件不做过期检查, 只查存在/可读
    for _f in $_keys; do
        [ -n "$_f" ] || continue
        case "$_f" in /*) : ;; *) continue ;; esac
        if [ ! -e "$_f" ]; then
            result FAIL "XRAY_CERT_MISSING" "配置引用的密钥不存在: $_f" "xray 启动会因找不到密钥而失败; 补齐证书或修正路径"
        elif [ ! -r "$_f" ]; then
            result FAIL "XRAY_CERT_NOREAD" "密钥不可读: $_f" "检查文件权限与运行用户 (systemd User=)"
        fi
    done
}

# ---- geo 数据文件 ----
_check_geo_files() {
    _dir="$1"
    # xray 默认在二进制同目录或 conf 目录找 geoip.dat/geosite.dat
    for _loc in "$_dir" "$(dirname "$_XRAY_BIN")" "/usr/local/share/xray" "/usr/share/xray"; do
        [ -d "$_loc" ] || continue
        for _geo in geoip.dat geosite.dat; do
            [ -f "$_loc/$_geo" ] && _found_geo="$_loc/$_geo"
        done
    done
    if [ -n "$_found_geo" ]; then
        result PASS "XRAY_GEO_OK" "geo 数据文件就绪: $_found_geo"
    else
        result WARN "XRAY_GEO_MISSING" "未找到 geoip.dat / geosite.dat" \
            "若配置用到 geosite/geoip 路由规则, 缺失会导致分流失效或启动报错; 下载到 conf 目录"
    fi
}

# ============================================================
# nginx 检查
# ============================================================
_NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
_NGINX_SERVICE="nginx"

check_nginx() {
    say "nginx (二进制 / 配置测试 / 服务 / 端口冲突 / 证书 / 用户 / include)"

    # N1. 已安装
    if ! has nginx; then
        if [ "$TARGET" = "all" ]; then
            result WARN "NGINX_ABSENT" "未安装 nginx (若该节点本应使用 nginx 反代则需安装)" ""
        fi
        return
    fi
    result PASS "NGINX_INSTALLED" "nginx 已安装: $(nginx -v 2>&1 | sed 's#.*/##')"

    # N2. 配置测试 nginx -t
    _t=$(nginx -t 2>&1)
    case "$_t" in
        *"test is successful"*|*"syntax is ok"*) result PASS "NGINX_CONF_OK" "nginx -t 通过" ;;
        *)
            _err=$(echo "$_t" | grep -iE 'emerg|error|failed' | head -2)
            result FAIL "NGINX_CONF_BAD" "nginx -t 失败" "${_err:-$_t}" ;;
    esac

    # N3. 服务状态
    if has systemctl; then
        _ns=$(systemctl is-active "$_NGINX_SERVICE.service" 2>/dev/null)
        if [ "$_ns" = "active" ]; then
            result PASS "NGINX_ACTIVE" "nginx 服务运行中"
        else
            _nerr=$(journalctl -u "$_NGINX_SERVICE.service" -n 40 --no-pager 2>/dev/null \
                    | grep -iE 'emerg|error|failed|bind|address already' | tail -1)
            result FAIL "NGINX_INACTIVE" "nginx 未运行 (state=$_ns)" "${_nerr:-无明确错误日志}"
        fi
    fi

    # N4. 端口冲突 — nginx listen 声明 vs 实际被谁占用
    _check_nginx_port_conflict

    # N5. 证书引用检查
    _check_nginx_certs

    # N6. nginx user 是否存在
    if [ -f "$_NGINX_CONF_DIR/nginx.conf" ]; then
        _u=$(grep -E '^\s*user\s+' "$_NGINX_CONF_DIR/nginx.conf" | head -1 | sed -E 's/.*user\s+([^; ]+).*/\1/')
        _u="${_u:-www-data}"
        if ! getent passwd "$_u" >/dev/null 2>&1; then
            result FAIL "NGINX_USER_MISSING" "nginx.conf 配置 user $_u 但系统无此用户" "worker 进程会启动失败; useradd $_u 或改用 www-data"
        else
            result PASS "NGINX_USER_OK" "nginx user '$_u' 存在"
        fi
    fi
}

# ---- nginx 端口冲突 (委托给统一检测: 同协议同端口双重声明 + 运行时占用) ----
# 解析逻辑已收敛到 _NginxDeclaredProtoPorts, 由 _PortOverlapCheck / _NginxPortRuntimeCheck 复用
_check_nginx_port_conflict() {
    _PortOverlapCheck
    _NginxPortRuntimeCheck
}

# ---- nginx 证书引用: 只查 /etc/nginx 下 *.conf 声明的 ssl_certificate ----
#   直接扫 .conf 文件 (不依赖 nginx -T), nginx -t 失败/服务未起也能查出引用;
#   未被任何 .conf 引用的散落证书 (如 /etc/ssl 历史遗留) 不在检查范围。
_check_nginx_certs() {
    [ -d "$_NGINX_CONF_DIR" ] || return 0
    # 剥注释后取 ssl_certificate 路径 (不含 ssl_certificate_key)
    _certs=$(find "$_NGINX_CONF_DIR" -maxdepth 3 -type f -name '*.conf' -exec sed 's/#.*//' {} + 2>/dev/null \
             | grep -E '[[:space:]]ssl_certificate[[:space:]]' \
             | sed -E 's/.*ssl_certificate[[:space:]]+//; s/[;[:space:]].*//' | sort -u)
    for _f in $_certs; do
        case "$_f" in /*) : ;; *) continue ;; esac   # 只查绝对路径
        _check_cert_file "$_f" NGINX_CERT
    done
}

# ============================================================
# TLS 证书通用检查 — 被 xray/nginx/cert 三个入口共用
# ============================================================
# ---- 证书文件综合检查 (存在/可读/过期), 按文件路径全局去重 ----
#   同一证书可能同时被 xray 配置 / nginx .conf / root_domain 扫描命中,
#   整次诊断只报告一次, 避免重复条目刷屏。
_CERT_FILES_CHECKED=""
_check_cert_file() {  # $1 = 证书路径, $2 = code 前缀 (XRAY_CERT / NGINX_CERT / CERT_ROOT_DOMAIN)
    _cf="$1"; _pfx="$2"
    case " ${_CERT_FILES_CHECKED} " in *" $_cf "*) return 0 ;; esac
    _CERT_FILES_CHECKED="${_CERT_FILES_CHECKED} $_cf"
    if [ ! -e "$_cf" ]; then
        result FAIL "${_pfx}_MISSING" "引用的证书不存在: $_cf" "启动会因找不到证书而失败; 补齐证书或修正路径"
    elif [ ! -r "$_cf" ]; then
        result FAIL "${_pfx}_NOREAD" "证书不可读: $_cf" "检查文件权限与运行用户"
    else
        result PASS "${_pfx}_OK" "证书文件就绪: $_cf"
        _check_cert_expiry "$_cf"
    fi
}

# ---- 过期检查 (仅对 PEM 文本证书) ----
_check_cert_expiry() {
    _f="$1"
    has openssl || return 0
    # 仅处理 PEM 文本证书
    grep -q 'BEGIN CERTIFICATE' "$_f" 2>/dev/null || return 0
    _end=$(openssl x509 -in "$_f" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    [ -n "$_end" ] || return 0
    # date -d 仅 GNU date 支持 (busybox/BSD date 解析失败 → 无法算剩余天数)。
    # 失败时不再静默跳过 (否则过期证书漏报无人知晓): 整次诊断只发一次 Telegram 告警,
    # 提示人工核对 (多证书扫描用 _CERT_DATE_FAIL_SENT 去重, 避免刷屏)。
    if ! _end_epoch=$(date -d "$_end" +%s 2>/dev/null) || [ -z "$_end_epoch" ]; then
        if [ -z "${_CERT_DATE_FAIL_SENT:-}" ]; then
            _CERT_DATE_FAIL_SENT=1
            result WARN "CERT_EXPIRY_CHECK_FAILED" \
                "证书过期检查无法执行 (date -d 解析失败, 非 GNU date?): $_f (到期 $_end)" \
                "本机 date 不支持 -d (busybox/BSD date), 无法计算证书剩余天数 → 过期证书可能漏报。安装 coreutils (GNU date) 或人工核对: openssl x509 -checkend 0 -noout -in <cert>"
            _TgSend "⚠️ [NodeHub] ${_SCRIPT_NAME}: 证书过期检查无法执行
主机: $(hostname -I 2>/dev/null | awk '{print $1}')
原因: date -d 解析失败 (非 GNU date), 过期证书可能漏报
首个证书: $_f (到期 $_end)
建议: 安装 coreutils 或人工 openssl x509 -checkend 0 -noout -in <cert>"
        fi
        return 0
    fi
    _now=$(date +%s)
    _days=$(( (_end_epoch - _now) / 86400 ))
    _cn=$(openssl x509 -in "$_f" -noout -subject 2>/dev/null | sed 's/^subject[= ]*//; s/.*CN *= *//; s#/.*##')
    if [ "$_days" -lt 0 ]; then
        result FAIL "CERT_EXPIRED" "证书已过期 ${_days#-} 天: $_f (CN=${_cn}, 到期 $_end)" \
            "已过期证书: xray/nginx 仍能启动但客户端 TLS 握手会失败/告警。续期: acme.sh / certbot"
    elif [ "$_days" -le 7 ]; then
        result WARN "CERT_EXPIRING" "证书即将过期 (剩 ${_days} 天): $_f (CN=${_cn})" "尽快续期"
    elif [ "$_days" -le 30 ]; then
        result WARN "CERT_RENEW_SOON" "证书 30 天内过期 (剩 ${_days} 天): $_f (CN=${_cn})" "安排续期"
    else
        result PASS "CERT_VALID" "证书有效 (剩 ${_days} 天): $_f (CN=${_cn})"
    fi
}

# ============================================================
# OOM 杀进程检查
# ============================================================
_check_oom_for() {
    _proc="$1"
    _hit=""
    if has dmesg; then
        _hit=$(dmesg 2>/dev/null | grep -iE 'out of memory|killed process' | grep -i "$_proc" | tail -1)
    fi
    if [ -z "$_hit" ]; then
        _hit=$(journalctl -k --no-pager 2>/dev/null | grep -iE 'oom|killed process' | grep -i "$_proc" | tail -1)
    fi
    if [ -n "$_hit" ]; then
        result WARN "${_proc}_OOM" "$_proc 曾被 OOM Killer 杀掉" "$_hit | 考虑加 swap 或限制内存"
    fi
}

# ============================================================
# 网络与防火墙 (net)
# ============================================================
check_net() {
    say "网络与防火墙 (iptables / ufw / firewalld / SELinux / conntrack / sysctl / NODE_PORT 对外可达与大陆 tcping)"

    # NW1. iptables DROP/REJECT 规则 (可能拦截代理端口)
    if has iptables; then
        _drop=$(iptables -L -n 2>/dev/null | grep -ciE 'DROP|REJECT')
        if [ "$_drop" -gt 5 ]; then
            result WARN "NET_IPTABLES_DROP" "iptables 有 $_drop 条 DROP/REJECT 规则" \
                "iptables -L -n --line-numbers 检查是否误拦了 xray/nginx 端口 (443/80/自定义)"
        else
            result PASS "NET_IPTABLES_OK" "iptables DROP/REJECT 规则数 $_drop (低)"
        fi
    fi

    # NW2. ufw
    if has ufw; then
        _ufw=$(ufw status 2>/dev/null | head -1)
        case "$_ufw" in
            *"inactive"*) result PASS "NET_UFW_OFF" "ufw 未启用" ;;
            *"active"*)   result WARN "NET_UFW_ON" "ufw 已启用, 确认放行了代理端口" "ufw status 查看, ufw allow 443/tcp 放行" ;;
        esac
    fi

    # NW3. firewalld
    if has firewall-cmd; then
        if systemctl is-active firewalld >/dev/null 2>&1; then
            result WARN "NET_FIREWALLD_ON" "firewalld 已启用, 确认放行了代理端口" "firewall-cmd --list-ports"
        else
            result PASS "NET_FIREWALLD_OFF" "firewalld 未运行"
        fi
    fi

    # NW4. SELinux / AppArmor
    if has getenforce; then
        _se=$(getenforce 2>/dev/null)
        case "$_se" in
            Enforcing) result WARN "NET_SELINUX_ENF" "SELinux 处于 Enforcing 模式" \
                "可能阻止 nginx/xray 绑定非标准端口或读取证书。setenforce 0 临时放宽排查, 或 restorecon 修复标签" ;;
            Permissive|Disabled) result PASS "NET_SELINUX_OK" "SELinux: $_se" ;;
        esac
    fi

    # NW5. 提示云安全组 (本地无法检测)
    result WARN "NET_SG_REMINDER" "云厂商安全组 (AWS SG / 阿里云安全组 / GCP 防火墙) 需在控制台单独放行端口" \
        "若本地端口监听正常但外部连不上, 99% 是云安全组未放行"

    # NW6. conntrack 连接跟踪表 — 代理高并发的生命线 (本次死机根因)
    #   真实故障 (2026-08-08, 103.173.155.212): 1核1GB 跑多用户 xray, nf_conntrack_max
    #   仅默认 8192 → 开机 3 秒打满 → 海量 'table full, dropping packet' → 内存耗尽 →
    #   整机硬死锁 (日志在 xray 正常处理连接的瞬间戛然而止, 无 OOM/panic 记录, 宕机 10h)。
    #   教训: 代理节点 nf_conntrack_max 必须 ≥ 65536; 默认 8192 秒级打满。
    if [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
        _ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
        _ct_max=$(_num "$_ct_max" 8192)
        _ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
        _ct_count=$(_num "$_ct_count" 0)
        _ct_pct=0
        [ "$_ct_max" -gt 0 ] && _ct_pct=$(( _ct_count * 100 / _ct_max ))
        if [ "$_ct_max" -lt 65536 ]; then
            result FAIL "NET_CONNTRACK_TOO_SMALL" \
                "nf_conntrack_max=${_ct_max} 过小 (<代理建议 65536), 当前占用 ${_ct_count} (${_ct_pct}%)" \
                "代理多用户高并发下默认 8192 秒级打满 → 海量丢包 → 内存耗尽硬死锁 (本次 103.173.155.212 死机根因)。修复: /etc/sysctl.d/99-nodehub-proxy.conf 写 net.netfilter.nf_conntrack_max=262144 (proxyInstall.sh 的 TuneKernelForProxy 已自动处理)"
        elif [ "$_ct_pct" -ge 85 ]; then
            result WARN "NET_CONNTRACK_HIGH" "conntrack 占用 ${_ct_pct}% (${_ct_count}/${_ct_max})" "逼近上限, 检查是否有异常连接暴增; 必要时再抬高 nf_conntrack_max"
        else
            result PASS "NET_CONNTRACK_OK" "nf_conntrack_max=${_ct_max}, 占用 ${_ct_pct}% (${_ct_count})"
        fi
    fi

    # NW7. 历史打满痕迹 — 本次/上次启动的内核日志是否记录过 'table full'
    #   (-k 只看内核消息, 避免代理 access 日志撑爆管道; 'table full' 是 kernel 打印)
    if has journalctl; then
        _ctf_cur=$(journalctl -b 0 -k --no-pager 2>/dev/null | grep -c 'table full')
        _ctf_cur=$(_num "$_ctf_cur" 0)
        _ctf_prev=$(journalctl -b -1 -k --no-pager 2>/dev/null | grep -c 'table full')
        _ctf_prev=$(_num "$_ctf_prev" 0)
        if [ "$_ctf_cur" -gt 0 ]; then
            result FAIL "NET_CONNTRACK_FULL_NOW" "本次启动已记录 ${_ctf_cur} 次 'nf_conntrack: table full, dropping packet'" "连接跟踪表【正在】打满丢包, 立即抬高 nf_conntrack_max 否则随时硬死锁"
        elif [ "$_ctf_prev" -gt 50 ]; then
            result WARN "NET_CONNTRACK_FULL_LASTBOOT" "上次启动记录 ${_ctf_prev} 次 'table full' (疑似上次宕机根因)" "已重启但根因未除, 建议立即抬高 nf_conntrack_max 防止复发"
        fi
    fi

    # NW8. sysctl 配置完整性 — key= 空值坏行会让 sysctl -p 静默失败 (本次死机根因之一)
    #   真实故障 (2026-08-08, 103.173.155.212): /etc/sysctl.conf 有 6 行形如
    #   'net.netfilter.nf_conntrack_max=' (等号后为空) → sysctl -p 对空值报错, 但被
    #   install 脚本的 '2>/dev/null || true' 吞掉 → conntrack 调优静默失效 → 回退默认 8192。
    #   教训: 调优写到独立 sysctl.d 文件并用 sysctl -p 单独加载; 判空值坏行。
    _sysctl_bad=""
    for _sc in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
        [ -f "$_sc" ] || continue
        while IFS= read -r _line || [ -n "$_line" ]; do
            case "$_line" in ''|\#*) continue ;; esac
            case "$_line" in *=*) ;; *) continue ;; esac   # 无等号跳过
            _val=${_line#*=}
            _val=${_val%%#*}                                # 去行尾注释
            if [ -z "$(printf '%s' "$_val" | tr -d ' \t')" ]; then
                _k=$(printf '%s' "${_line%%=*}" | tr -d ' \t')
                _sysctl_bad="${_sysctl_bad} ${_k}"
            fi
        done < "$_sc"
    done
    if [ -n "$_sysctl_bad" ]; then
        result FAIL "NET_SYSCTL_EMPTY_VALUE" "sysctl 配置存在【空值坏行】(key= 后无值):${_sysctl_bad}" \
            "空值使 sysctl -p 对该行报错而被忽略 → 调优静默失效回退默认值 (本次死机: 6 行 conntrack 空值 → 回退 8192 → 打满死锁)。修复: 删除这些空行, 或补上正确数值"
    else
        result PASS "NET_SYSCTL_OK" "sysctl 配置无空值坏行"
    fi

    # NW9. NODE_PORT 对外可达性 (端口监听 ≠ 外部可访问; 详见 _check_node_port_external)
    _check_node_port_external

    # NW10. NODE_PORT 大陆 tcping 被墙检测 (海外可达 ≠ 大陆可达; 检出封锁时随机新端口交叉验证
    #      端口级/IP级 被墙; 详见 _check_node_port_cn_tcping)
    _check_node_port_cn_tcping
}

# ============================================================
# NODE_PORT 对外可达性 — 端口监听 ≠ 外部可访问
#   端口若只 bind 127.0.0.1/::1, 本地 ss 显示"在监听"但外部客户端永远连不上。
#   NODE_PORT 取自 ~/.env 的 NODE_PORT (默认 443)。
# ============================================================
_check_node_port_external() {
    _resolve_node_port
    # 远程目标模式 (NODE_TARGET_IP 指定了非本机 IP): ss/监听检查只对本机有意义, 跳过
    if [ -n "${NODE_TARGET_IP:-}" ] \
       && ! printf '%s' " $(hostname -I 2>/dev/null) " | grep -qF " ${NODE_TARGET_IP} "; then
        if [ "$JSON_OUTPUT" != 1 ]; then
            printf '%b    └ 远程目标模式: NODE_TARGET_IP=%s 非本机, 跳过 NODE_PORT 本机监听检查 (ss 只能看本机)%b\n' \
                "$_C_DIM" "$NODE_TARGET_IP" "$_C_RESET"
        fi
        return 0
    fi
    # 协议感知: NODE_PORT 可能承载 TCP (VLESS/TLS, nginx 反代或 xray 直听) 也可能承载
    #   UDP (Hysteria2 — proxyInstall.sh 防火墙就是按 node_port/tcp + node_port/udp 双
    #   放行的), 故用 -tulnp 同查两协议; 仅查 TCP 会对 hysteria2 直听 NODE_PORT 的
    #   节点误报 NODE_PORT_NOT_LISTENING (TCP/UDP 是两个独立命名空间, 见 _PortOverlapCheck)。
    # 注意: -tulnp 输出比 -tlnp 多首列 Netid, 本地地址从 $4 变为 $5。
    # 端口锚定用 ([^0-9]|$) 而非 \b: \b 是 GNU grep 扩展, busybox/BSD grep 不识别会静默无输出 → _listen 恒空 → 误报 NODE_PORT 无监听。
    # ([^0-9]|$) 跨实现一致, 且避免 :443 误匹到 :4430 / IPv6 地址段等子串。
    _listen=$(ss -H -tulnp 2>/dev/null | grep -E "[:.]$_NODE_PORT([^0-9]|$)")
    if [ -z "$_listen" ]; then
        # 提示实际对外监听端口 —— 常见: ~/.env 的 NODE_PORT 已过期, 实际端口在别处
        _actual=$(ss -H -tulnp 2>/dev/null | grep -E 'users:.+"(xray|nginx)"' \
                 | grep -vE '127\.0\.0\.1|::1' | awk '{print $5}' | tr '\n' ',' | sed 's/,$//')
        if [ -n "$_actual" ]; then
            _hint="实际对外监听端口: [$_actual] —— ~/.env 的 NODE_PORT=$_NODE_PORT 疑似过期, 与实际不符 (重跑安装脚本会读到错误端口搞坏代理)"
        else
            _hint="xray/nginx 均未监听任何对外端口, 检查服务是否启动"
        fi
        result FAIL "NODE_PORT_NOT_LISTENING" "NODE_PORT=$_NODE_PORT (TCP/UDP 均无监听) → 外部无法连接" \
            "$_hint。核对 ~/.env / node.json / node.env 的 NODE_PORT 与实际配置一致"
        return
    fi
    _binds=$(printf '%s\n' "$_listen" | awk '{print $5}')
    # 外部可达 = 存在非环回监听地址 (* / 0.0.0.0 / [::] / 公网IP)
    _external=$(printf '%s\n' "$_binds" | grep -vE '^(127\.|\[?::1\])' | head -1)
    if [ -n "$_external" ]; then
        _b=$(printf '%s\n' "$_listen" | awk '{print $1"/"$5}' | sort -u | tr '\n' ',' | sed 's/,$//')
        result PASS "NODE_PORT_EXTERNAL" "NODE_PORT=$_NODE_PORT 监听在对外地址 [$_b] → 外部可达" \
            "TCP/UDP 任一协议对外监听即视为可达 (Hysteria2 走 UDP)"
    else
        result FAIL "NODE_PORT_LOCALHOST_ONLY" "NODE_PORT=$_NODE_PORT 仅监听 127.0.0.1/::1 → 外部无法访问" \
            "xray inbound 的 listen 留空或设 0.0.0.0; nginx listen 行去掉 127.0.0.1: 前缀"
    fi
}

# ============================================================
# NODE_PORT 大陆 tcping 被墙检测 (NW10) — "端口在监听 + 海外可达" ≠ "大陆可达"
#
# 被墙的表现: 本机端口监听正常 / 证书有效 / 海外客户端一切正常, 但大陆方向 TCP
#   握手全部超时或重置 → 用户侧"连不上", 而节点侧常规检查全部 PASS —— 与出站 IPv4
#   被封 (check_outbound) 同属"本机一切正常"型隐蔽故障, 必须借大陆视角才能发现。
#
# 做法: 借 tcp.ping.pe 的大陆探测点对 <node_ip>:<node_port> 做 TCP 连通测试,
#   并与海外探测点【对照】; 大陆探测点覆盖三网 + 云厂两类 (2026-08 实测 13 点):
#     · 电信 China Telecom ×2 (江苏/丽水) / 移动 China Mobile ×2 / 联通 China Unicom ×2
#       —— 丽水系为原生运营商线路, 能区分【单网被墙/干扰】(仅某一家全断)
#     · 腾讯云 ×5 (成都/重庆/广州/南京/上海) + 阿里云 ×2 (青岛/上海) —— 云厂骨干对照
#   逐网展示阻断状态 (移动/电信/联通/云厂/海外 各自: 通/部分/断, ok/total):
#     · 大陆全断 + 海外基本正常 → FAIL NODE_PORT_CN_BLOCKED   (三网+云厂全断)
#     · 单网 0/N 全挂             → WARN NODE_PORT_CN_PARTIAL   (单网被墙/干扰, 列出全断网)
#     · 各网均有通有断            → WARN NODE_PORT_CN_PARTIAL   (部分线路抖动, 非封锁)
#     · 大陆全部成功              → PASS NODE_PORT_CN_OK
#   全球探测点全失败 → 不是大陆方向问题 (端口未开/安全组, 交给 NW9 判定), 不误报被墙。
#
# 交叉验证 (xcheck): 主测判出封锁 (三网全断, 或单网全挂) 时, 本机随机开一个临时 TCP
#   端口 (20000-60000, python3 优先 / socat 退路, timeout 240s 兜底自灭) 再测一轮,
#   区分【端口被墙】vs【IP 整段被墙】(处置完全不同):
#     · 新端口大陆通 (原断网恢复)  → PASS NODE_PORT_CN_XCHECK_PORT  端口级: 换端口可救, IP 未整段封
#     · 新端口大陆也全断、海外正常 → FAIL NODE_PORT_CN_IP_BLOCKED  IP 级: 换端口无效, 需 CDN/中转/换 IP
#     · 部分网恢复/部分网仍断     → WARN NODE_PORT_CN_XCHECK_MIXED / XCHECK_IP (网级封锁)
#     · 新端口全球全断            → WARN CN_XCHECK_INCONCLUSIVE: 防火墙/云安全组拦了临时端口,
#                                   无法判定 (绝不据此误报 IP 被墙; 海外作对照的同款逻辑)
#   开关: NODE_CN_TCPING=0 关整个被墙检测; NODE_CN_TCPING_XCHECK=0 只关交叉验证 (省 ~60s)。
#
# 端口来源: _resolve_node_port (NODE_PORT 环境变量 > ~/.env > ~/node.json 的 node_port
#   > ~/node.env > 默认 443), 与 NW9/安装脚本同源。
# 目标 IP 来源: ~/node.json 的 node_ip > 已 source 的 node_ip (~/.env / node.env)
#   > 公网探测 (api.ip.sb / ifconfig.me, -4)。
#
# 接口流程 (2026-08 实测逆向, 纯 POSIX sh + curl, 无需 JS):
#   1. GET  /IP:PORT              → 响应内嵌 antiflood=<hex> cookie, 提取后须携带
#   2. GET  /IP:PORT?browsercheck=ok -b cookie -L → 页面内嵌 taskStartQuery/taskStartToken
#   3. POST ajax_startTask_v1.php (query + start_token, 须带 Origin 头, 否则 Invalid origin)
#        → {"data":{"stream_id":..., "pinger_count":167}}
#   4. 轮询 GET ajax_getPingResults_v2.php?type=tcp&totalPolls=N&stream_id=ID
#      (每轮只返回【增量】, 需拼接累积), 直到 "outstandingNodeCount":0
# 结果语义 (实测验证): "result":1 = 连接失败 (1.1.1.1:443 大陆 13 点全 1 = 确系大陆被墙;
#                      关闭端口全球全 1); "result":V>1 = 成功, V/100 ≈ 毫秒
#                      (baidu.com:443 大陆点 15.8~30.2ms)。
#
# 限制:
#   · 只测 TCP —— NODE_PORT 仅监听 UDP (Hysteria2 直听) 时跳过: TCP/UDP 是两个独立
#     命名空间, 纯 UDP 端口 tcping 全失败属正常, 不能判被墙 (同 NW9 的协议感知注意)。
#   · 依赖 tcp.ping.pe 可达 (大陆探测点由其代测, 节点本机只与其 HTTPS 通信);
#     服务不可达/繁忙时 WARN 跳过, 绝不误报。
#   · 耗时: 单轮 ~15-60s, 触发交叉验证时翻倍 (~2min)。
#
# 远程用法 (在第三方服务器上测【别的】节点, 无需登录目标机):
#   NODE_TARGET_IP=1.2.3.4 NODE_PORT=443 ./proxyDiagnose.sh --target net
#   · 核心被墙判定 (三网+云厂+海外对照) 完全可用 — 测量由 ping.pe 探测点完成,
#     与脚本运行位置无关; NODE_TARGET_IP 优先级最高, 不被 ~/.env/node.json 覆盖
#     (否则第三方服务器若自身也是节点, 会误测成它自己)。
#   · 远程目标自动降级: 跳过本机监听前置检查与 NW9 (ss 只能看本机端口)、跳过随机
#     端口交叉验证 (临时监听必须开在目标机上, 远程开了测的也是目标机的未开端口)。
#   · 需要完整诊断 (含交叉验证) 用 --host root@1.2.3.4 把脚本推到节点上执行。
# ============================================================

# ---- ping.pe 探测封装 (供主测/交叉验证复用) ----
# _pe_probe <目标 IP:PORT> <标签> — 跑一轮完整的 tcp.ping.pe 全球 tcping (含大陆分网)
#   成功 → 全局 _peR_t/_peR_cnok/_peR_cnfail/_peR_ok/_peR_fail/_peR_avg +
#          _peR_car (逐网三段串 "标签 状态 ok/total"), return 0
#   失败 → 已 emit WARN (标题含 <标签>), return 1, 调用方直接放弃本轮判定
_pe_probe() {
    _pp_tgt="$1"; _pp_lbl="${2:-}"
    _pe_ua="Mozilla/5.0 (X11; Linux x86_64) NodeHub-proxyDiagnose"
    _pe_b="https://tcp.ping.pe"

    # 1) antiflood cookie: 首访响应内嵌 document.cookie 赋值, 提取后携带重访
    _pe_page=$(curl -sS --connect-timeout 8 --max-time 20 -A "$_pe_ua" "${_pe_b}/${_pp_tgt}" 2>/dev/null)
    _pe_af=$(printf '%s' "$_pe_page" | grep -oE 'antiflood=[a-f0-9]+' | head -1 | cut -d= -f2)
    if [ -z "$_pe_af" ]; then
        result WARN "CN_TCPING_SERVICE_DOWN" "tcp.ping.pe 不可达, 跳过${_pp_lbl} ${_pp_tgt} 检测" \
            "本检查依赖其大陆探测点代测; 服务恢复后重跑, 或人工在 https://tcp.ping.pe/${_pp_tgt} 复核"
        return 1
    fi
    sleep 2
    _pe_page=$(curl -sS -L --connect-timeout 8 --max-time 40 -A "$_pe_ua" -b "antiflood=$_pe_af" \
        "${_pe_b}/${_pp_tgt}?browsercheck=ok" 2>/dev/null)
    _pe_tok=$(printf '%s' "$_pe_page" | grep -oE 'var taskStartToken = "[^"]*"' | head -1 | sed 's/^.*"\(.*\)"$/\1/')
    _pe_qry=$(printf '%s' "$_pe_page" | grep -oE 'var taskStartQuery = "[^"]*"' | head -1 | sed 's/^.*"\(.*\)"$/\1/')
    if [ -z "$_pe_tok" ] || [ -z "$_pe_qry" ]; then
        result WARN "CN_TCPING_SERVICE_CHANGE" "tcp.ping.pe 页面无任务令牌 (接口疑似变更), 跳过${_pp_lbl}检测" \
            "人工在 https://tcp.ping.pe/${_pp_tgt} 复核大陆节点连通性"
        return 1
    fi

    # 2) 启动探测任务 (须带 Origin 头, 否则 {"ok":false,"error":"Invalid origin"})
    _pe_start=$(curl -sS --connect-timeout 8 --max-time 20 -A "$_pe_ua" -b "antiflood=$_pe_af" \
        -H "X-Requested-With: XMLHttpRequest" -H "Origin: ${_pe_b}" -e "${_pe_b}/${_pp_tgt}" \
        --data-urlencode "query=$_pe_qry" --data-urlencode "start_token=$_pe_tok" \
        "${_pe_b}/ajax_startTask_v1.php" 2>/dev/null)
    _pe_sid=$(printf '%s' "$_pe_start" | grep -oE '"stream_id":"?[0-9]+' | grep -oE '[0-9]+$')
    if [ -z "$_pe_sid" ]; then
        case "$_pe_start" in
            *too_many*)
                result WARN "CN_TCPING_SERVICE_BUSY" "tcp.ping.pe 并发任务已满, 跳过${_pp_lbl}检测" \
                    "检测服务繁忙, 稍后重跑 ./proxyDiagnose.sh --target net" ;;
            *)
                result WARN "CN_TCPING_SERVICE_ERROR" "tcp.ping.pe 任务启动失败, 跳过${_pp_lbl}检测: $(printf '%s' "$_pe_start" | head -c 120)" \
                    "人工在 https://tcp.ping.pe/${_pp_tgt} 复核" ;;
        esac
        return 1
    fi

    # 3) 轮询增量结果拼接累积; "outstandingNodeCount":0 = 全部探测点已回报, 提前收工
    _pe_all=""
    _pe_i=0
    while [ "$_pe_i" -lt 12 ]; do
        sleep 4
        _pe_r=$(curl -sS --connect-timeout 8 --max-time 25 -A "$_pe_ua" -b "antiflood=$_pe_af" \
            -e "${_pe_b}/${_pp_tgt}" \
            "${_pe_b}/ajax_getPingResults_v2.php?type=tcp&totalPolls=$((_pe_i + 1))&stream_id=$_pe_sid" 2>/dev/null)
        _pe_all="${_pe_all}
$_pe_r"
        case "$_pe_r" in
            *'"outstandingNodeCount":0'*) break ;;
        esac
        [ -z "$_pe_r" ] && [ "$_pe_i" -ge 2 ] && break   # 连续空响应及早止损
        _pe_i=$((_pe_i + 1))
    done

    # 4) 解析汇总: {"node_id":"CN_5","timestamp_ms":N,"result":V,"result_text":""}
    #    V=1 失败 / V>1 成功 (V/100≈ms); CN_ 前缀 = 大陆探测点, 其余作海外对照。
    #    大陆点按运营商细分 — node→provider 映射取自探测页 <tr> 的 data-provider 属性
    #    (电信 China Telecom / 移动 China Mobile / 联通 China Unicom; 腾讯云·阿里云等归云厂)。
    #    awk 输出双行: 第1行 = 总量 (总数 大陆ok 大陆fail 海外ok 海外fail 大陆平均ms);
    #                  第2行 = 逐网状态, 每类三段 "标签 状态 ok/total"
    #                  (顺序: 移动 电信 联通 云厂 海外; 状态 ∈ 通/部分/断, 断=0/N 全挂)
    _pe_prov=$(printf '%s' "$_pe_page" \
        | grep -oE "data-pinger-id='CN_[0-9]+'[^>]*data-provider='[^']*'" \
        | sed -E "s/^data-pinger-id='(CN_[0-9]+)'.*data-provider='([^']*)'.*$/\1 \2/")
    _pe_out=$({ printf '%s\n' "$_pe_prov" | sed 's/^/P /'
        printf '%s\n' "$_pe_all" \
            | grep -oE '"node_id":"[A-Za-z0-9_]+","timestamp_ms":[0-9]+,"result":-?[0-9]+' \
            | sed -E 's/^"node_id":"([^"]*)","timestamp_ms":[0-9]+,"result":(-?[0-9]+)$/\1 \2/'
        } | awk '
            function tag(p) {
                if (p ~ /Telecom/) return "CT"
                if (p ~ /Mobile/)  return "CM"
                if (p ~ /Unicom/)  return "CU"
                return "CLD"
            }
            function emit(lbl, o, n,   st) {
                if (n <= 0) return
                st = "断"; if (o == n) st = "通"; else if (o > 0) st = "部分"
                s = s " " lbl " " st " " o "/" n
            }
            $1 == "P" { p = $0; sub(/^P [^ ]+ /, "", p); m[$2] = tag(p); next }
            {
                v = $2 + 0; t++
                if ($1 ~ /^CN_/) {
                    if (v > 1) { cnok++; cns += v; cok[m[$1]]++ } else { cnfail++; cfa[m[$1]]++ }
                } else {
                    if (v > 1) ok++; else fail++
                }
            }
            END {
                printf "%d %d %d %d %d %d\n", t, cnok, cnfail, ok, fail, (cnok ? int(cns / cnok / 100 + 0.5) : 0)
                s = ""
                emit("移动", cok["CM"] + 0, cok["CM"] + cfa["CM"])
                emit("电信", cok["CT"] + 0, cok["CT"] + cfa["CT"])
                emit("联通", cok["CU"] + 0, cok["CU"] + cfa["CU"])
                emit("云厂", cok["CLD"] + 0, cok["CLD"] + cfa["CLD"])
                emit("海外", ok + 0, ok + fail)
                print substr(s, 2)
            }')
    # shellcheck disable=SC2046,SC2086  # 故意分词: awk 的 6 个汇总值赋给位置参数
    set -- $(printf '%s\n' "$_pe_out" | sed -n 1p)
    [ $# -ge 6 ] || set -- 0 0 0 0 0 0
    _peR_t=$(_num "$1" 0);    _peR_cnok=$(_num "$2" 0);  _peR_cnfail=$(_num "$3" 0)
    _peR_ok=$(_num "$4" 0);   _peR_fail=$(_num "$5" 0);  _peR_avg=$(_num "$6" 0)
    _peR_car=$(printf '%s\n' "$_pe_out" | sed -n 2p)
    return 0
}

# _pe_render <逐网三段串> — 生成全局 _pe_car_s (紧凑串, 进标题/JSON) 与 _pe_tbl (逐网明细表行)
_pe_render() {
    _pe_car_s=""; _pe_tbl=""
    # shellcheck disable=SC2086  # 故意分词: 逐组 (三段一组) 读取分网状态
    set -- $1
    while [ $# -ge 3 ]; do
        _pe_car_s="${_pe_car_s:+${_pe_car_s} }${1}:${2}(${3})"
        case "$2" in
            断)   _sc="$_C_RED" ;;
            部分) _sc="$_C_YELLOW" ;;
            *)    _sc="$_C_GREEN" ;;
        esac
        _pe_tbl="${_pe_tbl}    │   ${1}  ${_sc}${2}${_C_RESET}  ${3}
"
        shift 3
    done
}

# _pe_dead_nets <紧凑串> — 输出状态为"断"的大陆网络名单 (空格分隔; 海外为对照不计入)
_pe_dead_nets() {
    [ -n "$1" ] || return 0
    # shellcheck disable=SC2086  # 故意分词: 逐 token 过滤 :断( 项
    printf '%s\n' $1 | grep ':断(' | grep -v '^海外:' | cut -d: -f1 | tr '\n' ' ' | sed 's/ *$//'
}

_check_node_port_cn_tcping() {
    [ "${NODE_CN_TCPING:-1}" = "0" ] && return 0
    _resolve_node_port
    has curl || { result WARN "CN_TCPING_NO_CURL" "无 curl, 跳过大陆 tcping 被墙检测"; return 0; }

    # 目标 IP: NODE_TARGET_IP (在第三方服务器上测别的节点; 最高优先, 不被 ~/.env 覆盖)
#   > 已 source 的 node_ip > ~/node.json .node_ip > 公网探测 (探测的是运行机自己的 IP)
    _pe_from_detect=0
    _pe_host="${NODE_TARGET_IP:-${node_ip:-}}"
    if [ -z "$_pe_host" ] && [ -f "$HOME/node.json" ] && has jq; then
        _pe_host=$(jq -r '.node_ip // empty' "$HOME/node.json" 2>/dev/null)
    fi
    if [ -z "$_pe_host" ]; then
        _pe_host=$(curl -4 -sS --connect-timeout 6 --max-time 10 https://api.ip.sb 2>/dev/null | tr -d '\n\r ')
        [ -z "$_pe_host" ] && _pe_host=$(curl -4 -sS --connect-timeout 6 --max-time 10 https://ifconfig.me 2>/dev/null | tr -d '\n\r ')
        [ -n "$_pe_host" ] && _pe_from_detect=1
    fi
    if [ -z "$_pe_host" ]; then
        result WARN "CN_TCPING_NO_IP" "无法确定目标公网 IP, 跳过 NODE_PORT=$_NODE_PORT 大陆 tcping 被墙检测" \
            "未配 node_ip 且公网探测 (api.ip.sb/ifconfig.me) 失败; 测远程节点用 NODE_TARGET_IP=<目标IP> NODE_PORT=<端口>"
        return 0
    fi

    # 目标是否本机: 决定监听类检查 (ss 前置 / 交叉验证临时端口) 是否适用。
#   本机 = 目标 IP 在本机网卡上, 或目标来自公网探测 (探测的就是运行机自己);
#   第三方服务器上测别的节点 → 非本机 → 跳过一切"开监听/ss"类步骤, 纯借 ping.pe 远测。
    _pe_islocal=0
    _pe_ips=" $(hostname -I 2>/dev/null) "
    # 取不到本机 IP 列表 → 保守视为本机 (保持旧行为); tr 判空保持 POSIX 可移植
    [ -z "$(printf '%s' "$_pe_ips" | tr -d ' ')" ] && _pe_islocal=1
    case "$_pe_ips" in *" $_pe_host "*) _pe_islocal=1 ;; esac
    [ "$_pe_from_detect" = 1 ] && _pe_islocal=1

    # 前置 (仅本机目标): NODE_PORT 必须有 TCP 监听 (纯 UDP 端口 tcping 无意义, 见上方限制);
#   远程目标无法 ss → 不微此检查, 端口实际未开时海外探测点也会失败 → PORT_UNREACHABLE 兜底
    # 端口锚定 ([^0-9]|$): 避免 :443 误匹 :4430 / IPv6 地址段 (与 NW9 同款)
    if [ "$_pe_islocal" = 1 ] && ! ss -H -tlnp 2>/dev/null | grep -qE "[:.]$_NODE_PORT([^0-9]|$)"; then
        result WARN "CN_TCPING_UDP_ONLY" "NODE_PORT=$_NODE_PORT 无 TCP 监听 (疑似纯 UDP: Hysteria2 直听), 跳过大陆 tcping 被墙检测" \
            "tcping 只能测 TCP; UDP 端口的封锁需用户侧实测/抓包判断 (probeTask.sh 采集方向)"
        return 0
    fi

    # ping.pe 目标格式: IPv6 需方括号包裹
    case "$_pe_host" in
        *:*) _pe_tgt="[${_pe_host}]:${_NODE_PORT}" ;;
        *)   _pe_tgt="${_pe_host}:${_NODE_PORT}" ;;
    esac
    # 主测: 原端口一轮完整探测 (流程封装于 _pe_probe, 供下方交叉验证复用)
    if ! _pe_probe "$_pe_tgt" "原端口"; then return 0; fi
    _pe_t=$_peR_t; _pe_cnok=$_peR_cnok; _pe_cnfail=$_peR_cnfail
    _pe_ok=$_peR_ok; _pe_fail=$_peR_fail; _pe_avg=$_peR_avg
    _pe_cnt=$((_pe_cnok + _pe_cnfail))
    _pe_ost=$((_pe_ok + _pe_fail))
    # 分网渲染 + 主测全断网名单 (供判定展示与交叉验证对照)
    _pe_render "$_peR_car"
    _pe_dead_main=$(_pe_dead_nets "$_pe_car_s")

    # 5) 判定 — 逐网展示阻断状态 (移动/电信/联通/云厂/海外 各自: 通/部分/断), 不笼统汇总
    #    (_pe_car_s 紧凑串 / _pe_tbl 明细表 已由 _pe_render 生成)
    if [ "$_pe_t" -eq 0 ]; then
        result WARN "CN_TCPING_PARSE_EMPTY" "tcp.ping.pe 未返回任何探测结果, 跳过被墙判定" \
            "人工在 https://tcp.ping.pe/${_pe_tgt} 复核"
        return 0
    fi
    if [ "$_pe_cnt" -eq 0 ]; then
        result WARN "CN_TCPING_NO_CN_NODE" "tcp.ping.pe 本次无大陆探测点回报 (全球共 ${_pe_t} 点), 无法判定被墙" \
            "大陆探测点可能临时下线, 稍后重跑; 人工在 https://tcp.ping.pe/${_pe_tgt} 复核"
        return 0
    fi

    # 分网状态串/明细表 已由 _pe_render 生成 (_pe_car_s / _pe_tbl)

    if [ "$_pe_ost" -gt 0 ] && [ "$_pe_ok" -eq 0 ]; then
        # 全球全失败 → 端口本身不可达 (非大陆方向问题), 不误报被墙, 交给 NW9
        _pe_lvl=WARN; _pe_code=CN_TCPING_PORT_UNREACHABLE
        _pe_title="${_pe_tgt} 端口本身不可达: 全球 ${_pe_t} 个探测点全部失败"
        _pe_detail="全球 (含海外) 全断不是被墙的特征 → 先看 NW9 NODE_PORT_NOT_LISTENING / 云安全组 / 本机防火墙"
    elif [ "$_pe_cnok" -eq 0 ]; then
        _pe_lvl=FAIL; _pe_code=NODE_PORT_CN_BLOCKED
        _pe_title="NODE_PORT=${_NODE_PORT} 疑似被墙: 三网+云厂全断 (大陆 ${_pe_cnfail}/${_pe_cnt}), 海外 ${_pe_ok}/${_pe_ost} 正常"
        _pe_detail="本机监听/证书/海外访问全正常, 唯独大陆不通 = 典型 IP/端口被墙特征。处置: ① https://tcp.ping.pe/${_pe_tgt} 多时段人工复核 ② 换端口 (重跑 proxyInstall.sh) ③ 套 CDN/中转 ④ 联系机房换 IP"
    elif [ "$_pe_cnfail" -gt 0 ]; then
        _pe_lvl=WARN; _pe_code=NODE_PORT_CN_PARTIAL
        # 全断网名单 (_pe_dead_main, 空格分隔) → 斜杠串用于标题
        _pe_dead=$(printf '%s' "$_pe_dead_main" | tr ' ' '/')
        if [ -n "$_pe_dead" ]; then
            _pe_title="NODE_PORT=${_NODE_PORT} 部分被墙: ${_pe_dead} 全断, 其余网可达 (大陆 ${_pe_cnok}/${_pe_cnt} 通, 平均 ${_pe_avg}ms)"
            _pe_detail="疑似【单网被墙/干扰】(仅 ${_pe_dead} 断, 其余网正常): 受影响用户换接入网/套 CDN 可绕, 无需整机换 IP; 持续恶化会演变为三网全断 (NODE_PORT_CN_BLOCKED)"
        else
            _pe_title="NODE_PORT=${_NODE_PORT} 部分线路抖动: 各网均有通有断 (大陆 ${_pe_cnok}/${_pe_cnt} 通, 平均 ${_pe_avg}ms)"
            _pe_detail="无整网全断, 多为部分探测点/线路抖动丢包而非封锁; 用户单线路不通可复测确认"
        fi
    else
        _pe_lvl=PASS; _pe_code=NODE_PORT_CN_OK
        _pe_title="NODE_PORT=${_NODE_PORT} 未被墙: 三网+云厂全通 (大陆 ${_pe_cnt}/${_pe_cnt}, 平均 ${_pe_avg}ms)"
        _pe_detail="大陆方向未被墙; 海外为对照 (海外正常 + 大陆全断 = 被墙特征)"
    fi

    # 输出: 逐网明细表 (文本模式; PASS 且 --quiet 时随结论一并静默) + 结论行
    if [ "$JSON_OUTPUT" != 1 ]; then
        if [ "$QUIET" != 1 ] || [ "$_pe_lvl" != PASS ]; then
            printf '%b    ┌─ NODE_PORT=%s 分网 tcping 阻断明细 (状态 成功/总数)%b\n' "$_C_DIM" "$_NODE_PORT" "$_C_RESET"
            printf '%b' "$_pe_tbl"
            printf '%b    └─ 海外为对照: 海外通 + 大陆断 = 被墙特征%b\n' "$_C_DIM" "$_C_RESET"
        fi
    fi
    [ -n "$_pe_car_s" ] && _pe_title="${_pe_title} [${_pe_car_s}]"
    result "$_pe_lvl" "$_pe_code" "$_pe_title" "$_pe_detail"

    # 6) 交叉验证 — 随机开临时新端口再测一轮, 区分【端口被墙】vs【IP 整段被墙】
    #    仅在主测判出封锁时执行: BLOCKED, 或 PARTIAL 且有整网全断 (_pe_dead_main 非空)。
    #    临时端口可能被本机防火墙/云安全组拦截 (默认只放行业务端口) → 全球全断时判
    #    "无法判定"绝不误报 IP 被墙; 大陆断+海外通 才是封锁特征 (与主测同款海外对照)。
    [ "${NODE_CN_TCPING_XCHECK:-1}" = "0" ] && return 0
    # 远程目标 (第三方服务器上测别的节点): 临时监听会开在【运行机】而非目标机, 测了也是
    # 目标机的未开端口 → 无意义, 跳过; 需完整交叉验证用 --host 在节点本机跑
    if [ "$_pe_islocal" != 1 ]; then
        if [ "$JSON_OUTPUT" != 1 ]; then
            printf '%b    └ 远程目标模式: 跳过随机端口交叉验证 (临时监听需开在目标机; 完整验证用 --host %s 在节点上跑)%b\n' \
                "$_C_DIM" "${NODE_TARGET_IP:-$_pe_host}" "$_C_RESET"
        fi
        return 0
    fi
    case "$_pe_code" in
        NODE_PORT_CN_BLOCKED) ;;
        NODE_PORT_CN_PARTIAL) [ -n "$_pe_dead_main" ] || return 0 ;;
        *) return 0 ;;
    esac

    # 选随机临时端口 (20000-60000): 避开 NODE_PORT 与当前已监听端口
    _xc_port=$(( ($(date +%s) % 40000) + 20000 ))
    _xc_try=0
    while [ "$_xc_try" -lt 20 ]; do
        if [ "$_xc_port" != "$_NODE_PORT" ] \
           && ! ss -H -tln 2>/dev/null | grep -qE "[:.]${_xc_port}([^0-9]|$)"; then
            break
        fi
        _xc_port=$((_xc_port + 1)); [ "$_xc_port" -gt 60000 ] && _xc_port=20000
        _xc_try=$((_xc_try + 1))
    done

    # 起临时监听: python3 优先 (节点标配, probeTask.sh 同依赖), socat 退路; timeout 240s 兜底自灭
    _xc_pid=""
    if has python3; then
        timeout 240 python3 -c "
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', ${_xc_port}))
s.listen(16)
while True:
    c, _ = s.accept()
    c.close()
" >/dev/null 2>&1 &
        _xc_pid=$!
    elif has socat; then
        timeout 240 socat TCP-LISTEN:${_xc_port},reuseaddr,fork OPEN:/dev/null >/dev/null 2>&1 &
        _xc_pid=$!
    else
        result WARN "CN_XCHECK_NO_LISTENER" "无 python3/socat, 无法开临时端口, 跳过端口级/IP级交叉验证" \
            "人工验证: 临时开一端口 (python3 -m http.server 20086) 后 https://tcp.ping.pe/<IP>:20086 看大陆可达性"
        return 0
    fi

    # 等监听就绪 (最多 ~2s); 未起来则收尾跳过
    _xc_up=0; _xc_w=0
    while [ "$_xc_w" -lt 5 ]; do
        if ss -H -tln 2>/dev/null | grep -qE "[:.]${_xc_port}([^0-9]|$)"; then _xc_up=1; break; fi
        sleep 0.4; _xc_w=$((_xc_w + 1))
    done
    if [ "$_xc_up" != 1 ]; then
        kill "$_xc_pid" 2>/dev/null; wait "$_xc_pid" 2>/dev/null
        result WARN "CN_XCHECK_LISTEN_FAIL" "临时端口 ${_xc_port} 监听启动失败, 跳过交叉验证" \
            "可能端口被占/权限不足; 重跑或人工验证"
        return 0
    fi

    # 第二轮探测 (与主测同流程, 间隔 4s 避免限流); 探完先收监听再判定
    sleep 4
    case "$_pe_host" in
        *:*) _xc_tgt="[${_pe_host}]:${_xc_port}" ;;
        *)   _xc_tgt="${_pe_host}:${_xc_port}" ;;
    esac
    _pe_probe "$_xc_tgt" "验证新端口"
    _xc_rc=$?
    kill "$_xc_pid" 2>/dev/null; wait "$_xc_pid" 2>/dev/null
    [ "$_xc_rc" = 0 ] || return 0    # 探测服务异常已 WARN, 跳过判定

    _pe_render "$_peR_car"
    _xc_dead_new=$(_pe_dead_nets "$_pe_car_s")
    _xc_sum="交叉验证新端口 ${_xc_port} 分网: [${_pe_car_s:-无数据}]"

    # 无有效数据 / 新端口全球全断 → 无法判定 (防火墙/安全组拦临时端口, 不误报)
    if [ "$_peR_t" -eq 0 ] || [ $((_peR_cnok + _peR_cnfail)) -eq 0 ] \
       || { [ "$_peR_ok" -eq 0 ] && [ "$_peR_fail" -gt 0 ]; }; then
        _xc_lvl=WARN; _xc_code=CN_XCHECK_INCONCLUSIVE
        _xc_title="交叉验证无法判定: 新端口 ${_xc_port} 全球 ${_peR_fail}/${_peR_t} 全部失败 → 疑似本机防火墙/云安全组未放行临时端口"
        _xc_detail="云安全组默认只放行业务端口, 临时端口全球不通属预期, 不能据此判 IP 被墙。想精确验证: 控制台临时放行 ${_xc_port}/tcp 后重跑, 或人工 https://tcp.ping.pe/${_xc_tgt} 复核"
    else
        # 逐网对照: 主测全断的网 (_pe_dead_main) 在新端口的表现 → 恢复 / 仍断
        _xc_still=""; _xc_rec=""
        for _n in $_pe_dead_main; do
            case " $_xc_dead_new " in
                *" $_n "*) _xc_still="${_xc_still:+${_xc_still} }$_n" ;;
                *)         _xc_rec="${_xc_rec:+${_xc_rec} }$_n" ;;
            esac
        done
        if [ -n "$_xc_rec" ] && [ -z "$_xc_still" ]; then
            _xc_lvl=PASS; _xc_code=NODE_PORT_CN_XCHECK_PORT
            _xc_title="交叉验证: 属【端口级被墙】— 新端口 ${_xc_port} 大陆可达 (原全断的 ${_xc_rec} 均恢复) → 仅 NODE_PORT=${_NODE_PORT} 被封, IP 未整段被墙"
            _xc_detail="换端口即可恢复: 面板改配/重跑 proxyInstall.sh 换 node_port, 无需换 IP。${_xc_sum}"
        elif [ -n "$_xc_still" ] && [ -z "$_xc_rec" ]; then
            if [ "$_peR_cnok" -eq 0 ]; then
                _xc_lvl=FAIL; _xc_code=NODE_PORT_CN_IP_BLOCKED
                _xc_title="交叉验证: 属【IP 级被墙】— 新端口 ${_xc_port} 大陆亦全断 (${_xc_still}), 而海外 ${_peR_ok}/${_peR_fail} 正常 → 整个 IP 的大陆方向被封"
                _xc_detail="换端口无效。处置: ① 套 CDN/中转 ② 联系机房换 IP ③ 多时段人工复核 https://tcp.ping.pe/${_xc_tgt}。${_xc_sum}"
            else
                _xc_lvl=WARN; _xc_code=NODE_PORT_CN_XCHECK_IP
                _xc_title="交叉验证: ${_xc_still} 对新旧端口均全断 → 该网封锁针对整个 IP (网级), 其余网正常"
                _xc_detail="受影响网用户需 CDN/中转或换 IP; 其余网不受影响。${_xc_sum}"
            fi
        elif [ -n "$_xc_still" ]; then
            _xc_lvl=WARN; _xc_code=NODE_PORT_CN_XCHECK_MIXED
            _xc_title="交叉验证: 混合封锁 — ${_xc_still} 新端口仍全断 (IP级/网级), ${_xc_rec} 新端口恢复 (端口级)"
            _xc_detail="部分网仅封原端口 (换端口可救), 部分网封整个 IP (需 CDN/中转或换 IP)。${_xc_sum}"
        else
            _xc_lvl=WARN; _xc_code=CN_XCHECK_INCONCLUSIVE
            _xc_title="交叉验证结果异常 (主测全断网在新端口无对照数据), 无法判定端口级/IP级"
            _xc_detail="人工在 https://tcp.ping.pe/${_xc_tgt} 复核"
        fi
    fi

    # 新端口明细表 (文本模式; PASS 且 --quiet 时随结论静默) + 结论行
    if [ "$JSON_OUTPUT" != 1 ]; then
        if [ "$QUIET" != 1 ] || [ "$_xc_lvl" != PASS ]; then
            printf '%b    ┌─ 交叉验证: 随机新端口 %s 分网 tcping 明细 (状态 成功/总数)%b\n' "$_C_DIM" "$_xc_port" "$_C_RESET"
            printf '%b' "$_pe_tbl"
            printf '%b    └─ 对照上表: 新端口通 → 端口级封锁 (换端口可救); 新端口大陆也断 → IP 级封锁%b\n' "$_C_DIM" "$_C_RESET"
        fi
    fi
    result "$_xc_lvl" "$_xc_code" "$_xc_title" "$_xc_detail"
}

# ============================================================
# 出站连通性 (outbound) — 本次 (2026-08-05, 38.45.72.223) 核心经验
#
# 真实故障: 代理"完全无法使用", 但常规检查【全部 PASS】:
#   服务 active / 端口 443 监听 / 客户端能完成 TLS 握手 + VLESS 认证(日志 accepted) /
#   证书有效 / nginx·MySQL·geoip 全正常 / ping·traceroute(ICMP)·curl(默认IPv6)·DNS(53) 全正常
#
# 根因: 服务器【出站 IPv4 TCP 的 80/443】被上游/运营商精准封锁 (IPv6·ICMP·DNS:53 全正常 →
#   极度隐蔽, 常规巡检全部漏报), 而 xray freedom 出站 domainStrategy=UseIPv4v6【强制优先 IPv4】→
#   所有网页拨号超时 (i/o timeout) → 代理 accept 连接但无法回传任何数据。
#
# 教训: "端口在监听 + TLS 握手成功" ≠ "代理可用"。真正可用 = 端到端数据转发。
#   必须主动测【出站 IPv4 web 端口】, 且 curl 必须加 -4 强制 IPv4
#   (否则 Happy Eyeballs 自动走 IPv6, 把故障完全掩盖 —— 这正是本次被忽略的原因)。
# ============================================================
check_outbound() {
    say "出站连通性 (IPv4/IPv6 web 端口 + freedom domainStrategy)"

    has curl || { result WARN "OUTBOUND_NO_CURL" "无 curl, 跳过出站连通性测试"; return 0; }

    # OB1. IPv4 出站 web(443) — 必须 -4 强制, 否则 curl 走 IPv6 掩盖故障
    #   1.1.1.1 anycast 极稳定; connect-timeout 测纯 TCP 连通, http_code=000 = 连不上
    _v4=$(curl -4 -k --connect-timeout 6 --max-time 10 -s -o /dev/null -w '%{http_code}' https://1.1.1.1 2>/dev/null)
    _v4=${_v4:-000}
    # OB2. IPv6 出站 web(443)
    _v6=$(curl -6 -k --connect-timeout 6 --max-time 10 -s -o /dev/null -w '%{http_code}' "https://[2606:4700:4700::1111]" 2>/dev/null)
    _v6=${_v6:-000}

    # 读 freedom 出站 domainStrategy
    _ds=""
    if [ -f "$_XRAY_CONF" ] && has jq; then
        _ds=$(jq -r '.outbounds[]? | select(.protocol=="freedom") | .settings.domainStrategy // empty' "$_XRAY_CONF" 2>/dev/null | head -1)
    fi

    [ "$_v4" != "000" ] && result PASS "OUTBOUND_V4_OK" "IPv4 出站 web(443) 可达 (http_code=$_v4)"
    [ "$_v6" != "000" ] && result PASS "OUTBOUND_V6_OK" "IPv6 出站 web(443) 可达 (http_code=$_v6)"

    # 核心判定
    if [ "$_v4" = "000" ] && [ "$_v6" != "000" ]; then
        # IPv4 web 被封但 IPv6 正常 (本次精确症状)
        case "$_ds" in
            UseIPv4|UseIPv4v6)
                result FAIL "OUTBOUND_V4_BLOCKED_XRAY_FORCES_V4" \
                    "出站 IPv4 web(80/443) 被封锁, 但 freedom domainStrategy=$_ds 强制用 IPv4 → 代理无法转发任何数据" \
                    "现象: 服务/端口/TLS握手/认证全 PASS, 唯独客户端收不到响应数据; curl 默认走 IPv6 故巡检看似正常(极具迷惑性)。修复: domainStrategy 改 UseIPv6 (本次已验证可恢复), 并联系机房查 IPv4 出站 80/443 为何被封"
                ;;
            *)
                result WARN "OUTBOUND_V4_BLOCKED" \
                    "出站 IPv4 web(80/443) 被封锁, IPv6 正常 (domainStrategy=${_ds:-未知})" \
                    "若代理异常, 把 freedom domainStrategy 改 UseIPv6 可绕过; 联系机房查 IPv4 出站封禁"
                ;;
        esac
    elif [ "$_v4" = "000" ] && [ "$_v6" = "000" ]; then
        result FAIL "OUTBOUND_ALL_BLOCKED" "IPv4 与 IPv6 出站 web 端口均不通" \
            "代理完全无法转发数据。检查本机网络/上游路由/机房封禁/iptables OUTPUT"
    fi

    [ -n "$_ds" ] && result PASS "OUTBOUND_DS_READ" "freedom domainStrategy = $_ds"
}

# ============================================================
# 本周期流量 (traffic) — vnstat tx × ~/.env NODE_TRAFFIC_RESETDAY
#
# 定义: 从【上一个 NODE_TRAFFIC_RESETDAY】(含当天) 到今天的 tx 出站流量。
#   · NODE_TRAFFIC_RESETDAY = 每月流量重置日 (1-31), 读 ~/.env; 面板多次追加同名
#     行时取最后一行 (与 source 语义一致, 后写覆盖先写); 未配置/非法 → WARN 跳过。
#   · 周期起点: 今日日号 ≥ 重置日 → 本月重置日; 否则 → 上月重置日。
#     重置日 > 所在月天数时取该月末天 (如 31 遇 2 月 → 28/29), 纯算术不依赖 GNU date。
#   · 只累加【tx 出站】(rx 入站不计, 与面板计费口径一致), 多网卡求和;
#     数据源: vnstat --json d 每日库, 按日期 ≥ 周期起点过滤。
#   · 完整性: 每日库最早记录晚于周期起点 (被 DailyDays 滚动清理) → WARN 统计偏小;
#     vnstatd 超 1 天未刷新 → WARN 数据失真; 配 NODE_TRAFFIC_LIMIT (GB) 时做限额对比。
# ============================================================
check_traffic() {
    say "本周期流量 (vnstat tx, 自上一个 NODE_TRAFFIC_RESETDAY 起)"

    # T1. 前置依赖: vnstat + jq (解析 JSON 求和)
    if ! has vnstat; then
        result WARN "TRAFFIC_VNSTAT_MISSING" "未安装 vnstat, 无法统计本周期流量" \
            "安装: apt install -y vnstat && systemctl enable --now vnstat (运行一段时间后才有数据)"
        return 0
    fi
    if ! has jq; then
        result WARN "TRAFFIC_JQ_MISSING" "无 jq, 无法解析 vnstat JSON" "安装: apt install -y jq"
        return 0
    fi

    # T2. 解析 ~/.env 的 NODE_TRAFFIC_RESETDAY / NODE_TRAFFIC_LIMIT
    _env_read() {  # _env_read <key> → 输出 ~/.env 中该 key 最后一行的值 (面板会追加同名行)
        grep -E "^[[:space:]]*$1[[:space:]]*=" "$HOME/.env" 2>/dev/null | tail -1 \
            | sed -E "s/^[^=]*=//; s/[\"'[:space:]]//g"
    }
    _rd=$(_env_read NODE_TRAFFIC_RESETDAY)
    _rd=${_rd:-${NODE_TRAFFIC_RESETDAY:-}}
    _rd=$(printf '%s' "$_rd" | sed 's/^0*//'); [ -z "$_rd" ] && _rd=0   # 去前导零防八进制误判
    if [ "$_rd" -lt 1 ] || [ "$_rd" -gt 31 ]; then
        result WARN "TRAFFIC_RESETDAY_INVALID" \
            "~/.env 未配置有效的 NODE_TRAFFIC_RESETDAY (当前: '${NODE_TRAFFIC_RESETDAY:-未设置}', 需 1-31)" \
            "在 ~/.env 写入 NODE_TRAFFIC_RESETDAY=<1-31> (每月流量重置日) 后重跑"
        return 0
    fi

    # T3. 周期起点 = 上一个重置日 (纯整数运算, 免 GNU date)
    _y=$(date +%Y); _m=$(date +%m | sed 's/^0//'); _d=$(date +%d | sed 's/^0//')
    if [ "$_d" -lt "$_rd" ]; then
        _m=$((_m - 1))
        [ "$_m" -eq 0 ] && { _m=12; _y=$((_y - 1)); }
    fi
    _dim=$(awk -v m="$_m" -v y="$_y" 'BEGIN{d=31; if(m==4||m==6||m==9||m==11)d=30; else if(m==2)d=(y%4==0&&(y%100!=0||y%400==0))?29:28; print d}')
    _sd=$_rd; [ "$_sd" -gt "$_dim" ] && _sd=$_dim      # 重置日 31 遇 2 月 → 28/29
    _start_ymd=$(printf '%04d-%02d-%02d' "$_y" "$_m" "$_sd")
    _start_cn="${_m}月${_sd}号"                          # 上次重置日 (几月几号)

    # T4. vnstat 每日库求和: 只取 tx, 日期 ≥ 周期起点, 多网卡求和
    _vn=$(vnstat --json d 2>/dev/null)
    if [ -z "$_vn" ] || ! printf '%s' "$_vn" | jq -e '.interfaces' >/dev/null 2>&1; then
        result WARN "TRAFFIC_VNSTAT_NOJSON" "vnstat --json d 无有效输出" \
            "检查 vnstat 数据库 (ls /var/lib/vnstat/) 与服务: systemctl status vnstat"
        return 0
    fi
    _ymd='((.date.year|tostring) + "-" + (("0"+(.date.month|tostring))[-2:]) + "-" + (("0"+(.date.day|tostring))[-2:]))'
    _sum_tx=$(printf '%s' "$_vn" | jq -r --arg s "$_start_ymd" \
        "[.interfaces[]?.traffic.day[]? | select($_ymd >= \$s) | .tx] | add // 0")
    _sum_tx=$(_num "$_sum_tx" 0)
    _ifs=$(printf '%s' "$_vn" | jq -r '[.interfaces[]?.name] | join(",")')
    _min_day=$(printf '%s' "$_vn" | jq -r "[.interfaces[]?.traffic.day[]? | $_ymd] | min // empty")

    # T5. 可读化 + 周期天数/日均
    _gib=$(awk -v b="$_sum_tx" 'BEGIN{printf "%.2f", b/1073741824}')
    _gb=$(awk  -v b="$_sum_tx" 'BEGIN{printf "%.2f", b/1000000000}')
    _days=""
    _start_epoch=$(date -d "$_start_ymd" +%s 2>/dev/null)   # GNU date; 失败则不显示天数
    if [ -n "$_start_epoch" ]; then
        _days=$(( ( $(date +%s) - _start_epoch ) / 86400 ))
        [ "$_days" -lt 0 ] && _days=0
    fi

    # T6. 主结论: 本周期 tx 流量 (信息性 → PASS; 重置日几月几号必列)
    _t="本周期 tx 出站流量: ${_gib} GiB (上次重置日: ${_start_cn}, ${_start_ymd})"
    _x="只统计 tx 出站, rx 不计入; 周期 = 上一个 NODE_TRAFFIC_RESETDAY ($_rd 号) ${_start_ymd} (含当天) → 今天"
    [ -n "$_days" ] && _x="$_x, 已 $_days 天"
    if [ -n "$_days" ] && [ "$_days" -gt 0 ]; then
        _avg=$(awk -v b="$_sum_tx" -v d="$_days" 'BEGIN{printf "%.2f", b/1073741824/d}')
        _x="$_x, 日均 tx ${_avg} GiB"
    fi
    _x="$_x; vnstat 网卡[$_ifs], 原始值 $_sum_tx B"
    result PASS "TRAFFIC_TX_CYCLE" "$_t" "$_x"

    # T7. 覆盖完整性 — 每日库最早记录晚于周期起点 → 周期前段已滚动清理, 统计偏小
    if [ -n "$_min_day" ] && awk -v a="$_min_day" -v b="$_start_ymd" 'BEGIN{exit !(a > b)}'; then
        result WARN "TRAFFIC_DAILY_COVERAGE" \
            "vnstat 每日库最早仅到 ${_min_day}, 晚于周期起点 ${_start_ymd} → 上述 tx 偏小" \
            "vnstat 只保留最近若干天明细, 周期前段已被滚动清理。调大 /etc/vnstat.conf 的 DailyDays 后 systemctl restart vnstat (更早的历史已不可恢复)"
    fi

    # T8. 数据新鲜度 — vnstatd 超 1 天未写库 → 统计失真
    _upd=$(printf '%s' "$_vn" | jq -r '[.interfaces[]?.updated.timestamp] | max // empty')
    _upd=$(_num "$_upd" "")
    if [ -n "$_upd" ]; then
        _age=$(( $(date +%s) - _upd ))
        [ "$_age" -gt 86400 ] && result WARN "TRAFFIC_VNSTAT_STALE" \
            "vnstat 数据已 $((_age / 3600)) 小时未刷新 (最后: $(date -d "@$_upd" '+%F %T' 2>/dev/null || echo "$_upd"))" \
            "vnstatd 可能已停: systemctl status vnstat; systemctl restart vnstat"
    fi

    # T9. 限额对比 — ~/.env NODE_TRAFFIC_LIMIT (GB, 1000 进制); ≥80% 提醒, ≥100% 告警
    _lim=$(_env_read NODE_TRAFFIC_LIMIT)
    _lim=${_lim:-${NODE_TRAFFIC_LIMIT:-}}
    _lim=$(printf '%s' "$_lim" | sed 's/^0*//'); [ -z "$_lim" ] && _lim=0
    if [ "$_lim" -gt 0 ]; then
        _pct=$(awk -v b="$_sum_tx" -v l="$_lim" 'BEGIN{printf "%.1f", b/(l*1000000000)*100}')
        if awk -v b="$_sum_tx" -v l="$_lim" 'BEGIN{exit !(b >= l*1000000000)}'; then
            result WARN "TRAFFIC_LIMIT_EXCEEDED" \
                "本周期 tx ${_gb} GB 已达限额 NODE_TRAFFIC_LIMIT=${_lim} GB 的 ${_pct}%" \
                "超限节点可能被面板停机/额外计费; 控制用户量或升级套餐; 下次重置: 下月 ${_rd} 号"
        elif awk -v b="$_sum_tx" -v l="$_lim" 'BEGIN{exit !(b >= l*1000000000*0.8)}'; then
            result WARN "TRAFFIC_LIMIT_NEAR" "本周期 tx 已用限额 ${_pct}% (${_gb}/${_lim} GB)" \
                "用量超八成, 提前规划 (控制用户/升级套餐)"
        fi
    fi
}

# ============================================================
# TLS 证书专项 (cert) — 只检查【在用】证书, 不做全盘扫描:
#   1. ~/node.json 中 root_domain 对应的证书 (按 CN/SAN 匹配定位)
#   2. /etc/nginx 中 *.conf 声明 ssl_certificate 引用的证书
#   未被使用的散落证书 (如 /etc/ssl 里的历史遗留) 过期不影响服务, 不检查。
# ============================================================
check_cert() {
    say "TLS 证书专项 (root_domain + nginx .conf 引用证书)"

    # C1. ~/node.json 的 root_domain 对应证书
    _rd=""
    if [ -f "$HOME/node.json" ] && has jq; then
        _rd=$(jq -r '.root_domain // empty' "$HOME/node.json" 2>/dev/null)
    fi
    if [ -z "$_rd" ]; then
        result WARN "CERT_NO_ROOT_DOMAIN" "$HOME/node.json 无 root_domain, 跳过主域证书检查" \
            "确认 $HOME/node.json 是否存在且含 root_domain 字段; 或手动 openssl x509 -checkend 0 -noout -in <cert>"
    else
        _hit=0
        for _d in /etc/letsencrypt/live /root/.acme.sh /etc/nginx/ssl /etc/ssl /usr/local/etc/xray "$_XRAY_DIR"; do
            [ -d "$_d" ] || continue
            for _c in $(find "$_d" -maxdepth 3 -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) 2>/dev/null); do
                case "$_c" in /etc/ssl/certs/*) continue ;; esac   # CA 信任库, 非本站证书
                grep -q 'BEGIN CERTIFICATE' "$_c" 2>/dev/null || continue
                # CN / SAN 匹配 root_domain (含泛子域) 才是主域证书
                _id="$(openssl x509 -in "$_c" -noout -subject 2>/dev/null)"
                _id="$_id $(openssl x509 -in "$_c" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tr '\n' ' ')"
                case "$_id" in
                    *"CN=$_rd"*|*"CN = $_rd"*|*"DNS:$_rd"*|*"DNS:*.$_rd"*|*"CN=*.$_rd"*|*"CN = *.$_rd"*)
                        _hit=1
                        _check_cert_file "$_c" CERT_ROOT_DOMAIN ;;
                esac
            done
        done
        [ "$_hit" = 0 ] && result WARN "CERT_ROOT_DOMAIN_NOT_FOUND" "未找到 root_domain=$_rd 的本地证书" \
            "若证书在其它路径, 手动 openssl x509 -checkend 0 -noout -in <cert>; 若节点未用本地证书 (如 reality/自签) 可忽略"
    fi

    # C2. /etc/nginx *.conf 引用的证书 (与 N5 共用 _check_nginx_certs, 按路径去重)
    _check_nginx_certs
}

# ============================================================
# 汇总输出
# ============================================================
summary() {
    if [ "$JSON_OUTPUT" = 1 ]; then
        # 输出 JSON: { target, totals, results[] }
        printf '{"target":"%s","totals":{"pass":%d,"warn":%d,"fail":%d},"results":[' \
            "$TARGET" "$_PASS" "$_WARN" "$_FAIL"
        _first=1
        while IFS='	' read -r _l _c _t _d; do
            [ -n "$_l" ] || continue
            [ "$_first" = 1 ] || printf ','
            # JSON 字符串转义 (基本的 " 和 \)
            _t=$(printf '%s' "$_t" | sed 's/\\/\\\\/g; s/"/\\"/g')
            _d=$(printf '%s' "$_d" | sed 's/\\/\\\\/g; s/"/\\"/g')
            printf '{"level":"%s","code":"%s","title":"%s","detail":"%s"}' "$_l" "$_c" "$_t" "$_d"
            _first=0
        done < "$_RESULTS_FILE"
        printf ']}\n'
    else
        say "诊断汇总"
        printf '  通过 %b%d%b   警告 %b%d%b   失败 %b%d%b\n' \
            "$_C_GREEN" "$_PASS" "$_C_RESET" \
            "$_C_YELLOW" "$_WARN" "$_C_RESET" \
            "$_C_RED" "$_FAIL" "$_C_RESET"
        if [ "$_FAIL" -gt 0 ]; then
            printf '%b  → 有 %d 项故障, 优先处理 FAIL 项%b\n' "$_C_RED" "$_FAIL" "$_C_RESET"
        else
            printf '%b  → 未发现阻断性故障%b\n' "$_C_GREEN" "$_C_RESET"
        fi
    fi
}

# ============================================================
# 主流程 — 按目标分发
# ============================================================
Main() {
    _resolve_node_port
    case "$TARGET" in
        all)
            check_env
            check_xray
            check_nginx
            check_cert
            check_net
            check_outbound
            check_traffic
            ;;
        xray)     check_xray ;;
        nginx)    check_nginx ;;
        env)      check_env ;;
        net)      check_net ;;
        cert)     check_cert ;;
        outbound) check_outbound ;;
        traffic)  check_traffic ;;
        *) echo "未知 --target: $TARGET (可选: all|xray|nginx|env|net|cert|outbound|traffic)" >&2; exit 2 ;;
    esac

    summary
    _NotifyTG
}

# 注意: 故意不设 set -e — 诊断脚本必须每项独立, 一项失败绝不中断其它检查
Main
# 退出码 = 失败数 (上限 99), 便于上层脚本/监控判断
[ "$_FAIL" -gt 99 ] && exit 99
exit "$_FAIL"
