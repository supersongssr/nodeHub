#!/bin/sh
# ============================================================
# manage.sh — nodeHub 节点运维菜单 (手动控制 / 故障自检 / 基础功能)
#
# 用法:
#   交互模式:  sh manage.sh            (显示菜单)
#   非交互模式: sh manage.sh <子命令> [参数]
#
# 子命令:
#   unlock            重新测试流媒体解锁 (清缓存后重跑 unlockCheck.sh)
#   check             节点故障自检 (服务/端口/配置/证书/磁盘/网络)
#   status            查看节点状态摘要
#   restart <svc>     重启服务 (xray|nginx|stat|cron|all)
#   ssl               手动同步 SSL 证书并重载服务
#   logs <name>       查看日志 (agent|monitor|unlock|xray|nginx)
#   update            从 NODEHUB_URL 更新本地脚本
#   reinstall         重新运行 proxyInstall.sh
#   help              显示帮助
#
# 约定: 与项目其它脚本一致, 使用 POSIX /bin/sh, 颜色 + emoji 输出
# ============================================================

RUN_VERSION="v1.0.0-$(date '+%Y%m%d')"

# ============================================================
# 颜色 (ANSI) — 不可识别时自动降级为无色
# ============================================================
if [ -t 1 ]; then
    C_RESET='\033[0m';   C_BOLD='\033[1m'
    C_RED='\033[31m';    C_GREEN='\033[32m';  C_YELLOW='\033[33m'
    C_BLUE='\033[34m';   C_CYAN='\033[36m';   C_GRAY='\033[90m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''
    C_BLUE=''; C_CYAN=''; C_GRAY=''
fi

# ============================================================
# 输出工具
# ============================================================
_msg() { printf '%b\n' "$*"; }            # 原始输出 (含颜色码)

title()   { _msg "${C_BOLD}${C_CYAN}════════════════════════════════════════${C_RESET}${C_BOLD} ${*} ${C_CYAN}════════════════════════════════════════${C_RESET}"; }
section() { _msg "\n${C_BOLD}${C_BLUE}▶ ${*}${C_RESET}"; }
ok()      { _msg "  ${C_GREEN}✓${C_RESET} ${*}"; }
fail()    { _msg "  ${C_RED}✗${C_RESET} ${*}"; }
warn()    { _msg "  ${C_YELLOW}!${C_RESET} ${*}"; }
info()    { _msg "  ${C_GRAY}·${C_RESET} ${*}"; }
die()     { _msg "${C_RED}❌ ${*}${C_RESET}" >&2; exit 1; }

# 确认提示, $1=提示语, 默认拒绝
Confirm() {
    _prompt="$1"
    printf '%b' "${C_YELLOW}${_prompt} [y/N] ${C_RESET}"
    read -r _ans
    case "$_ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

Pause() {
    printf '\n%b' "${C_GRAY}按回车返回菜单...${C_RESET}"
    read -r _dummy
}

# 服务是否存在 (unit 文件), $1=服务名
SvcExists() {
    systemctl list-unit-files 2>/dev/null | grep -q "^$1\.service" && return 0
    [ -f "/etc/systemd/system/$1.service" ] && return 0
    [ -f "/lib/systemd/system/$1.service" ] && return 0
    return 1
}

# 服务是否 active, $1=服务名
SvcActive() {
    [ "$(systemctl is-active "$1" 2>/dev/null || true)" = "active" ]
}

# ============================================================
# 环境加载 — 尽力而为, 缺失不致命 (菜单/查看类操作仍可用)
# 产出变量: NODE_ID, ROOT_DOMAIN, NODEHUB_URL, API_URL, API_TOKEN,
#           NET_CARD, NODE_PORT, PANEL_DETECTED
# ============================================================
LoadEnv() {
    [ -f ~/.env ]      && . ~/.env 2>/dev/null || true
    [ -f ~/node.env ]  && . ~/node.env 2>/dev/null || true

    NODEHUB_URL="${NODEHUB_URL:-}"
    API_URL="${API_URL:-}"
    API_TOKEN="${API_TOKEN:-}"
    NODE_ID="${node_id:-${NODE_ID:-}}"
    NET_CARD="${net_card:-$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)}"
    PANEL_DETECTED="${panel_detected:-}"

    # URL 标准化加 https://
    case "$NODEHUB_URL" in http*) ;; *) [ -n "$NODEHUB_URL" ] && NODEHUB_URL="https://${NODEHUB_URL}" ;; esac
    case "$API_URL"      in http*) ;; *) [ -n "$API_URL" ]      && API_URL="https://${API_URL}" ;; esac

    # root_domain: ~/node.json > ~/node.env(root_domain) > 空
    ROOT_DOMAIN="${root_domain:-}"
    if [ -z "$ROOT_DOMAIN" ] && [ -f ~/node.json ] && command -v jq >/dev/null 2>&1; then
        ROOT_DOMAIN=$(jq -r '.root_domain // empty' ~/node.json 2>/dev/null || true)
    fi

    # node_port: ~/node.json > ~/node.env > 443
    NODE_PORT="${node_port:-443}"
    if [ -f ~/node.json ] && command -v jq >/dev/null 2>&1; then
        _jp=$(jq -r '.node_port // empty' ~/node.json 2>/dev/null || true)
        [ -n "$_jp" ] && NODE_PORT="$_jp"
    fi
}

# ============================================================
# 子命令 1: 重新测试流媒体解锁
# 清除 /tmp 下的检测缓存 → 重跑 unlockCheck.sh (强制刷新结果)
# ============================================================
Action_UnlockCheck() {
    title "🔓 流媒体解锁检测"

    # 定位 unlockCheck.sh: 优先 ~/unlockCheck.sh, 回退 /tmp/unlockCheck.sh, 再回退下载
    _script=""
    for _cand in ~/unlockCheck.sh /tmp/unlockCheck.sh; do
        if [ -s "$_cand" ] && [ "$(head -c 2 "$_cand" 2>/dev/null)" = "#!" ]; then
            _script="$_cand"; break
        fi
    done

    if [ -z "$_script" ]; then
        [ -z "$NODEHUB_URL" ] && { fail "未找到 unlockCheck.sh 且 NODEHUB_URL 为空, 无法下载"; return 1; }
        warn "本地未找到 unlockCheck.sh, 从 ${NODEHUB_URL} 下载..."
        if wget -q --timeout=30 --tries=3 -O /tmp/unlockCheck.sh "${NODEHUB_URL}/unlockCheck.sh" 2>/dev/null; then
            chmod +x /tmp/unlockCheck.sh
            _script=/tmp/unlockCheck.sh
        else
            fail "下载 unlockCheck.sh 失败"; return 1
        fi
    fi

    # 清除检测缓存, 强制重新探测 (与 unlockCheck.sh RunUnlockCheck 的缓存文件一一对应)
    section "清除检测缓存"
    for _f in \
        /tmp/media_unlock.txt /tmp/media_unlock_clean.txt \
        /tmp/media_check.txt  /tmp/media_check_clean.txt \
        /tmp/check_google_scholar_unlock.json \
        /tmp/notebooklm_check_result.json; do
        if [ -f "$_f" ]; then rm -f "$_f"; ok "已删除 $(basename "$_f")"; fi
    done

    section "执行 unlockCheck.sh (后台, 输出 → /tmp/unlockCheck.out)"
    info "脚本: ${_script}"
    info "提示: 流媒体检测耗时 1-3 分钟, 请耐心等待"

    nohup sh "$_script" > /tmp/unlockCheck.out 2>&1 &
    _pid=$!
    ok "已启动 (PID=${_pid})"

    printf '\n%b' "${C_CYAN}是否等待检测完成并查看结果? [Y/n] ${C_RESET}"
    read -r _wait
    case "$_wait" in
        n|N)
            info "检测后台运行中, 稍后查看: tail -f /tmp/unlockCheck.out"
            ;;
        *)
            info "等待中 (PID=${_pid}) ..."
            # set +e 等价: wait 在进程已结束时返回非零不致退出
            wait "$_pid" 2>/dev/null || true
            section "检测结果 (尾部)"
            tail -n 25 /tmp/unlockCheck.out 2>/dev/null || warn "无输出文件"
            ;;
    esac
}

# ============================================================
# 子命令 2: 节点故障自检 (核心诊断功能)
# 统计 ok / fail 计数, 末尾给出汇总; 异常时返回非零 (便于 cron/监控调用)
# ============================================================
_CHECK_OK=0
_CHECK_FAIL=0

_CkOK()   { ok "$*";   _CHECK_OK=$((_CHECK_OK + 1)); }
_CkFail() { fail "$*"; _CHECK_FAIL=$((_CHECK_FAIL + 1)); }
_CkWarn() { warn "$*"; _CHECK_OK=$((_CHECK_OK + 1)); }

# 单个服务检查, $1=服务名 $2=说明(面板管理类可跳过)
_CheckSvc() {
    _svc="$1"; _note="${2:-}"
    if SvcExists "$_svc"; then
        if SvcActive "$_svc"; then
            _CkOK "${_svc} 服务运行中 (active)${_note:+ ($_note)}"
        else
            _state=$(systemctl is-active "$_svc" 2>/dev/null || true)
            _CkFail "${_svc} 服务未运行 (状态: ${_state:-unknown}) → systemctl restart ${_svc}"
        fi
    else
        _CkWarn "${_svc} 服务未安装${_note:+ ($_note)}"
    fi
}

Action_SelfCheck() {
    title "🩺 节点故障自检"
    _CHECK_OK=0; _CHECK_FAIL=0

    # ---- 1. 系统资源 ----
    section "[1/8] 系统资源"

    # 磁盘
    _disk_info=$(df -BG / 2>/dev/null | awk 'NR==2 {print $3, $4, $5}')
    _disk_used=$(echo "$_disk_info" | awk '{print $1}')
    _disk_avail=$(echo "$_disk_info" | awk '{print $2}')
    _disk_pct=$(echo "$_disk_info" | awk '{gsub(/%/,"",$3); print $3}')
    if [ -n "$_disk_pct" ]; then
        if [ "$_disk_pct" -ge 90 ]; then
            _CkFail "磁盘 / 已用 ${_disk_pct}% (仅剩 ${_disk_avail}), 可能导致服务/日志写入失败"
        elif [ "$_disk_pct" -ge 80 ]; then
            _CkWarn "磁盘 / 已用 ${_disk_pct}% (剩余 ${_disk_avail}), 建议清理"
        else
            _CkOK "磁盘 / 已用 ${_disk_pct}% (已用 ${_disk_used} 剩余 ${_disk_avail})"
        fi
    else
        _CkFail "无法读取磁盘使用率"
    fi

    # 内存
    _mem_info=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t>0)printf "%.0f %.0f %.0f", (t-a)*100/t, (t-a)/1048576, t/1048576}' /proc/meminfo 2>/dev/null || true)
    if [ -n "$_mem_info" ]; then
        _mem_pct=$(echo "$_mem_info" | awk '{print $1}')
        if [ "$_mem_pct" -ge 90 ]; then
            _CkFail "内存使用 ${_mem_pct}% (接近耗尽), 可能触发 OOM"
        elif [ "$_mem_pct" -ge 80 ]; then
            _CkWarn "内存使用 ${_mem_pct}% (偏高)"
        else
            _CkOK "内存使用 ${_mem_pct}% ($(echo "$_mem_info" | awk '{print $2}')/$(echo "$_mem_info" | awk '{print $3}') GB)"
        fi
    else
        _CkFail "无法读取内存信息"
    fi

    # 负载
    _load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || true)
    if [ -n "$_load" ]; then _CkOK "系统负载: ${_load}"; else _CkFail "无法读取负载"; fi

    # ---- 2. 核心服务 ----
    section "[2/8] 核心服务"
    _CheckSvc xray       "代理核心, 必须运行"
    # nginx 在面板模式下由面板管理, 仅无面板时视为必需
    if [ -n "$PANEL_DETECTED" ]; then
        _CheckSvc nginx "面板 ${PANEL_DETECTED} 管理, 仅供参考"
    else
        _CheckSvc nginx "TLS 入口, 必须运行"
    fi
    _CheckSvc stat_client "ServerStatus 探针"
    _CheckSvc cron; _CheckSvc crond

    # ---- 3. 端口监听 ----
    section "[3/8] 端口监听"
    _listening=$(ss -tlnp 2>/dev/null || true)
    if printf '%s\n' "$_listening" | grep -qE ":${NODE_PORT}\b"; then
        _CkOK "端口 ${NODE_PORT} 正在监听"
    else
        _CkFail "端口 ${NODE_PORT} 未监听 → 客户端将无法连接 (检查 xray/nginx 是否启动)"
    fi
    # 80 端口 (ACME/重定向, 非必需)
    if printf '%s\n' "$_listening" | grep -qE ':80\b'; then
        _CkOK "端口 80 正在监听"
    else
        _CkWarn "端口 80 未监听 (通常不影响, ACME/重定向用)"
    fi

    # ---- 4. xray 配置校验 ----
    section "[4/8] Xray 配置"
    if [ -x /usr/local/bin/xray ] && [ -f /usr/local/etc/xray/config.json ]; then
        _xtest=$(/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json 2>&1 || true)
        if printf '%s\n' "$_xtest" | grep -qi 'Configuration OK'; then
            _CkOK "xray config.json 校验通过"
        else
            _CkFail "xray 配置校验失败 → /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json"
            info "$(printf '%s\n' "$_xtest" | tail -n 3 | sed 's/^/      /')"
        fi
    else
        _CkFail "xray 二进制或配置缺失 (/usr/local/bin/xray | /usr/local/etc/xray/config.json)"
    fi

    # ---- 5. 配置文件完整性 ----
    section "[5/8] 配置文件"
    _CheckFile() {
        _f="$1"; _desc="$2"
        if [ -s "$_f" ]; then
            _CkOK "${_desc}: ${_f}"
        else
            _CkFail "${_desc} 缺失或为空: ${_f}"
        fi
    }
    _CheckFile ~/.env       "用户配置"
    _CheckFile ~/node.env   "节点状态"
    if [ -f ~/node.json ]; then
        if command -v jq >/dev/null 2>&1 && jq empty ~/node.json 2>/dev/null; then
            _CkOK "node.json: 有效 JSON"
        else
            _CkFail "node.json: 损坏 (非合法 JSON) → jq empty ~/node.json"
        fi
    else
        _CkFail "node.json 不存在 → 节点可能未完成注册"
    fi
    _CheckFile ~/config.json "xray 配置 (主目录副本)"

    # ---- 6. SSL 证书 ----
    section "[6/8] SSL 证书"
    if [ -n "$ROOT_DOMAIN" ]; then
        _pem="/etc/ssl/${ROOT_DOMAIN}.pem"
        _key="/etc/ssl/${ROOT_DOMAIN}.key"
        if [ -s "$_pem" ] && [ -s "$_key" ]; then
            _CkOK "证书文件存在: ${ROOT_DOMAIN}.pem / .key"
            # 过期天数
            if command -v openssl >/dev/null 2>&1; then
                _end=$(openssl x509 -enddate -noout -in "$_pem" 2>/dev/null | cut -d= -f2)
                if [ -n "$_end" ]; then
                    # 计算剩余天数; "date -d '<enddate>'" 仅 GNU date 支持
                    # (busybox/BSD date 不支持, 旧实现解析失败 → _days 变负 → 误报已过期)
                    # 解析失败时回退 openssl -checkend 做跨平台判定
                    _days=""
                    if _end_secs=$(date -d "$_end" +%s 2>/dev/null) && [ -n "$_end_secs" ]; then
                        case "$_end_secs" in *[!0-9]*) ;; *) _days=$(( ( _end_secs - $(date +%s) ) / 86400 )) ;; esac
                    fi
                    if [ -n "$_days" ]; then
                        if [ "$_days" -le 0 ]; then
                            _CkFail "证书已过期 (到期: ${_end}) → 手动同步: manage.sh ssl"
                        elif [ "$_days" -le 7 ]; then
                            _CkWarn "证书即将过期, 剩余 ${_days} 天 (到期: ${_end})"
                        else
                            _CkOK "证书剩余 ${_days} 天 (到期: ${_end})"
                        fi
                    elif openssl x509 -checkend 604800 -noout -in "$_pem" 2>/dev/null; then
                        _CkOK "证书剩余 >7 天 (到期: ${_end})"
                    elif openssl x509 -checkend 0 -noout -in "$_pem" 2>/dev/null; then
                        _CkWarn "证书即将过期, 剩余不足 7 天 (到期: ${_end}) → manage.sh ssl"
                    else
                        _CkFail "证书已过期或校验失败 (到期: ${_end}) → 手动同步: manage.sh ssl"
                    fi
                fi
            fi
        else
            _CkFail "证书文件缺失: ${_pem} 或 ${_key} → manage.sh ssl"
        fi
    else
        _CkWarn "root_domain 为空, 跳过证书检查 (node.json 缺失或未配置域名)"
    fi

    # ---- 7. 定时任务 ----
    section "[7/8] 定时任务 (cron)"
    if [ -f /etc/crontab ]; then
        if grep -q 'nodeMonitor\.sh' /etc/crontab 2>/dev/null; then
            _CkOK "nodeMonitor.sh 已注册 (每分钟流量采样)"
        else
            _CkFail "/etc/crontab 缺少 nodeMonitor.sh 条目 → 流量统计将停止"
        fi
        if grep -q 'nodeAgent\.sh' /etc/crontab 2>/dev/null; then
            _CkOK "nodeAgent.sh 已注册 (每小时状态上报 + SSL 同步)"
        else
            _CkFail "/etc/crontab 缺少 nodeAgent.sh 条目 → 节点将停止上报"
        fi
    else
        _CkFail "/etc/crontab 不存在 → cron 未正确安装"
    fi
    # nodeMonitor 最近采样活跃度 (采样时间现持久化在 ~/nodeMonitor.json 的 last_time)
    if [ -f ~/nodeMonitor.json ]; then
        _mt=$(sed -n 's/.*"last_time":\([0-9][0-9]*\).*/\1/p' ~/nodeMonitor.json | head -1)
        if [ -n "$_mt" ]; then
            _now=$(date +%s)
            _diff=$((_now - _mt))
            if [ "$_diff" -le 300 ]; then
                _CkOK "nodeMonitor 最近采样 ${_diff}s 前 (正常)"
            else
                _CkFail "nodeMonitor 最近采样在 ${_diff}s 前 (>5分钟, 流量采集可能停滞)"
            fi
        fi
    fi

    # ---- 8. 网络连通性 ----
    section "[8/8] 网络连通性"
    # 公网出口
    _pub=$(curl -sS --connect-timeout 5 --max-time 8 -4 https://api.ip.sb 2>/dev/null || true)
    if [ -n "$_pub" ]; then
        _CkOK "公网出口 IPv4: ${_pub}"
    else
        _CkFail "无法访问公网 (api.ip.sb) → 检查网络/防火墙"
    fi
    # 面板 API
    if [ -n "$API_URL" ]; then
        if curl -sS --connect-timeout 5 --max-time 8 -o /dev/null "$API_URL" 2>/dev/null; then
            _CkOK "面板 API 可达: ${API_URL}"
        else
            _CkFail "面板 API 不可达: ${API_URL}"
        fi
    else
        _CkWarn "API_URL 未配置, 跳过面板连通性检查"
    fi
    # NODEHUB_URL
    if [ -n "$NODEHUB_URL" ]; then
        if curl -sS --connect-timeout 5 --max-time 8 -o /dev/null "${NODEHUB_URL}/nodeAgent.sh" 2>/dev/null; then
            _CkOK "资源站可达: ${NODEHUB_URL}"
        else
            _CkFail "资源站不可达: ${NODEHUB_URL} (脚本/证书将无法更新)"
        fi
    fi

    # ---- 汇总 ----
    section "自检汇总"
    if [ "$_CHECK_FAIL" -eq 0 ]; then
        _msg "${C_GREEN}${C_BOLD}✅ 全部通过: ${_CHECK_OK} 项检查正常, 未发现异常${C_RESET}"
    else
        _msg "${C_RED}${C_BOLD}❌ 发现 ${_CHECK_FAIL} 项异常${C_RESET} ${C_GRAY}(另 ${_CHECK_OK} 项正常/警告)${C_RESET}"
        _msg "${C_GRAY}提示: 异常项后已附修复命令, 可逐一执行${C_RESET}"
    fi
    [ "$_CHECK_FAIL" -eq 0 ]
}

# ============================================================
# 子命令 3: 查看节点状态
# ============================================================
Action_Status() {
    title "📊 节点状态"

    section "节点标识"
    if [ -n "$NODE_ID" ]; then
        info "node_id: ${NODE_ID}"
    else
        warn "node_id: 未配置 (节点可能未注册)"
    fi
    info "root_domain: ${ROOT_DOMAIN:-未配置}"
    info "node_port: ${NODE_PORT}"
    info "net_card: ${NET_CARD:-未知}"
    info "面板: ${PANEL_DETECTED:-无 (独立模式)}"

    # node.json 关键字段
    if [ -f ~/node.json ] && command -v jq >/dev/null 2>&1; then
        section "node.json 摘要"
        info "node_ids: $(jq -r '.node_ids // "无"' ~/node.json 2>/dev/null)"
        info "v2_name:  $(jq -r '.v2_name  // "无"' ~/node.json 2>/dev/null)"
        info "node_level: $(jq -r '.node_level // "无"' ~/node.json 2>/dev/null)"
    fi

    # 实时流量 (nodeMonitor.json) — 数字/字符串已分离, 用 jq -r 直取
    if [ -f ~/nodeMonitor.json ] && command -v jq >/dev/null 2>&1; then
        section "流量统计 (nodeMonitor.json)"
        info "当前速率: $(jq -r '.mbps // 0' ~/nodeMonitor.json) Mbps"
        info "峰值速率: $(jq -r '.max_mbps // 0' ~/nodeMonitor.json) Mbps"
        info "采样时间: $(jq -r '.ts // "未知"' ~/nodeMonitor.json)"
    fi

    # 服务状态一览
    section "服务状态"
    for _svc in xray nginx stat_client cron; do
        if SvcExists "$_svc"; then
            _state=$(systemctl is-active "$_svc" 2>/dev/null || true)
            case "$_state" in
                active) ok "$_svc: active" ;;
                *)      fail "$_svc: ${_state:-unknown}" ;;
            esac
        fi
    done
}

# ============================================================
# 子命令 4: 重启服务
# ============================================================
Action_Restart() {
    _target="${1:-}"

    if [ -z "$_target" ]; then
        title "🔄 重启服务"
        _msg "  ${C_CYAN}1)${C_RESET} xray         (代理核心)"
        _msg "  ${C_CYAN}2)${C_RESET} nginx        (TLS 入口)"
        _msg "  ${C_CYAN}3)${C_RESET} stat_client  (ServerStatus 探针)"
        _msg "  ${C_CYAN}4)${C_RESET} cron         (定时任务)"
        _msg "  ${C_CYAN}5)${C_RESET} all          (xray + nginx + stat_client + cron)"
        printf '%b' "${C_YELLOW}选择 [1-5]: ${C_RESET}"
        read -r _choice
        case "$_choice" in
            1) _target=xray ;; 2) _target=nginx ;; 3) _target=stat ;;
            4) _target=cron ;; 5) _target=all ;;
            *) warn "已取消"; return 0 ;;
        esac
    fi

    _svcs=""
    case "$_target" in
        xray)  _svcs="xray" ;;
        nginx) _svcs="nginx" ;;
        stat)  _svcs="stat_client" ;;
        cron)  _svcs="cron" ;;
        all)   _svcs="xray nginx stat_client cron" ;;
        *) die "未知服务: $_target (支持: xray|nginx|stat|cron|all)" ;;
    esac

    title "🔄 重启服务: $_target"
    for _svc in $_svcs; do
        if SvcExists "$_svc"; then
            if systemctl restart "$_svc" 2>/dev/null; then
                sleep 1
                if SvcActive "$_svc"; then
                    ok "$_svc 已重启 (active)"
                else
                    fail "$_svc 重启后仍未 active → journalctl -u $_svc -n 20"
                fi
            else
                fail "$_svc 重启失败"
            fi
        else
            warn "$_svc 未安装, 跳过"
        fi
    done
}

# ============================================================
# 子命令 5: 手动同步 SSL 证书
# 镜像 nodeAgent.sh SyncSSL 逻辑: wget -N + 校验 + reload nginx/xray
# ============================================================
Action_SyncSSL() {
    title "🔔 同步 SSL 证书"

    [ -z "$ROOT_DOMAIN" ] && die "root_domain 为空 (node.json 未配置域名), 无法同步"
    [ -z "$NODEHUB_URL" ] && die "NODEHUB_URL 未配置, 无法下载证书"
    command -v wget >/dev/null 2>&1 || die "wget 不可用"

    mkdir -p /etc/ssl
    _key_file="/etc/ssl/${ROOT_DOMAIN}.key"
    _pem_file="/etc/ssl/${ROOT_DOMAIN}.pem"
    _updated=0

    section "下载 ${ROOT_DOMAIN} 证书"

    _before=""
    [ -f "$_pem_file" ] && _before=$(stat -c %Y "$_pem_file" 2>/dev/null || echo "")

    for _ext in key pem; do
        _f="/etc/ssl/${ROOT_DOMAIN}.${_ext}"
        info "下载 ${ROOT_DOMAIN}.${_ext} ..."
        if wget -N --timeout=30 --tries=2 -P /etc/ssl "${NODEHUB_URL}/ssl/${ROOT_DOMAIN}.${_ext}" 2>/dev/null; then
            ok "${ROOT_DOMAIN}.${_ext} 下载完成"
        else
            fail "${ROOT_DOMAIN}.${_ext} 下载失败 (${NODEHUB_URL}/ssl/${ROOT_DOMAIN}.${_ext})"
        fi
    done

    _after=$(stat -c %Y "$_pem_file" 2>/dev/null || echo "")
    [ -n "$_before" ] && [ "$_before" != "$_after" ] && _updated=1

    # 权限
    chmod 600 "$_key_file" 2>/dev/null || true
    chmod 644 "$_pem_file" 2>/dev/null || true

    # 格式校验
    section "证书校验"
    if grep -q 'BEGIN CERTIFICATE' "$_pem_file" 2>/dev/null; then
        ok "${ROOT_DOMAIN}.pem 格式正确"
    else
        fail "${ROOT_DOMAIN}.pem 不含 CERTIFICATE (源文件可能损坏)"
    fi
    if grep -q 'PRIVATE KEY' "$_key_file" 2>/dev/null; then
        ok "${ROOT_DOMAIN}.key 格式正确"
    else
        fail "${ROOT_DOMAIN}.key 不含 PRIVATE KEY (源文件可能损坏)"
    fi

    # 过期天数
    if command -v openssl >/dev/null 2>&1; then
        _end=$(openssl x509 -enddate -noout -in "$_pem_file" 2>/dev/null | cut -d= -f2)
        [ -n "$_end" ] && info "证书到期: ${_end}"
    fi

    # 重载服务让新证书生效
    section "重载服务"
    if command -v nginx >/dev/null 2>&1 && SvcExists nginx; then
        if nginx -t 2>/dev/null; then
            if systemctl reload nginx 2>/dev/null; then ok "nginx 已 reload"
            else warn "nginx reload 失败 (尝试 restart)"; systemctl restart nginx 2>/dev/null && ok "nginx 已 restart"
            fi
        else
            warn "nginx -t 校验失败, 跳过 reload"
        fi
    else
        info "nginx 未安装/未管理, 跳过"
    fi

    # xray (Xray-core) 不支持 SIGHUP 热重载 —— 收到 SIGHUP 会直接退出 (与 nginx 不同)。
    # 旧 xray.service 曾配置 ExecReload=/bin/kill -HUP, `systemctl reload xray` 会把 xray
    # 杀死; 而 reload 退出码恒为 0 (systemd 只看 kill 命令是否执行成功), 旧 "reload 失败
    # 回退 restart" 判断永不触发 (死代码) → 静默停机。新 service 已无 ExecReload, reload 会
    # 直接报错。两种情况下 reload 都不可用, 统一改用 restart + is-active 健康校验。
    # 秒级断连可接受 (证书每天才更新一次)。
    if SvcExists xray; then
        if systemctl restart xray 2>/dev/null; then
            # restart 后轮询最多 5s 等 active (is-active 偶有滞后)
            _ssl_xi=0
            while [ "$_ssl_xi" -lt 5 ]; do
                sleep 1; _ssl_xi=$((_ssl_xi + 1))
                SvcActive xray && break
            done
            if SvcActive xray; then
                ok "xray 已 restart 并通过健康校验 (active)"
            else
                fail "xray restart 后 is-active 非 active — 请检查 config.json / 证书"
            fi
        else
            fail "xray restart 失败 — 请检查 xray.service / config.json / 证书格式"
        fi
    fi

    section "完成"
    if [ "$_updated" = "1" ]; then
        ok "证书已更新并重载服务"
    else
        info "证书未变化 (已是最新)"
    fi
}

# ============================================================
# 子命令 6: 查看日志
# ============================================================
Action_Logs() {
    _which="${1:-}"

    _targets() {
        _msg "  ${C_CYAN}agent${C_RESET}    ~/nodeLogs (nodeAgent 上报日志)"
        _msg "  ${C_CYAN}monitor${C_RESET}  /tmp/nodeMonitor.log (流量采样)"
        _msg "  ${C_CYAN}unlock${C_RESET}   /tmp/unlockCheck.out (解锁检测)"
        _msg "  ${C_CYAN}xray${C_RESET}     journalctl -u xray"
        _msg "  ${C_CYAN}nginx${C_RESET}    journalctl -u nginx"
    }

    [ -z "$_which" ] && {
        title "📜 查看日志"
        _targets
        printf '%b' "${C_YELLOW}选择日志 [输入名称, 默认 agent]: ${C_RESET}"
        read -r _which
        _which="${_which:-agent}"
    }

    _lines=50
    case "$_which" in
        agent)
            title "📜 ~/nodeLogs (尾部 ${_lines} 行)"
            if [ -f ~/nodeLogs ]; then tail -n "$_lines" ~/nodeLogs; else warn "~/nodeLogs 不存在"; fi
            ;;
        monitor)
            title "📜 /tmp/nodeMonitor.log (尾部 ${_lines} 行)"
            if [ -f /tmp/nodeMonitor.log ]; then tail -n "$_lines" /tmp/nodeMonitor.log; else warn "/tmp/nodeMonitor.log 不存在"; fi
            ;;
        unlock)
            title "📜 /tmp/unlockCheck.out (尾部 ${_lines} 行)"
            if [ -f /tmp/unlockCheck.out ]; then tail -n "$_lines" /tmp/unlockCheck.out; else warn "/tmp/unlockCheck.out 不存在"; fi
            ;;
        xray)
            title "📜 journalctl -u xray (尾部 ${_lines} 行)"
            journalctl -u xray --no-pager -n "$_lines" 2>/dev/null || warn "journalctl 不可用"
            ;;
        nginx)
            title "📜 journalctl -u nginx (尾部 ${_lines} 行)"
            journalctl -u nginx --no-pager -n "$_lines" 2>/dev/null || warn "journalctl 不可用"
            ;;
        *)
            _targets
            die "未知日志: $_which"
            ;;
    esac
}

# ============================================================
# 子命令 7: 更新本地脚本 (从 NODEHUB_URL 重新下载)
# ============================================================
Action_Update() {
    title "📥 更新本地脚本"
    [ -z "$NODEHUB_URL" ] && die "NODEHUB_URL 未配置, 无法下载"

    _files="nodeAgent.sh nodeMonitor.sh unlockCheck.sh"
    for _f in $_files; do
        info "更新 ${_f} ..."
        if wget -q --timeout=30 --tries=3 -O ~/"${_f}" "${NODEHUB_URL}/${_f}" 2>/dev/null; then
            chmod +x ~/"${_f}"
            if [ -s ~/"${_f}" ]; then
                ok "${_f} 更新成功 ($(wc -c < ~/"${_f}") bytes)"
            else
                fail "${_f} 更新后为空"
            fi
        else
            fail "${_f} 下载失败"
        fi
    done

    if Confirm "是否重启 cron 以立即应用 nodeAgent/nodeMonitor 更新?"; then
        systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || warn "cron 重启失败"
        ok "cron 已重启"
    fi
}

# ============================================================
# 子命令 8: 重新安装代理
# ============================================================
Action_Reinstall() {
    title "♻️  重新安装代理 (proxyInstall.sh)"
    warn "此操作将重新注册节点并重装 xray/nginx, 可能短暂中断服务!"

    [ -z "$NODEHUB_URL" ] && die "NODEHUB_URL 未配置, 无法下载 proxyInstall.sh"

    if ! Confirm "确认要重新安装吗?"; then
        info "已取消"; return 0
    fi

    section "下载并执行 proxyInstall.sh"
    cd /tmp || die "无法进入 /tmp"
    if wget -q --timeout=60 --tries=3 -O /tmp/proxyInstall.sh "${NODEHUB_URL}/proxyInstall.sh" 2>/dev/null; then
        chmod +x /tmp/proxyInstall.sh
        ok "proxyInstall.sh 下载完成, 开始执行"
        sh /tmp/proxyInstall.sh
    else
        die "proxyInstall.sh 下载失败"
    fi
}

# ============================================================
# 交互式菜单
# ============================================================
ShowMenu() {
    printf '\n'
    title "nodeHub 节点运维菜单 ${RUN_VERSION}"
    _msg "  ${C_GRAY}节点: ${NODE_ID:-未配置} ${ROOT_DOMAIN:+| ${ROOT_DOMAIN}}${C_RESET}"
    _msg ""
    _msg "  ${C_CYAN} 1${C_RESET}) 🔓 流媒体解锁检测"
    _msg "  ${C_CYAN} 2${C_RESET}) 🩺 节点故障自检"
    _msg "  ${C_CYAN} 3${C_RESET}) 📊 查看节点状态"
    _msg "  ${C_CYAN} 4${C_RESET}) 🔄 重启服务"
    _msg "  ${C_CYAN} 5${C_RESET}) 🔔 同步 SSL 证书"
    _msg "  ${C_CYAN} 6${C_RESET}) 📜 查看日志"
    _msg "  ${C_CYAN} 7${C_RESET}) 📥 更新本地脚本"
    _msg "  ${C_CYAN} 8${C_RESET}) ♻️  重新安装代理"
    _msg "  ${C_CYAN} q${C_RESET}) 🚪 退出"
    printf '\n'
}

MenuLoop() {
    while :; do
        ShowMenu
        printf '%b' "${C_BOLD}${C_YELLOW}请选择: ${C_RESET}"
        read -r _opt
        case "$_opt" in
            1) Action_UnlockCheck ;;
            2) Action_SelfCheck ;;
            3) Action_Status ;;
            4) Action_Restart ;;
            5) Action_SyncSSL ;;
            6) Action_Logs ;;
            7) Action_Update ;;
            8) Action_Reinstall ;;
            q|Q|quit|exit) _msg "${C_GREEN}再见 👋${C_RESET}"; break ;;
            '') continue ;;
            *) warn "无效选择: $_opt" ;;
        esac
        Pause
    done
}

# ============================================================
# 帮助
# ============================================================
Usage() {
    cat <<EOF
nodeHub 运维菜单 ${RUN_VERSION}

用法:
  sh manage.sh              交互式菜单
  sh manage.sh <子命令>     非交互执行单个操作

子命令:
  unlock            重新测试流媒体解锁 (清缓存重跑)
  check             节点故障自检 (服务/端口/配置/证书/磁盘/网络)
  status            查看节点状态摘要
  restart <svc>     重启服务 (xray|nginx|stat|cron|all)
  ssl               手动同步 SSL 证书并重载服务
  logs <name>       查看日志 (agent|monitor|unlock|xray|nginx)
  update            从 NODEHUB_URL 更新本地脚本
  reinstall         重新运行 proxyInstall.sh
  help              显示本帮助

示例:
  sh manage.sh check                 # 一键自检
  sh manage.sh restart xray          # 重启 xray
  sh manage.sh logs xray             # 查看 xray 日志
  sh manage.sh ssl                   # 手动同步证书

退出码:
  check 子命令: 全部通过返回 0, 存在异常返回 1 (可用于监控告警)
EOF
}

# ============================================================
# 入口
# ============================================================
LoadEnv

# root 检查 (大多数操作需要 root, 仅查看/帮助不需要)
_need_root() {
    case "$1" in
        restart|ssl|update|reinstall|unlock) return 0 ;;
        *) return 1 ;;
    esac
}

if [ "$#" -eq 0 ]; then
    # 无参数: 启动交互菜单 (需 TTY)
    if [ ! -t 0 ]; then
        Usage
        echo ""
        die "非交互环境请使用子命令 (见上方帮助), 例如: sh manage.sh check"
    fi
    MenuLoop
    exit 0
fi

_cmd="$1"; shift
case "$_cmd" in
    unlock)    if _need_root unlock && [ "$(id -u)" -ne 0 ]; then die "需要 root 权限"; fi; Action_UnlockCheck "$@" ;;
    check)     Action_SelfCheck "$@" ;;
    status)    Action_Status "$@" ;;
    restart)   [ "$(id -u)" -ne 0 ] && die "需要 root 权限"; Action_Restart "$@" ;;
    ssl)       [ "$(id -u)" -ne 0 ] && die "需要 root 权限"; Action_SyncSSL "$@" ;;
    logs)      Action_Logs "$@" ;;
    update)    [ "$(id -u)" -ne 0 ] && die "需要 root 权限"; Action_Update "$@" ;;
    reinstall) [ "$(id -u)" -ne 0 ] && die "需要 root 权限"; Action_Reinstall "$@" ;;
    -h|--help|help) Usage ;;
    *) Usage; echo ""; die "未知子命令: $_cmd" ;;
esac
