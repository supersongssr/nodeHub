#!/usr/bin/env bats
# ============================================================
# test_node_agent_tcping_notify.bats — TcpingPortCheck TG 通知口径测试
# 覆盖 (CDN 过滤 + 解封通知, 与监控侧 "非CDN在线节点才判被墙 / CDN 只判解封" 口径对齐):
#   T1. 非 CDN (vision) + blocked → 发被墙通知 (回归)
#   T2. CDN (xhttp-cdn / xhttp-cdn-hy2) + blocked → 不发被墙 TG (已知被墙);
#       检测留档与 state 照常写入 (推送路径不受影响)
#   T3. CDN + 大陆恢复可达 → 发一次解封通知 (提示换回直连); 持续可达不重发
#   T4. 非 CDN + prev=blocked → ok → 发普通恢复通知 (非解封文案, 回归)
#   T5. CDN + unreachable → 不发 TG
#
# 隔离: HOME=mktemp 目录; curl (TG) / wget (tcpingCheck.py) 用 stub, 不访问网络;
#       tcpingCheck.py 桩 = 输出环境变量 STUB_TCPING_JSON 指定的 JSON 文件
# ============================================================

load 'test_helper'

AGENT_SRC="${PROJECT_ROOT}/nodeAgent.sh"
STUB_BIN=""
FIXTURE=""       # wget stub 的"源站"
TG_LOG=""        # curl stub 记录的 Telegram 调用
STUB_PY=""       # tcpingCheck.py 桩
WRAPPER=""

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="${TEST_TMPDIR}"
    STUB_BIN="${TEST_TMPDIR}/bin";  mkdir -p "$STUB_BIN"
    FIXTURE="${TEST_TMPDIR}/srv";   mkdir -p "$FIXTURE"
    TG_LOG="${TEST_TMPDIR}/tg.log"
    STUB_PY="${TEST_TMPDIR}/tcping.json"

    # ---- 被测函数库: nodeAgent.sh 去掉末尾 Main 调用 ----
    sed 's/^Main "\$@"$/: # Main disabled for test/' "$AGENT_SRC" > "${TEST_TMPDIR}/agent.lib.sh"
    WRAPPER="${TEST_TMPDIR}/runcheck.sh"
    cat > "$WRAPPER" <<'EOF'
#!/bin/sh
. "$1"
TcpingPortCheck
_rc=$?
trap - EXIT   # 清除 nodeAgent 的 OnError EXIT trap, 避免正常退出误报
exit $_rc
EOF

    # ---- 通用环境: 关节流 / 桩 token / 关推送 (推送逻辑不在本测试范围) ----
    export TG_NOTIFY_THROTTLE=0
    export TELEGRAM_BOT_TOKEN="test-token"
    export TELEGRAM_CHAT_ID="test-chat"
    export TCPING_PUSH=0
    export NODEHUB_URL="http://stub.local"
    export node_id="test-001"
    export STUB_TCPING_JSON="$STUB_PY"
    # stub 脚本在子进程里读取, 必须 export
    export TG_LOG FIXTURE
    export PATH="${STUB_BIN}:${PATH}"

    # ---- curl stub: 只记录 Telegram 调用 (推送已关, 不应有其他 curl) ----
    cat > "${STUB_BIN}/curl" <<'EOF'
#!/bin/sh
case "$*" in
    *api.telegram.org*)
        printf '%s\n' "=== curl invoke ===" >> "${TG_LOG:?}"
        printf '%s\n' "$*" >> "${TG_LOG:?}"
        ;;
esac
exit 0
EOF
    chmod +x "${STUB_BIN}/curl"

    # ---- wget stub: 从"源站" FIXTURE 复制 tcpingCheck.py 到 cwd ----
    cat > "${STUB_BIN}/wget" <<'EOF'
#!/bin/sh
_url=""; _prev=""
for _a in "$@"; do
    case "$_prev" in -O) _url=""; _prev=""; continue ;; esac
    case "$_a" in -*) ;; *) _url="$_a" ;; esac
    _prev="$_a"
done
_base="${_url##*/}"
[ -z "$_base" ] && exit 1
[ -f "${FIXTURE:?}/${_base}" ] || exit 1
cp "${FIXTURE:?}/${_base}" "./${_base}" || exit 1
exit 0
EOF
    chmod +x "${STUB_BIN}/wget"

    # ---- tcpingCheck.py 桩: 合法 python, 输出 STUB_TCPING_JSON 文件内容 ----
    cat > "${FIXTURE}/tcpingCheck.py" <<'EOF'
import os, sys
_p = os.environ.get("STUB_TCPING_JSON", "")
sys.stdout.write(open(_p, encoding="utf-8").read() if _p and os.path.exists(_p) else "")
EOF

    # ---- 初始节点: node.json 端口 443 (v2_name 由各用例写入) ----
    echo '{"node_id":"test-001","node_port":443}' > "${HOME}/node.json"

    # 清理上次测试可能遗留的 /tmp 固定路径文件 (nodeAgent 硬编码 cd /tmp && wget)
    rm -f /tmp/tcpingCheck.py
}

teardown() {
    rm -f /tmp/tcpingCheck.py
    [ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

# ---- 辅助: 写 v2_name 到 node.json ----
set_v2name() { # <v2_name>
    jq --arg v "$1" '. + {v2_name:$v}' "${HOME}/node.json" > "${HOME}/node.json.tmp" \
        && mv "${HOME}/node.json.tmp" "${HOME}/node.json"
}

# ---- 辅助: 生成检测 JSON ----
tcping_json() { # <status> <block_level>
    local status="$1" level="${2:-none}"
    local ct cu cm
    if [ "$status" = "blocked" ] || [ "$status" = "unreachable" ]; then
        ct='{"ok":0,"total":2}'; cu='{"ok":0,"total":2}'; cm='{"ok":0,"total":2}'
        [ "$status" = "unreachable" ] && cm="$cm"
    else
        ct='{"ok":2,"total":2}'; cu='{"ok":2,"total":2}'; cm='{"ok":2,"total":2}'
    fi
    local os_g='{"ok":2,"total":2}'
    if [ "$status" = "unreachable" ]; then os_g='{"ok":0,"total":2}'; fi
    printf '{"status":"%s","block_level":"%s","ip":"203.0.113.10","port":443,"groups":{"ct":%s,"cu":%s,"cm":%s,"vendor":{"ok":0,"total":2},"os":%s}}' \
        "$status" "$level" "$ct" "$cu" "$cm" "$os_g"
}

# ---- 辅助: 运行被测函数 ----
run_check() {
    run sh "$WRAPPER" "${TEST_TMPDIR}/agent.lib.sh"
}

# ---- 辅助: 预置检测状态 ----
set_state() { # <last_status>
    echo "last_status=$1" > "${HOME}/nodeAgent.portcheck.state"
}

tg_count() { # TG 调用次数
    [ -f "$TG_LOG" ] && grep -c "api.telegram.org" "$TG_LOG" || echo 0
}

# ============================================================
# T1: 非 CDN + blocked → 发被墙通知 (回归)
# ============================================================

@test "T1: vision 节点 blocked(port级) → TG 发被墙通知 (回归)" {
    set_v2name "vision"
    tcping_json blocked port > "$STUB_PY"

    run_check
    [ "$status" -eq 0 ]
    [ "$(tg_count)" -eq 1 ]
    grep -q "端口被墙检测" "$TG_LOG"
    grep -q "■ 被墙情况" "$TG_LOG"
    grep -q "端口级封锁" "$TG_LOG"
    # 状态推进
    [ "$(grep -E '^last_status=' "${HOME}/nodeAgent.portcheck.state" | tail -1)" = "last_status=blocked" ]
}

# ============================================================
# T2: CDN 模式 + blocked → 不发被墙 TG
# ============================================================

@test "T2a: xhttp-cdn 节点 blocked → 不发被墙 TG (已知被墙), 留档与 state 照常" {
    set_v2name "xhttp-cdn"
    tcping_json blocked ip > "$STUB_PY"

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$TG_LOG" ]                            # 静默: CDN 模式不发被墙通知
    # 检测留档 + 状态照常 (下周期解封判定依赖 state)
    [ -f "${HOME}/nodeAgent.tcping.log" ]
    grep -q "status=blocked" "${HOME}/nodeAgent.tcping.log"
    [ "$(grep -E '^last_status=' "${HOME}/nodeAgent.portcheck.state" | tail -1)" = "last_status=blocked" ]
}

@test "T2b: xhttp-cdn-hy2 变体 blocked → 同样不发 TG" {
    set_v2name "xhttp-cdn-hy2"
    tcping_json blocked port > "$STUB_PY"

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$TG_LOG" ]
}

@test "T2c: CDN 节点持续 blocked (第二周期) → 仍静默" {
    set_v2name "xhttp-cdn"
    tcping_json blocked ip > "$STUB_PY"
    set_state blocked

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$TG_LOG" ]
}

# ============================================================
# T3: CDN + 大陆恢复可达 → 解封通知 (发一次, 不重复)
# ============================================================

@test "T3a: CDN 节点首次检测即 ok → 发解封通知 (提示换回直连)" {
    set_v2name "xhttp-cdn"
    tcping_json ok > "$STUB_PY"

    run_check
    [ "$status" -eq 0 ]
    [ "$(tg_count)" -eq 1 ]
    grep -q "疑似解封" "$TG_LOG"
    grep -q "CDN 模式" "$TG_LOG"
    grep -q "换回直连" "$TG_LOG"
    grep -q "v2_name=xhttp-cdn" "$TG_LOG"
}

@test "T3b: CDN 节点 blocked → ok → 发解封通知, state 推进 ok" {
    set_v2name "xhttp-cdn-hy2"
    tcping_json ok > "$STUB_PY"
    set_state blocked

    run_check
    [ "$status" -eq 0 ]
    [ "$(tg_count)" -eq 1 ]
    grep -q "疑似解封" "$TG_LOG"
    grep -q "v2_name=xhttp-cdn-hy2" "$TG_LOG"
    [ "$(grep -E '^last_status=' "${HOME}/nodeAgent.portcheck.state" | tail -1)" = "last_status=ok" ]
}

@test "T3c: CDN 节点连续两周期 ok → 解封通知只发一次" {
    set_v2name "xhttp-cdn"
    tcping_json ok > "$STUB_PY"

    run_check                                        # 第 1 周期: 首次 ok → 发
    [ "$status" -eq 0 ]
    [ "$(tg_count)" -eq 1 ]

    run_check                                        # 第 2 周期: 持续 ok → 不重发
    [ "$status" -eq 0 ]
    [ "$(tg_count)" -eq 1 ]
}

# ============================================================
# T4: 非 CDN + 恢复 → 普通恢复通知 (回归)
# ============================================================

@test "T4: vision 节点 blocked → ok → 发普通恢复通知 (非解封文案)" {
    set_v2name "vision"
    tcping_json ok > "$STUB_PY"
    set_state blocked

    run_check
    [ "$status" -eq 0 ]
    [ "$(tg_count)" -eq 1 ]
    grep -q "✅ 端口恢复" "$TG_LOG"
    ! grep -q "疑似解封" "$TG_LOG"
}

@test "T4b: vision 节点首次检测 ok (从未 blocked) → 不发 TG (回归)" {
    set_v2name "vision"
    tcping_json ok > "$STUB_PY"

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$TG_LOG" ]
}

# ============================================================
# T5: CDN + unreachable → 不发 TG
# ============================================================

@test "T5: CDN 节点 unreachable (全球不可达) → 不发 TG" {
    set_v2name "xhttp-cdn"
    tcping_json unreachable > "$STUB_PY"

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$TG_LOG" ]
}
