#!/bin/sh
# ============================================================
# proxyDiagnose.sh — 代理服务 (xray / nginx / 代理安装环境) 故障诊断脚本
#
# 职责: 一键检查 xray / nginx / 代理无法【安装】或【运行】的各种可能原因。
#       覆盖真实生产故障场景, 包括但不限于:
#         · 端口冲突 (nginx 与 xray 抢 443/80 — 本次 179.61.138.177 故障)
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
#   ./proxyDiagnose.sh --target net         # 只查网络与防火墙
#   ./proxyDiagnose.sh --target cert        # 只查 TLS 证书
#   ./proxyDiagnose.sh --json               # 输出 JSON (供程序解析)
#   ./proxyDiagnose.sh --quiet              # 只输出 FAIL/WARN, 不输出 PASS
#   ./proxyDiagnose.sh --no-color           # 关闭颜色
#   ./proxyDiagnose.sh --host root@1.2.3.4  # 远程诊断 (ssh 执行, 本地无需登录)
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

# ============================================================
# 命令行参数解析
# ============================================================
TARGET="all"
JSON_OUTPUT=0
QUIET=0
USE_COLOR=1
REMOTE_HOST=""

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --json)   JSON_OUTPUT=1; USE_COLOR=0; shift ;;
        --quiet)  QUIET=1; shift ;;
        --no-color) USE_COLOR=0; shift ;;
        --host)   REMOTE_HOST="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "未知参数: $1 (用 --help 查看用法)" >&2; exit 2 ;;
    esac
done

# ============================================================
# 远程模式: 把自身推送到远程主机执行 (保证远程环境一致)
# 远程主机必须有 bash/sh + 基础工具; 无需预装本脚本
# ============================================================
if [ -n "$REMOTE_HOST" ]; then
    # 通过 ssh 执行自身 (stdin 传入脚本内容, 远程用 sh 跑; 剥离 --host 避免递归)
    # 远程为非 TTY, 颜色由 [ -t 1 ] 自动关闭, 无需转发 --no-color
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$REMOTE_HOST" \
        "sh -s -- --target $TARGET $( [ "$JSON_OUTPUT" = 1 ] && echo --json ) $( [ "$QUIET" = 1 ] && echo --quiet )" \
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
# ============================================================
_NotifyTG() {
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

    # X9. 端口冲突 — nginx↔xray 双重声明抢占 + xray 端口运行时占用
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
# 端口声明与冲突检测 (核心: nginx ↔ xray 双重声明抢占)
#
# 设计:
#   · 允许 xray 占用其自身声明的端口 (xray 是代理主服务, 占用合法, 不报错)
#   · 允许 nginx 占用其自身声明的端口
#   · 真正的故障 = nginx 与 xray 【同时声明】同一端口 (典型如 443),
#     二者无法共存: 谁先启动谁抢到, 后者 'bind: address already in use'
#     退出 (exit 255/EXCEPTION)。这是 179.61.138.177 故障的根因。
#   · 次要风险 = 某服务声明的端口被【无关第三方进程】占用
#
# 三类检查 (重叠端口只报告一次, 不重复):
#   1) _PortOverlapCheck   : nginx ∩ xray 双重声明 → FAIL (抢占冲突根因)
#   2) _XrayPortRuntime    : xray 独占端口的运行时占用 (跳过重叠项)
#   3) _NginxPortRuntime   : nginx 独占端口的运行时占用 (跳过重叠项)
# ============================================================

# ---- 返回 xray 配置声明的监听端口 (空格分隔, 去重纯数字) ----
# inbound.port 可能是数字或 "1000-2000" 范围; 仅取纯数字端口
_XrayDeclaredPorts() {
    [ -f "$_XRAY_CONF" ] && has jq || return 0
    jq -r '.inbounds[]?.port // empty' "$_XRAY_CONF" 2>/dev/null \
        | grep -oE '^[0-9]+$' | sort -un | tr '\n' ' '
}

# ---- 返回 nginx 声明的监听端口 (空格分隔, 去重纯数字) ----
# listen 形态: `80` / `443 ssl` / `127.0.0.1:8088` / `[::]:80` / `[::1]:443` / `unix:/x`
# → 取 listen 后第一个 token, 再取最后冒号后部分 (剥离 IP 前缀), 仅留纯数字
_NginxDeclaredPorts() {
    has nginx || return 0
    if nginx -T >/dev/null 2>&1; then
        _src=$(nginx -T 2>/dev/null)
    else
        # 降级: 读取 conf 目录原始行 (含注释, 后续统一剥离)
        _src=$(grep -rhE '.' "$_NGINX_CONF_DIR" 2>/dev/null)
    fi
    # 先剥离 # 注释 (否则 `# listen 443 ssl;` 这类注释会被误判为真实声明),
    # 再取 listen 后第一个 token, 再取最后冒号后部分 (剥离 IP 前缀), 仅留纯数字
    printf '%s\n' "$_src" | sed 's/#.*//' \
        | sed -n 's/.*listen[[:space:]][[:space:]]*\([^ ;]*\).*/\1/p' \
        | sed -E 's/.*://' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' '
}

# ---- 某端口的运行时占用进程名 (换行分隔, 去重) ----
_RuntimeHolders() {  # $1 = port
    ss -H -tulnp 2>/dev/null | grep -E "[:.]$1\b" \
        | sed -n 's/.*users:(("//;s/".*//p' | sort -u
}

# ---- 端口是否在空格分隔列表中 ----
_PortIn() {  # _PortIn <port> <"p1 p2 p3">
    case " $2 " in *" $1 "*) return 0 ;; esac
    return 1
}

# ---- 缓存声明端口 (避免重复解析 nginx -T) ----
_EnsurePorts() {
    [ -n "${_XP+set}" ] || _XP=$(_XrayDeclaredPorts)
    [ -n "${_NP+set}" ] || _NP=$(_NginxDeclaredPorts)
}

# ---- 核心: nginx ∩ xray 双重声明抢占检查 (幂等, 全程仅报告一次) ----
# 检测 nginx 与 xray 是否同时声明了同一端口 (如 443) —— 这是抢占冲突的根因
_PORT_OVERLAP_DONE=0
_PortOverlapCheck() {
    [ "$_PORT_OVERLAP_DONE" = 1 ] && return 0
    _PORT_OVERLAP_DONE=1
    has nginx && has jq && [ -f "$_XRAY_CONF" ] || return 0
    _EnsurePorts
    [ -n "$_XP" ] && [ -n "$_NP" ] || return 0

    for _port in $_XP; do
        if _PortIn "$_port" "$_NP"; then
            _win=$(_RuntimeHolders "$_port" | grep -v '^$')
            _win=$(printf '%s' "$_win" | tr '\n' ',' | sed 's/,$//')
            [ -n "$_win" ] && _win_detail="当前实际占用者: [${_win}]" || _win_detail="当前无进程占用 (二者均未成功启动)"
            result FAIL "PORT_DUAL_DECL_${_port}" \
                "端口 ${_port} 同时被 nginx 与 xray 声明监听 → 抢占冲突" \
                "二者无法共存: systemd 启动顺序决定谁先抢到端口, 后者必然 'bind: address already in use' 退出 (exit 255/EXCEPTION)。${_win_detail}。解决: 让其中一方让出 ${_port} (如 nginx 改 8443, 或 xray 走 nginx 反代 / SNI 分流)"
        fi
    done
}

# ---- xray 独占端口的运行时占用检查 (允许 xray 自身占用, 不报错) ----
_XrayPortRuntimeCheck() {
    [ -f "$_XRAY_CONF" ] && has jq || return 0
    _EnsurePorts
    for _port in $_XP; do
        _PortIn "$_port" "$_NP" && continue   # 跳过重叠项 (已由 _PortOverlapCheck 报告)
        _h=$(_RuntimeHolders "$_port")
        if printf '%s\n' "$_h" | grep -qx 'xray'; then
            result PASS "PORT_XRAY_LISTEN_${_port}" "xray 正在监听端口 ${_port} (允许占用)"
        elif [ -z "$_h" ]; then
            result PASS "PORT_FREE_${_port}" "端口 ${_port} 空闲, 可供 xray 使用"
        else
            _how=$(printf '%s' "$_h" | tr '\n' ',' | sed 's/,$//')
            result FAIL "PORT_OCCUPIED_${_port}" "xray 需要端口 ${_port}, 但被无关进程 [$_how] 占用" \
                "停止占用进程, 或让 xray 改用空闲端口"
        fi
    done
}

# ---- nginx 独占端口的运行时占用检查 (允许 nginx 自身占用, 不报错) ----
_NginxPortRuntimeCheck() {
    has nginx || return 0
    _EnsurePorts
    for _port in $_NP; do
        _PortIn "$_port" "$_XP" && continue   # 跳过重叠项
        _h=$(_RuntimeHolders "$_port")
        if printf '%s\n' "$_h" | grep -qx 'nginx'; then
            result PASS "PORT_NGINX_LISTEN_${_port}" "nginx 正在监听端口 ${_port}"
        elif [ -z "$_h" ]; then
            result PASS "PORT_NGINX_FREE_${_port}" "端口 ${_port} 空闲, 可供 nginx 使用"
        else
            _how=$(printf '%s' "$_h" | tr '\n' ',' | sed 's/,$//')
            result FAIL "NGINX_PORT_OCCUPIED_${_port}" "nginx 需要端口 ${_port}, 但被无关进程 [$_how] 占用" \
                "停止占用进程, 或修改 nginx listen 端口"
        fi
    done
}

# ---- 扫描 xray 配置中的证书引用, 检查存在/可读/过期 ----
_check_cert_refs_in_xray() {
    _cfg="$1"; [ -f "$_cfg" ] || return 0; has jq || return 0
    _certs=$(jq -r '.. | .certificateFile? // empty' "$_cfg" 2>/dev/null | sort -u)
    _keys=$(jq -r '.. | .keyFile? // empty' "$_cfg" 2>/dev/null | sort -u)
    for _f in $_certs $_keys; do
        [ -n "$_f" ] || continue
        case "$_f" in /*) : ;; *) continue ;; esac   # 只查绝对路径
        if [ ! -e "$_f" ]; then
            result FAIL "XRAY_CERT_MISSING" "配置引用的证书/密钥不存在: $_f" "xray 启动会因找不到证书而失败; 补齐证书或修正路径"
        elif [ ! -r "$_f" ]; then
            result FAIL "XRAY_CERT_NOREAD" "证书/密钥不可读: $_f" "检查文件权限与运行用户 (systemd User=)"
        else
            result PASS "XRAY_CERT_OK" "证书文件就绪: $_f"
            # 过期检查 (仅对证书 cert, 非 key)
            case "$_f" in *.key|*key*) continue ;; esac
            _check_cert_expiry "$_f"
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

# ---- nginx 端口冲突 (委托给统一检测: 双重声明 + 运行时占用) ----
# 解析逻辑已收敛到 _NginxDeclaredPorts, 由 _PortOverlapCheck / _NginxPortRuntimeCheck 复用
_check_nginx_port_conflict() {
    _PortOverlapCheck
    _NginxPortRuntimeCheck
}

# ---- nginx 证书引用 ----
_check_nginx_certs() {
    nginx -T >/dev/null 2>&1 || return 0
    _certs=$(nginx -T 2>/dev/null | grep -oE 'ssl_certificate\s+[^;]*;' | sed -E 's/ssl_certificate\s+//;s/;$//' | sort -u)
    for _f in $_certs; do
        case "$_f" in
            /etc/ssl/certs/*|/etc/letsencrypt/*) : ;;
        esac
        if [ ! -e "$_f" ]; then
            result FAIL "NGINX_CERT_MISSING" "nginx 引用证书不存在: $_f" "nginx -t 会报 emerg; 补齐证书或注释该 server 块"
        elif [ ! -r "$_f" ]; then
            result FAIL "NGINX_CERT_NOREAD" "nginx 证书不可读: $_f"
        else
            result PASS "NGINX_CERT_OK" "nginx 证书就绪: $_f"
            _check_cert_expiry "$_f"
        fi
    done
}

# ============================================================
# TLS 证书通用检查 (过期) — 被 xray/nginx 共用
# ============================================================
_check_cert_expiry() {
    _f="$1"
    has openssl || return 0
    # 仅处理 PEM 文本证书
    grep -q 'BEGIN CERTIFICATE' "$_f" 2>/dev/null || return 0
    _end=$(openssl x509 -in "$_f" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    [ -n "$_end" ] || return 0
    _end_epoch=$(date -d "$_end" +%s 2>/dev/null) || return 0
    _now=$(date +%s)
    _days=$(( (_end_epoch - _now) / 86400 ))
    _cn=$(openssl x509 -in "$_f" -noout -subject 2>/dev/null | sed 's/.*CN=//' | sed 's#/.*##')
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
    say "网络与防火墙 (iptables / ufw / firewalld / SELinux)"

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
}

# ============================================================
# TLS 证书专项 (cert) — 扫描常见证书目录
# ============================================================
check_cert() {
    say "TLS 证书专项扫描"
    _found=0
    for _d in /etc/letsencrypt/live /root/.acme.sh /etc/nginx/ssl /etc/ssl /usr/local/etc/xray "$_XRAY_DIR"; do
        [ -d "$_d" ] || continue
        # 找 fullchain.pem / .crt / .cer
        for _c in $(find "$_d" -maxdepth 3 -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) 2>/dev/null | head -30); do
            grep -q 'BEGIN CERTIFICATE' "$_c" 2>/dev/null || continue
            _found=1
            _check_cert_expiry "$_c"
        done
    done
    [ "$_found" = 0 ] && result WARN "CERT_NONE_FOUND" "常见目录未扫描到证书文件" "若无 TLS 入站可忽略; 否则检查证书路径"
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
    case "$TARGET" in
        all)
            check_env
            check_xray
            check_nginx
            check_cert
            check_net
            ;;
        xray)  check_xray ;;
        nginx) check_nginx ;;
        env)   check_env ;;
        net)   check_net ;;
        cert)  check_cert ;;
        *) echo "未知 --target: $TARGET (可选: all|xray|nginx|env|net|cert)" >&2; exit 2 ;;
    esac

    summary
    _NotifyTG
}

# 注意: 故意不设 set -e — 诊断脚本必须每项独立, 一项失败绝不中断其它检查
Main
# 退出码 = 失败数 (上限 99), 便于上层脚本/监控判断
[ "$_FAIL" -gt 99 ] && exit 99
exit "$_FAIL"
