#!/usr/bin/env bats
# ============================================================
# test_node_agent_tcping_push.bats — 推送安全门禁 + NODEHUB_URL 传输安全测试
# 覆盖 (2026-09-20 复审 fix 回归):
#   T1.  TLS 证书校验失败 (curl 60) → 门禁拒推 + TG 告警一次, 确定性失败不重试
#   T1b. wget 5 (SSL 校验失败, curl 不可用) → 同样映射为 TLS 门禁 (rc=2)
#   T2.  持续 TLS 校验失败 (第二周期) → 不重复告警 (last_push_gate 去重)
#   T3.  TLS 失败后推送成功 → 门禁清除 + 恢复 TG 一次
#   T4.  一般网络失败 (curl 7) → 重试一次后失败返回, 不设门禁/不发 TG
#   T5.  前置门禁回归: MONITOR_URL 非 https → 拒推 + TG 一次
#   T6.  LoadEnv NODEHUB_URL: 无 scheme 自动补全 https:// + warn(TG) 一次;
#        持续失配不重复告警; 显式 http:// 仅告警不强改; 恢复 https 后清标记
#
# 隔离: HOME=mktemp 目录; curl (推送+TG) / wget / sleep 用 stub, 不访问网络;
#       CA 走 MONITOR_CA 指向 fixture PEM (真实 _MonitorCaFile 校验路径)
# ============================================================

load 'test_helper'

AGENT_SRC="${PROJECT_ROOT}/nodeAgent.sh"
STUB_BIN=""
TG_LOG=""        # curl stub 记录的 Telegram 调用
PUSH_LOG=""      # curl/wget stub 记录的推送调用
CA_PEM=""
WRAP_PUSH=""
WRAP_ENV=""

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="${TEST_TMPDIR}"
    STUB_BIN="${TEST_TMPDIR}/bin"; mkdir -p "$STUB_BIN"
    TG_LOG="${TEST_TMPDIR}/tg.log"
    PUSH_LOG="${TEST_TMPDIR}/push.log"
    CA_PEM="${TEST_TMPDIR}/monitor-ca.pem"

    # ---- 被测函数库: nodeAgent.sh 去掉末尾 Main 调用 ----
    sed 's/^Main "\$@"$/: # Main disabled for test/' "$AGENT_SRC" > "${TEST_TMPDIR}/agent.lib.sh"

    # ---- 通用环境: 关节流 / 桩 token / 推送必配三键 ----
    export TG_NOTIFY_THROTTLE=0
    export TELEGRAM_BOT_TOKEN="test-token"
    export TELEGRAM_CHAT_ID="test-chat"
    export TCPING_PUSH=1
    export MONITOR_URL="https://monitor.stub:8443"
    export MONITOR_KEY="ssr_live_test"
    export MONITOR_CA="$CA_PEM"
    export NODEHUB_URL="https://hub.stub.local"
    export node_id="test-001"
    export STUB_PUSH_RC="0"
    export TG_LOG PUSH_LOG
    export PATH="${STUB_BIN}:${PATH}"

    # ---- CA fixture: 首行 PEM 头 (通过 _MonitorCaFile 真实校验) ----
    printf -- '-----BEGIN CERTIFICATE-----\nFAKECA\n-----END CERTIFICATE-----\n' > "$CA_PEM"

    # ---- curl stub: TG 调用记 TG_LOG; 推送调用按 STUB_PUSH_RC 模拟结果 ----
    cat > "${STUB_BIN}/curl" <<'EOF'
#!/bin/sh
case "$*" in
    *api.telegram.org*)
        printf '%s\n' "$*" >> "${TG_LOG:?}"
        exit 0
        ;;
esac
printf 'PUSH\n' >> "${PUSH_LOG:?}"
case "${STUB_PUSH_RC:-0}" in
    0) printf '{"ok":true,"deduped":false}'; exit 0 ;;
    *) exit "${STUB_PUSH_RC}" ;;
esac
EOF
    chmod +x "${STUB_BIN}/curl"

    # ---- wget stub (T1b curl 不可用时走此分支) ----
    cat > "${STUB_BIN}/wget" <<'EOF'
#!/bin/sh
printf 'PUSH\n' >> "${PUSH_LOG:?}"
case "${STUB_PUSH_RC:-0}" in
    0) printf '{"ok":true}'; exit 0 ;;
    *) exit "${STUB_PUSH_RC}" ;;
esac
EOF
    chmod +x "${STUB_BIN}/wget"

    # ---- sleep stub: 重试等待不拖慢测试 ----
    printf '#!/bin/sh\nexit 0\n' > "${STUB_BIN}/sleep"
    chmod +x "${STUB_BIN}/sleep"

    # ---- wrapper: 调 _TcpingPush (stderr 的彩色日志丢弃, 只断言 stdout/rc) ----
    WRAP_PUSH="${TEST_TMPDIR}/runpush.sh"
    cat > "$WRAP_PUSH" <<'EOF'
#!/bin/sh
. "$1"
_json='{"status":"ok","ip":"203.0.113.10","port":443}'
_rc=0
_TcpingPush "$_json" || _rc=$?
trap - EXIT
exit $_rc
EOF

    # ---- wrapper: 调 LoadEnv 后回显 NODEHUB_URL ----
    WRAP_ENV="${TEST_TMPDIR}/runenv.sh"
    cat > "$WRAP_ENV" <<'EOF'
#!/bin/sh
. "$1"
_rc=0
LoadEnv || _rc=$?
printf 'NODEHUB_URL=%s\n' "${NODEHUB_URL:-}"
trap - EXIT
exit $_rc
EOF

    # 清理 /tmp 固定路径残留 (T1b 依赖 /tmp/monitor-ca.pem fixture)
    rm -f /tmp/monitor-ca.pem
}

teardown() {
    rm -f /tmp/monitor-ca.pem
    [ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

# ---- 辅助 ----
run_push() { run sh "$WRAP_PUSH" "${TEST_TMPDIR}/agent.lib.sh" 2>/dev/null; }
run_env()  { run sh "$WRAP_ENV"  "${TEST_TMPDIR}/agent.lib.sh" 2>/dev/null; }

gate_state() {
    grep -E '^last_push_gate=' "${HOME}/nodeAgent.portcheck.state" 2>/dev/null | tail -1 | sed 's/^last_push_gate=//'
}
tg_count()   { [ -f "$TG_LOG" ] && grep -c "api.telegram.org" "$TG_LOG" || echo 0; }
push_count() { [ -f "$PUSH_LOG" ] && wc -l < "$PUSH_LOG" || echo 0; }

write_node_env() { # <NODEHUB_URL 值>
    cat > "${HOME}/.env" <<EOF
API_TOKEN=t
API_URL=api.stub
NODEHUB_URL=$1
EOF
    echo 'node_id="test-001"' > "${HOME}/node.env"
}

# ============================================================
# T1: TLS 证书校验失败 (curl 60) → 门禁拒推 + TG 一次, 不重试
# ============================================================

@test "T1: curl 60 (证书无法由 CA 认证) → 拒推 + TG 告警一次, 确定性失败不重试" {
    export STUB_PUSH_RC=60
    run_push
    [ "$status" -eq 0 ]                                  # 门禁处置后按已处理返回 0
    [ "$(push_count)" -eq 1 ]                            # 不重试 (一般失败才 sleep 5 重试)
    [ "$(tg_count)" -eq 1 ]
    grep -q "TLS 证书校验失败" "$TG_LOG"
    grep -q "monitor 证书与监控内部 CA 不匹配" "$TG_LOG"
    grep -q "密钥未外发" "$TG_LOG"
    case "$(gate_state)" in
        "TLS 证书校验失败"*) ;;
        *) fail "last_push_gate 应记录 TLS 校验失败原因, 实际: $(gate_state)" ;;
    esac
}

@test "T1b: wget 5 (SSL 校验失败, curl 不可用) → _TcpingPushOnce 映射 return 2" {
    export STUB_PUSH_RC=5
    unset MONITOR_CA
    # /tmp CA fixture (MONITOR_CA 未设时 _MonitorCaFile 走此路径, 无外部命令依赖)
    printf -- '-----BEGIN CERTIFICATE-----\nFAKECA\n' > /tmp/monitor-ca.pem
    # wbin: 仅含 wget 桩 (无 curl) → command -v curl 落空, 真实代码走 wget 分支
    _wbin="${TEST_TMPDIR}/wbin"; mkdir -p "$_wbin"
    cp "${STUB_BIN}/wget" "${_wbin}/wget"
    run sh -c 'PATH="$1"; export PATH
. "$2"
_json="{\"status\":\"ok\"}"
_rc=0
_TcpingPushOnce "$_json" || _rc=$?
trap - EXIT
exit $_rc' _ "${_wbin}" "${TEST_TMPDIR}/agent.lib.sh" 2>/dev/null
    [ "$status" -eq 2 ]
    [ "$(push_count)" -eq 1 ]
}

# ============================================================
# T2: 持续 TLS 校验失败 → 不重复告警
# ============================================================

@test "T2: 第二周期仍 TLS 失败 → last_push_gate 去重, 不再发 TG" {
    export STUB_PUSH_RC=60
    run_push
    [ "$status" -eq 0 ]
    [ "$(tg_count)" -eq 1 ]
    run_push                                              # 第二周期 (同因失败)
    [ "$status" -eq 0 ]
    [ "$(tg_count)" -eq 1 ]                              # 仍只 1 次
    [ "$(push_count)" -eq 2 ]                            # 每周期各尝试 1 次
}

# ============================================================
# T3: TLS 失败后推送成功 → 门禁清除 + 恢复 TG
# ============================================================

@test "T3: TLS 失败 → 修复后推送成功 → 清除门禁 + 恢复 TG 一次" {
    export STUB_PUSH_RC=60
    run_push
    [ "$(tg_count)" -eq 1 ]
    [ -n "$(gate_state)" ]

    export STUB_PUSH_RC=0
    run_push
    [ "$status" -eq 0 ]
    [ "$(tg_count)" -eq 2 ]
    grep -q "推送门禁恢复" "$TG_LOG"
    [ -z "$(gate_state)" ]

    run_push                                              # 持续成功不再发
    [ "$(tg_count)" -eq 2 ]
}

# ============================================================
# T4: 一般网络失败 → 重试一次, 不设门禁/不发 TG
# ============================================================

@test "T4: curl 7 (连接拒绝) → 重试一次后失败返回, 无门禁无 TG" {
    export STUB_PUSH_RC=7
    run_push
    [ "$status" -eq 1 ]                                  # 一般失败如实上抛 (调用方记 info)
    [ "$(push_count)" -eq 2 ]                            # 重试一次
    [ "$(tg_count)" -eq 0 ]
    [ -z "$(gate_state)" ]
}

# ============================================================
# T5: 前置门禁回归 (c670ceb 行为不回退)
# ============================================================

@test "T5: MONITOR_URL 非 https → 前置门禁拒推 + TG 一次, 不发起推送" {
    export MONITOR_URL="monitor.stub:8443"               # 无 scheme (wget/curl 按 http 处理)
    run_push
    [ "$status" -eq 0 ]
    [ "$(push_count)" -eq 0 ]                            # 未外发密钥
    [ "$(tg_count)" -eq 1 ]
    grep -q "MONITOR_URL 非 https" "$TG_LOG"
    case "$(gate_state)" in
        "MONITOR_URL 非 https"*) ;;
        *) fail "last_push_gate 应记录前置门禁原因" ;;
    esac
}

# ============================================================
# T6: LoadEnv NODEHUB_URL scheme 检测 (warn + TG, 标记去重)
# ============================================================

@test "T6a: 无 scheme → 自动补全 https:// + warn(TG) 一次 + 落标记" {
    write_node_env "hub.stub.local"
    run_env
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | tail -1)" = "NODEHUB_URL=https://hub.stub.local" ]
    [ "$(tg_count)" -eq 1 ]
    grep -q "NODEHUB_URL 非 https" "$TG_LOG"
    [ -f "${HOME}/nodeAgent.huburl-warned" ]
}

@test "T6b: 持续失配 (第二次运行) → 不重复告警" {
    write_node_env "hub.stub.local"
    run_env
    run_env
    [ "$(tg_count)" -eq 1 ]                              # 标记去重
    [ "$(printf '%s\n' "$output" | tail -1)" = "NODEHUB_URL=https://hub.stub.local" ]
}

@test "T6c: 显式 http:// → 保留原值仅告警; 改回 https 后清标记" {
    write_node_env "http://hub.stub.local"
    run_env
    [ "$(printf '%s\n' "$output" | tail -1)" = "NODEHUB_URL=http://hub.stub.local" ]  # 尊重运维选择不强改
    [ "$(tg_count)" -eq 1 ]

    sed -i 's#^NODEHUB_URL=.*#NODEHUB_URL=https://hub.stub.local#' "${HOME}/.env"
    run_env
    [ "$(printf '%s\n' "$output" | tail -1)" = "NODEHUB_URL=https://hub.stub.local" ]
    [ "$(tg_count)" -eq 1 ]                              # 正常配置无告警
    [ ! -f "${HOME}/nodeAgent.huburl-warned" ]           # 标记清除 (之后失配可重新告警)
}

@test "T6d: 本就 https:// → 静默无告警" {
    write_node_env "https://hub.stub.local"
    run_env
    [ "$(printf '%s\n' "$output" | tail -1)" = "NODEHUB_URL=https://hub.stub.local" ]
    [ "$(tg_count)" -eq 0 ]
    [ ! -f "${HOME}/nodeAgent.huburl-warned" ]
}
