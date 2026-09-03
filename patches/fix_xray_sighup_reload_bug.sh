#!/bin/sh
# ============================================================
# fix_xray_sighup_reload_bug.sh — Xray SIGHUP/reload 静默停机 bug 巡检 + 自动修复
#
# 背景 (真实故障):
#   xray (Xray-core) 不支持 SIGHUP 热重载, 收到 SIGHUP 会直接退出。早期 xray.service
#   错误配置 ExecReload=/bin/kill -HUP $MAINPID, 导致 `systemctl reload xray` 把 xray
#   杀死; 而 systemctl reload 退出码恒为 0 (systemd 只看 kill 命令是否执行成功), 调用方
#   无法察觉; 又因 Restart=on-failure 不把"被信号杀死"视为 failure, xray 不会被自动拉起
#   → 静默停机 (本节点曾因此停机约 24 小时)。
#
# 本脚本 (幂等, 可反复运行; 健康时静默退出):
#   1) 检测 xray.service 是否含致命的 ExecReload=...-HUP 配置 → 删除 (并清理误导注释)
#   2) 检测 Restart 策略是否为 on-failure/no (信号杀死不兜底) → 升级为 always
#   3) 检测 xray 当前是否未运行 (is-active != active) → 尝试 restart 并验证
#   4) 任一发现 → 备份原 service 文件 + daemon-reload + (必要时) restart, 并发 Telegram
#      告警 (含 服务器IP / node_id / 发现 / 已修复 / 当前状态)
#   5) 健康巡检节流: 同一持续故障 6h 内只告警一次 (避免每小时刷屏); 故障消除后自动解除
#
# 部署模型: 由 nodeAgent.sh :: PatchXraySighupReloadBug 从
#   ${NODEHUB_URL}/patches/fix_xray_sighup_reload_bug.sh 下载到 /tmp 后执行;
#   亦可手动 `sh fix_xray_sighup_reload_bug.sh` 在任意节点独立运行 (自读 ~/.env 发 TG)。
#   各节点独立巡检自身 xray, 经 nodeAgent 调度即可覆盖"所有服务器"。
#
# 退出码: 恒为 0 (失败不阻断 nodeAgent 主流程; 告警经 Telegram 发出)
# ============================================================
set -u

# ---------- 配置 ----------
# 同一持续故障的告警节流窗口 (秒); 设 0 关闭节流
THROTTLE_SEC="${XRAY_BUG_GUARD_THROTTLE_SEC:-21600}"   # 默认 6 小时

# ---------- 加载节点配置 (~/.env 全大写人工配置 + ~/node.env 脚本生成; 后者覆盖) ----------
# 注意: `. "$_f"` 是 source, 会执行文件内的 shell 代码 (并非"只读取变量")。
# 这些文件由 root 拥有, 信任级别与 nodeAgent.sh 自身相同; 不可写则不 source。
_load_env() {
    for _f in "$HOME/.env" "$HOME/node.env"; do
        [ -f "$_f" ] || continue
        # shellcheck disable=SC1090
        . "$_f" 2>/dev/null || true
    done
}
_load_env

_TG_TOKEN="${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
_TG_CHAT="${TELEGRAM_CHAT_ID:-${TG_CHAT_ID:-}}"
_NODE_ID="${node_id:-${NODE_ID:-}}"

# ---------- 日志 (纯文本无颜色; 输出由 nodeAgent/cron 捕获进 ~/nodeLogs) ----------
_log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }

# ---------- Telegram 通知 (与 nodeAgent.sh NotifyTG 一致的 token/chat 优先级) ----------
# 用法: _tg <level> <message>
_tg() {
    _tg_level="$1"; _tg_text="$2"
    { [ -z "$_TG_TOKEN" ] || [ -z "$_TG_CHAT" ]; } && return 0
    _tg_emoji=$(case "$_tg_level" in
        error) printf '❌' ;; warn) printf '⚠️' ;; info) printf 'ℹ️' ;; *) printf '📝' ;; esac)
    _tg_full="${_tg_emoji} [NodeHub] fix_xray_sighup_reload_bug.sh
等级: ${_tg_level}
节点ID: ${_NODE_ID:-N/A}
时间: $(date '+%Y-%m-%d %H:%M:%S')

${_tg_text}"
    curl -sS --connect-timeout 5 --max-time 15 \
        --data-urlencode "chat_id=${_TG_CHAT}" \
        --data-urlencode "text=${_tg_full}" \
        "https://api.telegram.org/bot${_TG_TOKEN}/sendMessage" >/dev/null 2>&1 || true
}

# ---------- 取节点 IP (供告警标注来源) ----------
_get_ip() {
    for _cand in "${node_ip:-}" "${NODE_IP:-}"; do
        [ -n "$_cand" ] && { printf '%s' "$_cand"; return 0; }
    done
    _cand=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$_cand" ] && { printf '%s' "$_cand"; return 0; }
    hostname 2>/dev/null || printf '未知'
}

# ---------- 主流程 ----------
_main() {
    command -v systemctl >/dev/null 2>&1 || { _log debug "systemctl 不存在, 跳过"; exit 0; }
    # 仅当本机装了 xray 才巡检 (非 xray 节点静默跳过)
    systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service' \
        || { _log debug "xray.service 未安装, 跳过"; exit 0; }

    # 定位真实 service 文件 (FragmentPath), 兜底标准路径
    _frag=$(systemctl show -p FragmentPath --value xray 2>/dev/null)
    [ -z "$_frag" ] && _frag=/etc/systemd/system/xray.service
    [ -f "$_frag" ] || { _log debug "service 文件不存在: $_frag, 跳过"; exit 0; }

    _findings=""
    _actions=""
    _cfg_changed=0

    # ---- 检测 A: 致命的 ExecReload=...-HUP (xray 不支持 SIGHUP, reload 会杀进程) ----
    if grep -qE '^ExecReload=.*-HUP' "$_frag" 2>/dev/null; then
        _findings="${_findings}• xray.service 含 ExecReload=/bin/kill -HUP \$MAINPID (xray 不支持 SIGHUP, systemctl reload 会把 xray 杀死, 且退出码仍为 0 → 静默停机)
"
        cp -a "$_frag" "${_frag}.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
        # 删除 bad ExecReload 行 + 误导注释 (SIGHUP 热重载 / systemctl reload xray)
        sed -i \
            -e '/^ExecReload=.*-HUP/d' \
            -e '\@^#[[:space:]]*SIGHUP 热重载@d' \
            -e '\@^#[[:space:]].*systemctl reload xray@d' \
            "$_frag"
        _actions="${_actions}• 已删除 ExecReload (kill -HUP) 及误导注释
"
        _cfg_changed=1
    fi

    # ---- 检测 B: Restart 策略不足 (on-failure/no 不兜底"被信号杀死") ----
    if grep -qE '^Restart=(on-failure|no)$' "$_frag" 2>/dev/null; then
        _bad_restart=$(grep -oE '^Restart=(on-failure|no)' "$_frag" | head -1)
        _findings="${_findings}• Restart=${_bad_restart#Restart=} (被信号杀死不自动拉起, 兜底不足)
"
        [ "$_cfg_changed" = 0 ] && cp -a "$_frag" "${_frag}.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
        sed -i -e 's/^Restart=on-failure$/Restart=always/' -e 's/^Restart=no$/Restart=always/' "$_frag"
        _actions="${_actions}• 已把 Restart 升级为 always (任何退出都自动拉起)
"
        _cfg_changed=1
    fi

    if [ "$_cfg_changed" = 1 ]; then
        systemctl daemon-reload 2>/dev/null || true
        _actions="${_actions}• 已 systemctl daemon-reload
"
    fi

    # ---- 检测 C: xray 当前是否未运行 (bug 的症状; 也覆盖其它原因的宕机) ----
    _down=0
    [ "$(systemctl is-active xray 2>/dev/null)" != "active" ] && _down=1

    if [ "$_down" = 1 ]; then
        _findings="${_findings}• xray 当前未运行 (is-active=$(systemctl is-active xray 2>/dev/null))
"
        if systemctl restart xray 2>/dev/null; then
            # 轮询最多 5 秒等待 active
            _i=0
            while [ "$_i" -lt 5 ]; do
                sleep 1; _i=$((_i + 1))
                [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && break
            done
            _actions="${_actions}• 已 systemctl restart xray (重启后 is-active=$(systemctl is-active xray 2>/dev/null))
"
        else
            _actions="${_actions}• ⚠️ systemctl restart xray 失败 — 需人工介入 (检查 config.json / 证书 / 二进制)
"
        fi
    fi

    # ---- 无任何发现 → 健康, 静默退出 (并清除历史节流标记, 为下次新故障即时告警做准备) ----
    if [ -z "$_findings" ]; then
        rm -f "$HOME/nodeAgent.xray-bug-guard.throttle" 2>/dev/null || true
        _log debug "xray 巡检通过 (配置正确 + active), 无需处理"
        exit 0
    fi

    # ---- 组装结果 ----
    _after_active=$(systemctl is-active xray 2>/dev/null)
    _after_pid=$(systemctl show -p MainPID --value xray 2>/dev/null || echo '?')
    if command -v ss >/dev/null 2>&1; then
        _ports=$(ss -tlnp 2>/dev/null | grep -c xray)
    else
        _ports="(ss 不可用)"
    fi

    # ---- 节流: 同一持续故障在窗口内只告警一次 (修复仍照常执行) ----
    _mark="$HOME/nodeAgent.xray-bug-guard.throttle"
    if [ "${THROTTLE_SEC:-0}" -gt 0 ] 2>/dev/null; then
        _now=$(date +%s)
        _last=$(cat "$_mark" 2>/dev/null || echo 0)
        if [ $((_now - _last)) -lt "${THROTTLE_SEC}" ]; then
            _log warn "xray bug 巡检: 发现问题但处于 ${THROTTLE_SEC}s 节流窗口内, 本次告警抑制 (仍已尝试修复):
$(printf '%b' "$_findings")"
            exit 0
        fi
        echo "$_now" > "$_mark" 2>/dev/null || true
    fi

    # ---- 发 Telegram + 写错误日志 ----
    _msg="🚨 [NodeHub] Xray SIGHUP/reload 静默停机 bug 巡检命中
主机: $(hostname 2>/dev/null || echo '?')
IP: $(_get_ip)

【发现】
$(printf '%b' "$_findings")
【已自动修复】
$(printf '%b' "$_actions")
【当前状态】
is-active: ${_after_active}
MainPID: ${_after_pid}
监听端口数(xray): ${_ports}"

    _log error "xray bug 巡检命中并已自动处理:
$_msg"
    _tg error "$_msg"
    exit 0
}

_main "$@"
