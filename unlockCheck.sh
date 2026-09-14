#!/bin/sh
# ============================================================
# unlockCheck.sh — 独立 IP 服务解锁检测脚本
# 职责: 检测 IP 对各服务的解锁状态 → 解析结果 → POST /api/node/unlock_check
#       → 重新拉取 Xray config.json → 有变化才重启 xray (闭环)
# 检测范围: 流媒体(Netflix/Disney+/Bahamut/MeWatch)、AI(ChatGPT/Claude/Gemini/NotebookLM)、
#           社交平台(TikTok/Bilibili/iQIYI)、搜索(Google Scholar/Bing)
# 闭环说明: 面板生成 config.json 依赖 node_unlock 数据, 而安装时
#           (Step3_InstallXray) 拉取的配置生成于解锁数据上报之前;
#           故上报完成后必须重新拉取配置并重启 xray, 解锁路由才会生效。
# 用法:
#   直接运行:  sh ~/unlockCheck.sh
#   后台运行:  nohup sh ~/unlockCheck.sh >> ~/nodeLogs 2>&1 &
# ============================================================

set -eu

SCRIPT_VERSION="v1.3.0-$(date '+%Y%m%d')"

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
# 重新拉取 Xray 配置并按需重启 — 解锁闭环的关键一步
#
# 背景 (2026-07 bug): unlockCheck 从 register 剥离为后台脚本后,
#   安装时 Step3_InstallXray 拉取的 config.json 生成于解锁数据上报之前,
#   面板 DB 虽随后被 unlock_check 更新, 但节点侧无人重新拉取配置,
#   导致 xray 永远运行在"无解锁版"配置上 (解锁路由/中转出站缺失)。
#
# 流程: POST /api/node/config (此刻面板已有最新 node_unlock)
#   → 校验 (HTTP 200 + 有效 JSON + xray -test 预检)
#   → 与 ~/config.json 比对, 无变化直接返回 (幂等, 不做无谓重启断连)
#   → 备份旧配置 → 落盘 ~/config.json + /usr/local/etc/xray/config.json
#   → systemctl restart xray (xray 不支持 SIGHUP, reload 等同杀进程)
#   → 健康验证 (轮询 is-active); 失败则回滚备份配置并再次 restart
# 容错: 任一步失败仅 log error 并保留现有配置在跑, 不影响上报结果;
#       供 Main 以 `|| true` 方式调用 (set -eu 安全)
# ============================================================
RefreshXrayConfig() {
    _home_conf="$HOME/config.json"
    _xray_conf_dir=/usr/local/etc/xray
    _xray_conf="${_xray_conf_dir}/config.json"
    _xray_bin=/usr/local/bin/xray

    # xray 未安装 (独立运行/安装前手动跑) → 无配置可刷新, 静默跳过
    if [ ! -d "$_xray_conf_dir" ] && [ ! -f "$_home_conf" ]; then
        log debug "xray 未安装 (无 ${_xray_conf_dir} 且无 ${_home_conf}), 跳过配置刷新"
        return 0
    fi

    # ---- 0. 安装器握手: proxyInstall.sh 仍在运行时, 等它完全退出再刷新 ----
    # why: 缓存命中的重装场景下本脚本约 1-3 秒即完成检测+上报, 若立刻刷新配置
    #      并 restart xray, 会撞上安装器收尾的"服务状态检查" (is-active 恰落在
    #      restart 窗口 → 误报 xray 异常 → Telegram 假警报)。等待后时序固定为
    #      确定性的"安装先完成, 刷新最后"; 等待发生在本后台进程内, 安装零延迟
    #      (fresh 安装时检测本身 1-3 分钟 > 安装器尾巴, 等待几乎总是 0 秒)。
    # 容错: 无标记 / PID 已死 (含安装器被 kill -9 后残留) / 超时 → 均立即继续;
    #       等待只是消除交叠, 不是刷新的前置条件 (安装器收尾本就不写 config/xray)
    # 可调: UC_INSTALLER_WAIT_MAX 覆盖等待上限秒数 (默认 120, 主要供测试)
    _inst_marker=/tmp/.nodehub_installer.running
    if [ -f "$_inst_marker" ]; then
        _inst_pid=$(cat "$_inst_marker" 2>/dev/null | tr -dc '0-9' || true)
        if [ -n "$_inst_pid" ] && kill -0 "$_inst_pid" 2>/dev/null; then
            _wait_max="${UC_INSTALLER_WAIT_MAX:-120}"
            log info "安装器仍在运行 (PID=${_inst_pid}), 等待其退出后再刷新 Xray 配置 (上限 ${_wait_max}s)..."
            _w=0
            while [ "$_w" -lt "$_wait_max" ]; do
                kill -0 "$_inst_pid" 2>/dev/null || break
                sleep 2
                _w=$((_w + 2))
            done
            if kill -0 "$_inst_pid" 2>/dev/null; then
                log warn "等待安装器退出超时 (${_wait_max}s), 继续刷新 (安装器收尾不写 config/xray, 竞态无害)"
            else
                log info "安装器已退出, 开始刷新 Xray 配置"
            fi
        fi
    fi

    log info "重新拉取 Xray 配置 (面板此刻已含最新解锁数据)"

    # ---- 1. 拉取 ----
    _resp=$(curl -sS --connect-timeout 15 --max-time 60 \
        --retry 3 --retry-delay 5 --retry-all-errors \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -X POST -d "node_id=${NODE_ID}" \
        -w "\n%{http_code}" \
        "${API_URL}/api/node/config") || true

    _http_code=$(printf '%s\n' "${_resp:-}" | tail -1)
    _body=$(printf '%s\n' "${_resp:-}" | sed '$d')

    case "$_http_code" in
        200) ;;
        *)
            log error "Xray 配置拉取失败: HTTP ${_http_code:-空} — $(printf '%s' "$_body" | head -c 200) (保留现有配置, 不重启)"
            return 1
            ;;
    esac

    if [ -z "$_body" ]; then
        log error "Xray 配置响应体为空 (HTTP ${_http_code}), 保留现有配置"
        return 1
    fi

    # ---- 2. 校验响应为有效 JSON (防错误页/脏数据覆盖在用配置) ----
    if command -v jq >/dev/null 2>&1; then
        if ! printf '%s' "$_body" | jq -e '.' >/dev/null 2>&1; then
            log error "Xray 配置响应非有效 JSON (前 200 字符: $(printf '%s' "$_body" | head -c 200)), 保留现有配置"
            return 1
        fi
    fi

    # ---- 3. 内容无变化 → 无需重启 (幂等, 避免无谓断连) ----
    # 比较: $() 会剥离两侧尾部换行, 与本函数 printf '%s\n' 落盘格式自洽
    _cur=""
    [ -f "$_home_conf" ] && _cur=$(cat "$_home_conf" 2>/dev/null || true)
    if [ "$_cur" = "$_body" ]; then
        log info "Xray 配置无变化, 跳过重启"
        return 0
    fi
    log info "检测到 Xray 配置变化 (${#_cur} → ${#_body} 字符), 准备更新"

    # ---- 4. xray -test 预检 (二进制存在时; 拦截面板下发的坏配置) ----
    _tmp_conf="/tmp/unlockCheck.config.$$.json"
    printf '%s\n' "$_body" > "$_tmp_conf" 2>/dev/null || {
        log error "新配置临时文件写入失败: ${_tmp_conf}"
        return 1
    }
    if [ -x "$_xray_bin" ]; then
        if ! "$_xray_bin" run -test -config "$_tmp_conf" >/dev/null 2>&1; then
            _test_err=$("$_xray_bin" run -test -config "$_tmp_conf" 2>&1 | head -c 300 || true)
            log error "新配置 xray -test 校验失败, 放弃更新 (保留现有配置): ${_test_err}"
            rm -f "$_tmp_conf"
            return 1
        fi
    fi

    # ---- 5. 备份旧配置 + 落盘 (~/config.json 与 xray 目录双写) ----
    _ts=$(date '+%Y%m%d%H%M%S')
    _backup=""
    if [ -f "$_home_conf" ]; then
        _backup="${_home_conf}.bak.${_ts}"
        cp -f "$_home_conf" "$_backup" 2>/dev/null || _backup=""
    fi

    mv -f "$_tmp_conf" "$_home_conf" 2>/dev/null || {
        log error "新配置写入 ${_home_conf} 失败"
        rm -f "$_tmp_conf"
        return 1
    }
    mkdir -p "$_xray_conf_dir"
    cp -f "$_home_conf" "$_xray_conf"
    log info "新配置已落盘: ${_home_conf} + ${_xray_conf}"

    # ---- 6. 重启 xray + 健康验证 ----
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service'; then
        :
    else
        log info "xray.service 未安装, 仅更新配置文件 (不重启)"
        return 0
    fi

    log info "重启 xray 以加载新配置..."
    if ! systemctl restart xray 2>/dev/null; then
        log error "systemctl restart xray 失败"
        _RollbackXrayConfig "$_backup" "$_xray_conf"
        return 1
    fi

    # 健康验证: 轮询 is-active (最多 8s)
    _i=0
    while [ "$_i" -lt 8 ]; do
        sleep 1
        _i=$((_i + 1))
        [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && break
    done
    if [ "$(systemctl is-active xray 2>/dev/null)" = "active" ]; then
        log info "✅ xray 已重启并加载含解锁路由的新配置 (等待 ${_i}s, active)"
        [ -n "$_backup" ] && rm -f "$_backup" 2>/dev/null || true
        return 0
    fi

    log error "xray 重启后健康验证失败 (is-active 非 active), 回滚旧配置"
    _RollbackXrayConfig "$_backup" "$_xray_conf"
    return 1
}

# 回滚旧配置并尽力拉起 xray — 供 RefreshXrayConfig 失败路径调用
# 用法: _RollbackXrayConfig <backup_file> <xray_conf_path>
_RollbackXrayConfig() {
    _rb_backup="$1"
    _rb_conf="$2"
    if [ -n "$_rb_backup" ] && [ -f "$_rb_backup" ]; then
        cp -f "$_rb_backup" "$_home_conf" 2>/dev/null || true
        cp -f "$_rb_backup" "$_rb_conf" 2>/dev/null || true
        systemctl restart xray 2>/dev/null || true
        log error "已回滚到备份配置并重启: ${_rb_backup}"
    else
        log error "无备份可回滚 (首次部署?), 保留新配置; 请手动检查: systemctl status xray"
    fi
    return 0
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
    # UC_REPORT_ONLY=1 (安装脚本 Step2.6 缓存命中时的同步补报模式):
    #   仅检测+上报, 不重拉配置不重启 — 此刻 xray 可能尚未安装, 配置将由
    #   安装脚本 Step3 一次性拉取, 避免同一安装周期 config.json 拉两遍
    if [ "${UC_REPORT_ONLY:-0}" = "1" ]; then
        log info "UC_REPORT_ONLY=1 — 仅上报模式, 跳过配置刷新 (由安装脚本统一拉取)"
    else
        # 解锁闭环: 上报后面板才有 node_unlock, 必须重拉 config.json 才能让
        # 解锁路由/出站真正落到节点; 失败不影响上报结果 (内部已 log error)
        RefreshXrayConfig || true
    fi
    log info "===== unlockCheck.sh 完成 ====="
}

Main "$@"
