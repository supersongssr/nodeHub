#!/usr/bin/env bats
# ============================================================
# test_node_agent_port_block.bats — DailyPortBlockCheck 端口被墙自愈测试
# 覆盖 (对应审查需求):
#   T1. 超过 24 小时 (冷却期满) → 自动换端口重装; 冷却期内 → 不重装
#   T2. 各分支 Telegram 通知发送/抑制 (blocked+xcport / ip_blocked / 未被墙)
#   T3. 新端口必须是从未被占用过的端口 (避开历史 portswap.log / 当前端口 / hop 区间)
# 附带:
#   T4. 状态机: done 跨天清零 (昨日 done 不吞今日重试) / attempts≥3 止损 / 定论后当日收工
#   T5. proxyDiagnose --no-notify 转发 (本地 + --host 远程 ssh 命令行)
#
# 隔离: HOME=mktemp 目录; wget/curl/awk(随机桩)/ssh 均用 stub, 不访问网络
# ============================================================

load 'test_helper'

AGENT_SRC="${PROJECT_ROOT}/nodeAgent.sh"
DIAG_SRC="${PROJECT_ROOT}/proxyDiagnose.sh"
STUB_BIN=""      # 注入 PATH 的 stub bin
FIXTURE=""       # wget stub 的"源站"
TG_LOG=""        # curl stub 记录的 TG 调用
DIAG_ARGS=""     # 诊断 stub 记录的 argv (每次一行)
INSTALL_LOG=""   # 安装 stub 记录的 NODE_PORT
WRAPPER=""       # 加载被测函数的包装脚本

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="${TEST_TMPDIR}"
    STUB_BIN="${TEST_TMPDIR}/bin";  mkdir -p "$STUB_BIN"
    FIXTURE="${TEST_TMPDIR}/srv";   mkdir -p "$FIXTURE"
    TG_LOG="${TEST_TMPDIR}/tg.log"
    DIAG_ARGS="${TEST_TMPDIR}/diag.args"
    INSTALL_LOG="${TEST_TMPDIR}/install.log"

    # ---- 被测函数库: nodeAgent.sh 去掉末尾 Main 调用 ----
    sed 's/^Main "\$@"$/: # Main disabled for test/' "$AGENT_SRC" > "${TEST_TMPDIR}/agent.lib.sh"
    WRAPPER="${TEST_TMPDIR}/runcheck.sh"
    cat > "$WRAPPER" <<'EOF'
#!/bin/sh
. "$1"
DailyPortBlockCheck
_rc=$?
trap - EXIT   # 清除 nodeAgent 的 OnError EXIT trap, 避免正常退出误报
exit $_rc
EOF

    # ---- 通用环境: 关节流 / 桩 token / 恒过小时窗口 ----
    export TG_NOTIFY_THROTTLE=0
    export TELEGRAM_BOT_TOKEN="test-token"
    export TELEGRAM_CHAT_ID="test-chat"
    export NODE_PORT_CHECK_HOUR=0
    export NODEHUB_URL="http://stub.local"
    export node_id="test-001"
    # stub 配置必须 export: stub 脚本在子进程里读取
    export TG_LOG DIAG_ARGS INSTALL_LOG FIXTURE
    export PATH="${STUB_BIN}:${PATH}"

    # ---- curl stub: 记录 TG 调用参数 ----
    cat > "${STUB_BIN}/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "=== curl invoke ===" >> "${TG_LOG:?}"
printf '%s\n' "$*" >> "${TG_LOG:?}"
exit 0
EOF
    chmod +x "${STUB_BIN}/curl"

    # ---- wget stub: 从"源站" FIXTURE 复制到 cwd (模拟下载) ----
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
cp "${FIXTURE}/${_base}" "./${_base}" || exit 1
exit 0
EOF
    chmod +x "${STUB_BIN}/wget"

    # ---- 诊断 stub: 记录 argv + 输出可配置 JSON ----
    cat > "${FIXTURE}/proxyDiagnose.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${DIAG_ARGS:?}"
[ -n "${STUB_DIAG_JSON:-}" ] && [ -f "$STUB_DIAG_JSON" ] && cat "$STUB_DIAG_JSON"
exit 0
EOF

    # ---- 安装 stub: 记录 NODE_PORT 并写入 node.json (模拟面板回传) ----
    cat > "${FIXTURE}/proxyInstall.sh" <<'EOF'
#!/bin/sh
echo "NODE_PORT=${NODE_PORT:-}" >> "${INSTALL_LOG:?}"
if [ "${STUB_INSTALL_FAIL:-0}" = "1" ]; then exit 1; fi
jq -n --argjson p "${NODE_PORT:-0}" '{node_id:"test-001", node_port:$p}' > "${HOME:?}/node.json"
exit 0
EOF

    # ---- 初始节点: node.json 端口 443 ----
    echo '{"node_id":"test-001","node_port":443}' > "${HOME}/node.json"

    # 清理上次测试可能遗留的 /tmp 固定路径文件 (nodeAgent 硬编码 /tmp)
    rm -f /tmp/proxyDiagnose.sh /tmp/proxyInstall.sh
}

teardown() {
    rm -f /tmp/proxyDiagnose.sh /tmp/proxyInstall.sh
    [ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

# ---- 辅助: 生成诊断 JSON ----
diag_json() { # <blocked:0|1> <xc: none|port|ip>
    local blocked="$1" xc="$2"
    local results=""
    [ "$blocked" = "1" ] && results='{"level":"FAIL","code":"NODE_PORT_CN_BLOCKED","title":"NODE_PORT=443 三网+云厂全断, 海外正常","detail":"tcp.ping.pe 全超时"},'
    case "$xc" in
        port) results="${results}{\"level\":\"PASS\",\"code\":\"NODE_PORT_CN_XCHECK_PORT\",\"title\":\"交叉验证: 属【端口级被墙】— 新端口大陆可达\",\"detail\":\"ok\"}" ;;
        ip)   results="${results}{\"level\":\"FAIL\",\"code\":\"NODE_PORT_CN_IP_BLOCKED\",\"title\":\"交叉验证: 属【IP 级被墙】\",\"detail\":\"bad\"}" ;;
    esac
    printf '{"target":"net","totals":{"pass":1,"warn":0,"fail":1},"results":[%s]}' "${results%,}"
}

# ---- 辅助: 运行被测函数 ----
run_check() {
    STUB_DIAG_JSON="${TEST_TMPDIR}/diag.json" run sh "$WRAPPER" "${TEST_TMPDIR}/agent.lib.sh"
}

# ---- 辅助: 写状态文件 ----
set_state() { # <date> <attempts> <done> <last_swap>
    {   echo "date=$1"
        echo "attempts=$2"
        echo "done=$3"
        echo "last_swap=$4"
    } > "${HOME}/nodeAgent.portcheck.state"
}

now() { date +%s; }
today() { date '+%Y%m%d'; }
yesterday() { date -d 'yesterday' '+%Y%m%d' 2>/dev/null || date -v-1d '+%Y%m%d'; }

# ============================================================
# T1: 超过 24 小时 (冷却期满) → 自动换端口
# ============================================================

@test "T1a: 距上次换端口 25h (>24h, 冷却默认 20h 已过) → 自动重装换端口" {
    diag_json 1 port > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 "$(( $(now) - 90000 ))"   # 25h 前

    run_check
    [ "$status" -eq 0 ]

    # 重装发生: 安装 stub 被调用且带新端口
    [ -f "$INSTALL_LOG" ]
    grep -q '^NODE_PORT=[0-9]\{5\}$' "$INSTALL_LOG"
    local new_port; new_port=$(sed -n 's/^NODE_PORT=//p' "$INSTALL_LOG" | tail -1)

    # 新端口合法性: 20000-60000, 非旧端口 443, 避开 hy2 port-hop 30000-32000
    [ "$new_port" -ge 20000 ]
    [ "$new_port" -le 60000 ]
    [ "$new_port" -ne 443 ]
    ! { [ "$new_port" -ge 30000 ] && [ "$new_port" -le 32000 ]; }

    # node.json 已换成新端口; portswap.log 记录 443 -> 新端口
    [ "$(jq -r .node_port "${HOME}/node.json")" = "$new_port" ]
    grep -q "换端口 443 -> ${new_port} (请求随机 ${new_port}) 重装=1" "${HOME}/nodeAgent.portswap.log"

    # 状态推进: done=1, last_swap 更新为今天
    grep -q '^done=1$' "${HOME}/nodeAgent.portcheck.state"
    local ls; ls=$(sed -n 's/^last_swap=//p' "${HOME}/nodeAgent.portcheck.state")
    [ $(( $(now) - ls )) -lt 60 ]
}

@test "T1b: 距上次换端口仅 1h (冷却期内) → 不重装, 通知冷却期" {
    diag_json 1 port > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 "$(( $(now) - 3600 ))"

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$INSTALL_LOG" ]                       # 未重装
    [ "$(jq -r .node_port "${HOME}/node.json")" = "443" ]  # 端口未变
    [ ! -f "${HOME}/nodeAgent.portswap.log" ]
    grep -q "冷却期" "$TG_LOG"                     # TG 说明处于冷却期
    grep -q '^done=1$' "${HOME}/nodeAgent.portcheck.state"
}

@test "T1c: 冷却边界 — 恰过 20h 冷却 → 允许重装" {
    diag_json 1 port > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 "$(( $(now) - 72100 ))"   # 20h+100s

    run_check
    [ "$status" -eq 0 ]
    [ -f "$INSTALL_LOG" ]
    grep -q '重装=1' "${HOME}/nodeAgent.portswap.log"
}

@test "T1d: 重装失败 (proxyInstall 返回非零) → 端口不变, TG 通知失败, 不崩溃" {
    diag_json 1 port > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 0
    export STUB_INSTALL_FAIL=1

    run_check
    [ "$status" -eq 0 ]
    [ -f "$INSTALL_LOG" ]
    [ "$(jq -r .node_port "${HOME}/node.json")" = "443" ]
    grep -q "重装=0" "${HOME}/nodeAgent.portswap.log"
    grep -q "❌ 失败" "$TG_LOG"
}

# ============================================================
# T2: Telegram 通知
# ============================================================

@test "T2a: 端口被墙+IP未被墙+重装 → TG 通知含被墙情况/交叉验证/旧→新端口" {
    diag_json 1 port > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 "$(( $(now) - 90000 ))"

    run_check
    [ "$status" -eq 0 ]
    grep -q "端口被墙检测与自动处置" "$TG_LOG"
    grep -q "三网+云厂全断" "$TG_LOG"
    grep -q "交叉验证: 随机新端口大陆可达" "$TG_LOG"
    grep -q "已自动重装 proxyInstall.sh, 端口 443 → " "$TG_LOG"
    grep -q "✅ 成功" "$TG_LOG"
    # 发往 Telegram API 且带 chat_id
    grep -q "api.telegram.org/bottest-token/sendMessage" "$TG_LOG"
    grep -q "chat_id=test-chat" "$TG_LOG"
}

@test "T2b: IP 级被墙 → TG 通知『IP 级被墙/未自动重装』, 不重装" {
    diag_json 1 ip > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 0

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$INSTALL_LOG" ]
    [ ! -f "${HOME}/nodeAgent.portswap.log" ]
    grep -q "IP 级被墙" "$TG_LOG"
    grep -q "未自动重装 (换端口无效)" "$TG_LOG"
    grep -q '^done=1$' "${HOME}/nodeAgent.portcheck.state"
}

@test "T2c: 三网全断但交叉验证无定论 → TG 通知且不重装, 当日可重试" {
    diag_json 1 none > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 0

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$INSTALL_LOG" ]
    grep -q "未能确认端口级封锁" "$TG_LOG"
    grep -q "未自动重装" "$TG_LOG"
    # 无定论不当日收工: done 仍为 0, 下个小时可重试
    ! grep -q '^done=1$' "${HOME}/nodeAgent.portcheck.state"
}

@test "T2d: 未被墙 → 不发 TG, 当日收工 (done=1)" {
    diag_json 0 none > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 0

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$TG_LOG" ]                            # 静默: 未被墙不推送
    [ ! -f "$INSTALL_LOG" ]
    grep -q '^done=1$' "${HOME}/nodeAgent.portcheck.state"
}

@test "T2e: TG 未配置 token → 静默跳过, 不影响处置 (换端口照常)" {
    unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
    diag_json 1 port > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 "$(( $(now) - 90000 ))"

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$TG_LOG" ]
    [ -f "$INSTALL_LOG" ]                          # 处置不受影响
    grep -q '重装=1' "${HOME}/nodeAgent.portswap.log"
}

# ============================================================
# T3: 新端口必须是从未被占用过的端口
# ============================================================

@test "T3a: _PbcRandomPort 避开历史已用端口 (portswap.log 拉黑) — 确定性桩" {
    # 历史已用: 25000 / 25123; 当前端口: 25123
    cat > "${HOME}/nodeAgent.portswap.log" <<'EOF'
2026-08-30 05:00:00 换端口 443 -> 25000 (请求随机 25000) 重装=1
2026-08-31 05:00:00 换端口 25000 -> 25123 (请求随机 25123) 重装=1
EOF

    # awk 桩: 按序吐出 当前端口→hop区间→历史端口→全新端口, 验证逐一被跳过
    local seqf="${TEST_TMPDIR}/awk.seq"
    cat > "${STUB_BIN}/awk" <<EOF
#!/bin/sh
case "\$*" in
  *srand*)
    _n=\$(cat "${seqf}" 2>/dev/null || echo 0); _n=\$((_n + 1)); echo "\$_n" > "${seqf}"
    case "\$_n" in
      1) echo 25123 ;;   # 当前端口 (avoid)
      2) echo 31000 ;;   # hy2 port-hop 区间
      3) echo 25000 ;;   # 历史已用端口 ← 修复前会命中这里 (bug)
      4) echo 47891 ;;   # ✓ 全新端口
      *) echo 47892 ;;
    esac
    exit 0 ;;
  *) exec /usr/bin/awk "\$@" ;;
esac
EOF
    chmod +x "${STUB_BIN}/awk"

    run sh -c ". '${TEST_TMPDIR}/agent.lib.sh'; trap - EXIT; _PbcRandomPort 25123"
    [ "$status" -eq 0 ]
    [ "$output" = "47891" ]                       # 前三个候选全部被正确跳过
}

@test "T3b: 历史端口全部撞车 (30 次均冲突) → 放弃并返回失败" {
    cat > "${HOME}/nodeAgent.portswap.log" <<'EOF'
2026-08-30 05:00:00 换端口 443 -> 25000 (请求随机 25000) 重装=1
EOF
    # awk 桩: 恒吐历史端口 25000 → 30 次全冲突
    cat > "${STUB_BIN}/awk" <<'EOF'
#!/bin/sh
case "$*" in
  *srand*) echo 25000; exit 0 ;;
  *) exec /usr/bin/awk "$@" ;;
esac
EOF
    chmod +x "${STUB_BIN}/awk"

    run sh -c ". '${TEST_TMPDIR}/agent.lib.sh'; trap - EXIT; _PbcRandomPort 443"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "T3c: 集成 — 换出的新端口不在历史已用集合 ∪ {旧端口} 中" {
    # 预置历史: 443 -> 23456 -> 24567
    cat > "${HOME}/nodeAgent.portswap.log" <<'EOF'
2026-08-29 05:00:00 换端口 443 -> 23456 (请求随机 23456) 重装=1
2026-08-30 05:00:00 换端口 23456 -> 24567 (请求随机 24567) 重装=1
EOF
    echo '{"node_id":"test-001","node_port":24567}' > "${HOME}/node.json"
    diag_json 1 port > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 "$(( $(now) - 90000 ))"

    run_check
    [ "$status" -eq 0 ]
    local new_port; new_port=$(sed -n 's/^NODE_PORT=//p' "$INSTALL_LOG" | tail -1)
    [ -n "$new_port" ]
    [ "$new_port" != "23456" ]
    [ "$new_port" != "24567" ]
    [ "$new_port" != "443" ]
    # 历史文件追加了一行, 且新端口对全部历史唯一
    [ "$(wc -l < "${HOME}/nodeAgent.portswap.log")" -eq 3 ]
    [ "$(grep -oE '[0-9]{5}' "${HOME}/nodeAgent.portswap.log" | sort -u | grep -cx "$new_port")" -eq 1 ]
}

# ============================================================
# T4: 状态机
# ============================================================

@test "T4a: 昨日 done=1 不吞今日重试 (跨天清零) — 无定论后同日可再跑" {
    # 诊断桩输出损坏 JSON → 无定论
    echo 'not a json' > "${TEST_TMPDIR}/diag.json"
    set_state "$(yesterday)" 3 1 0                 # 昨天: 已跑满 + 已定论

    run_check                                       # 今日首跑 (跨天)
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$DIAG_ARGS")" -eq 1 ]            # 诊断确实跑了
    ! grep -q '^done=1$' "${HOME}/nodeAgent.portcheck.state"

    run_check                                       # 今日第 2 跑: 应重试而非被昨日 done 吞掉
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$DIAG_ARGS")" -eq 2 ]            # ★ 修复前此处只有 1 次
    grep -q '^attempts=2$' "${HOME}/nodeAgent.portcheck.state"
}

@test "T4b: 当日 attempts≥3 → 止损不再跑" {
    diag_json 1 none > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 3 0 0

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$DIAG_ARGS" ]                          # 未执行诊断
    [ ! -f "$TG_LOG" ]
}

@test "T4c: 当日已有定论 (done=1) → 不再跑" {
    diag_json 0 none > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 1 0

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$DIAG_ARGS" ]
}

@test "T4d: NODE_PORT_BLOCK_CHECK=0 总开关关闭" {
    diag_json 1 port > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 0
    export NODE_PORT_BLOCK_CHECK=0

    run_check
    [ "$status" -eq 0 ]
    [ ! -f "$DIAG_ARGS" ]
    [ ! -f "$TG_LOG" ]
}

@test "T4e: nodeAgent 调用诊断时带 --no-notify (防双重 TG) + --json + --target net" {
    diag_json 0 none > "${TEST_TMPDIR}/diag.json"
    set_state "$(today)" 1 0 0

    run_check
    [ "$status" -eq 0 ]
    grep -q -- '--target net --json --quiet --no-notify' "$DIAG_ARGS"
}

# ============================================================
# T5: proxyDiagnose --no-notify
# ============================================================

@test "T5a: --host 远程模式 ssh 命令转发 --no-notify" {
    # ssh 桩: 记录命令行后成功退出 (不真正连接)
    local sshlog="${TEST_TMPDIR}/ssh.log"
    cat > "${STUB_BIN}/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${sshlog}"
exit 0
EOF
    chmod +x "${STUB_BIN}/ssh"

    run sh "$DIAG_SRC" --host "root@1.2.3.4" --target net --json --no-notify
    [ "$status" -eq 0 ]
    grep -q -- "--target 'net'" "$sshlog"
    grep -q -- "--json" "$sshlog"
    grep -q -- "--no-notify" "$sshlog"             # ★ 修复前缺失
}

@test "T5b: --host 远程模式未传 --no-notify 时不转发该旗标" {
    local sshlog="${TEST_TMPDIR}/ssh.log"
    cat > "${STUB_BIN}/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${sshlog}"
exit 0
EOF
    chmod +x "${STUB_BIN}/ssh"

    run sh "$DIAG_SRC" --host "root@1.2.3.4" --target net
    [ "$status" -eq 0 ]
    ! grep -q -- "--no-notify" "$sshlog"
}
