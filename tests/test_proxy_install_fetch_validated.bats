#!/usr/bin/env bats
# ============================================================
# test_proxy_install_fetch_validated.bats — 下载校验+脏文件自愈测试
# 覆盖 (复审组落地: f-24eb4a13 及同类):
#   1. 无本地文件 + 正常下载 → 内容校验通过 (返回 0)
#   2. 下载到垃圾内容 (源损坏) → 强制重下仍坏 → 返回 1 且清理脏文件
#   3. 本地脏文件 + wget -N 跳过 (时间戳机制) → 强制重下修复 (核心场景)
#   4. 脏文件 + 强制重下也坏 → 返回 1 且不留脏文件
#   5. 本地有效副本 + 服务器不可达 → 沿用本地副本返回 0
#   6. _ValidateFile 各校验类型: script(#!) / elf(魔数) / unit(ExecStart) /
#      nonempty / cert / key 的正反例
# 隔离: 提取 _ValidateFile/FetchValidated + PATH mock wget
#       (wget.mode 控制行为, 调用记录到 wget.log)
# ============================================================

load 'test_helper'

MOCK_STATE_DIR=""

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="${TEST_TMPDIR}"
    MOCK_BIN_DIR="${TEST_TMPDIR}/mock_bin"
    MOCK_STATE_DIR="${TEST_TMPDIR}/state"
    mkdir -p "${MOCK_BIN_DIR}" "${MOCK_STATE_DIR}" "${TEST_TMPDIR}/dl"
    export MOCK_STATE_DIR

    # ---- mock wget: 按 wget.mode 行为分派 ----
    #   ok      : -N/-O 均写出合法脚本内容 (#!/bin/sh 开头)
    #   garbage : -N/-O 均写出 HTML 垃圾 (模拟坏源/错误页)
    #   skip    : -N 不碰本地文件直接成功 (模拟脏文件比服务器新被跳过),
    #             -O 写出合法脚本 (强制重下可修复)
    #   skipbad : -N 跳过, -O 写垃圾 (脏文件 + 源也坏)
    #   fail    : 全部失败 (网络不可达)
    cat > "${MOCK_BIN_DIR}/wget" <<'EOF'
#!/bin/sh
_state="${MOCK_STATE_DIR:?MOCK_STATE_DIR unset}"
echo "$@" >> "${_state}/wget.log"
_mode="$(cat "${_state}/wget.mode" 2>/dev/null || echo ok)"
_out="" _dir="." _url="" _had_O=0
while [ $# -gt 0 ]; do
    case "$1" in
        -O) shift; _out="$1"; _had_O=1 ;;
        -P) shift; _dir="$1" ;;
        -N|--timeout=*|--tries=*) ;;
        http://*|https://*) _url="$1" ;;
    esac
    shift
done
[ -n "$_out" ] || _out="${_dir}/${_url##*/}"
case "$_mode" in
    fail)    exit 1 ;;
    ok)      printf '#!/bin/sh\necho good\n' > "$_out" ;;
    garbage) printf '<html>error page\n' > "$_out" ;;
    skip)    [ "$_had_O" = 1 ] && printf '#!/bin/sh\necho good\n' > "$_out"; exit 0 ;;
    skipbad) [ "$_had_O" = 1 ] && printf '<html>error page\n' > "$_out"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN_DIR}/wget"
    export PATH="${MOCK_BIN_DIR}:${PATH}"

    # ---- 提取被测函数 (不能 source 整个 proxyInstall.sh — 末尾会执行 Main) ----
    sed -n '/^_ValidateFile() {/,/^}$/p;/^FetchValidated() {/,/^}$/p' \
        "${PROJECT_ROOT}/proxyInstall.sh" > "${TEST_TMPDIR}/fetch.sh"

    # ---- 桩: log (die 不涉及 — FetchValidated 不直接退出) ----
    cat > "${TEST_TMPDIR}/stubs.sh" <<'EOF'
log() { _lvl="$1"; shift; echo "[${_lvl}] $*" >> "${MOCK_STATE_DIR}/log.out"; }
EOF
    . "${TEST_TMPDIR}/stubs.sh"
    . "${TEST_TMPDIR}/fetch.sh"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
    return 0
}

mode() { printf '%s\n' "$1" > "${MOCK_STATE_DIR}/wget.mode"; }
forced_wget_called() { grep -q ' -O ' "${MOCK_STATE_DIR}/wget.log" 2>/dev/null; }

# ============================================================
# FetchValidated — 下载 + 校验 + 自愈流程
# ============================================================

@test "FetchValidated: 无本地文件 + 下载正常 → 校验通过返回 0" {
    mode ok
    run FetchValidated script "${TEST_TMPDIR}/dl/a.sh" "http://hub.test/a.sh"
    [ "$status" -eq 0 ]
    [ "$(head -c 2 "${TEST_TMPDIR}/dl/a.sh" 2>/dev/null)" = "#!" ]
    ! forced_wget_called
}

@test "FetchValidated: 下载到垃圾内容 → 强制重下仍坏 → 返回 1 且清理" {
    mode garbage
    run FetchValidated script "${TEST_TMPDIR}/dl/a.sh" "http://hub.test/a.sh"
    [ "$status" -eq 1 ]
    [ ! -f "${TEST_TMPDIR}/dl/a.sh" ]
    forced_wget_called
}

@test "FetchValidated: 本地脏文件被 wget -N 跳过 → 强制重下修复 (f-24eb4a13 核心)" {
    # 0 字节脏文件 = 上次下载中断的残留; wget -N 比时间戳跳过下载返回成功
    : > "${TEST_TMPDIR}/dl/a.sh"
    mode skip
    run FetchValidated script "${TEST_TMPDIR}/dl/a.sh" "http://hub.test/a.sh"
    [ "$status" -eq 0 ]
    [ "$(head -c 2 "${TEST_TMPDIR}/dl/a.sh" 2>/dev/null)" = "#!" ]
    forced_wget_called
}

@test "FetchValidated: 截断的非 #! 脏文件同样触发强制重下修复" {
    printf '<html>half of a scri' > "${TEST_TMPDIR}/dl/a.sh"
    mode skip
    run FetchValidated script "${TEST_TMPDIR}/dl/a.sh" "http://hub.test/a.sh"
    [ "$status" -eq 0 ]
    [ "$(head -c 2 "${TEST_TMPDIR}/dl/a.sh" 2>/dev/null)" = "#!" ]
    forced_wget_called
}

@test "FetchValidated: 脏文件 + 强制重下也坏 → 返回 1 且不留脏文件" {
    : > "${TEST_TMPDIR}/dl/a.sh"
    mode skipbad
    run FetchValidated script "${TEST_TMPDIR}/dl/a.sh" "http://hub.test/a.sh"
    [ "$status" -eq 1 ]
    [ ! -f "${TEST_TMPDIR}/dl/a.sh" ]
    forced_wget_called
}

@test "FetchValidated: 本地有效副本 + 服务器不可达 → 沿用本地副本返回 0" {
    printf '#!/bin/sh\necho cached\n' > "${TEST_TMPDIR}/dl/a.sh"
    mode fail
    run FetchValidated script "${TEST_TMPDIR}/dl/a.sh" "http://hub.test/a.sh"
    [ "$status" -eq 0 ]
    grep -q 'echo cached' "${TEST_TMPDIR}/dl/a.sh"
    ! forced_wget_called
}

# ============================================================
# _ValidateFile — 各校验类型正反例
# ============================================================

@test "_ValidateFile: script/elf/unit/nonempty/cert/key 正反例" {
    _v="${TEST_TMPDIR}/v"
    mkdir -p "${_v}"
    printf '#!/bin/sh\n' > "${_v}/s.sh"
    printf '\177ELF-binary-junk' > "${_v}/b.bin"
    printf '[Unit]\n[Service]\nExecStart=/bin/true\n' > "${_v}/u.service"
    printf 'x' > "${_v}/d.dat"
    printf -- '-----BEGIN CERTIFICATE-----\nabc\n' > "${_v}/c.pem"
    printf -- '-----BEGIN PRIVATE KEY-----\nabc\n' > "${_v}/k.key"
    : > "${_v}/empty"

    run _ValidateFile script "${_v}/s.sh";    [ "$status" -eq 0 ]
    run _ValidateFile elf "${_v}/b.bin";      [ "$status" -eq 0 ]
    run _ValidateFile unit "${_v}/u.service"; [ "$status" -eq 0 ]
    run _ValidateFile nonempty "${_v}/d.dat"; [ "$status" -eq 0 ]
    run _ValidateFile cert "${_v}/c.pem";     [ "$status" -eq 0 ]
    run _ValidateFile key "${_v}/k.key";      [ "$status" -eq 0 ]

    # 反例: 空文件 / 类型不符
    run _ValidateFile script "${_v}/empty";   [ "$status" -eq 1 ]
    run _ValidateFile script "${_v}/b.bin";   [ "$status" -eq 1 ]
    run _ValidateFile elf "${_v}/s.sh";       [ "$status" -eq 1 ]
    run _ValidateFile unit "${_v}/s.sh";      [ "$status" -eq 1 ]
    run _ValidateFile nonempty "${_v}/empty"; [ "$status" -eq 1 ]
    run _ValidateFile cert "${_v}/k.key";     [ "$status" -eq 1 ]
    run _ValidateFile key "${_v}/c.pem";      [ "$status" -eq 1 ]
    run _ValidateFile script "${_v}/不存在";  [ "$status" -eq 1 ]
}
