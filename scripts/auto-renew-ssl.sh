#!/bin/sh
# ============================================================
# scripts/auto-renew-ssl.sh — SSL 证书自动续期 / 部署
# ============================================================
# 作用:
#   1. 证书下载源取自 ~/.env 的 $NODEHUB_URL
#      模式: ${NODEHUB_URL}/ssl/<domain>.pem  与  .key
#      (若 .env 中设置了专用 SSL_SYNC_BASE_URL, 则优先使用它)
#   2. 待续期域名取自项目 .env 的 SSL_DOMAINS, 或脚本参数
#   3. 读取 /etc/ssl/<domain>.pem 的过期时间, 若剩余 < 30 天
#      (或本地缺失/损坏) 才尝试同步, 避免无谓请求
#   4. 使用 wget -N 时间戳下载 (仅在远端更新时真正拉取),
#      校验 证书↔私钥 配对后原子部署到 /etc/ssl, 并重载服务
#   5. 每晚由 cron 自动执行: ./auto-renew-ssl.sh --install-cron
# ============================================================
# 用法:
#   auto-renew-ssl.sh                    # 续期 SSL_DOMAINS 中所有域名
#   auto-renew-ssl.sh vvup.top kukuss.top# 仅续期指定域名
#   auto-renew-ssl.sh --force            # 跳过 30 天阈值强制同步
#   auto-renew-ssl.sh --install-cron     # 安装每晚 04:15 的 cron 任务
#   auto-renew-ssl.sh --help
# ============================================================

set -eu

# ---- 路径 ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODEHUB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_FILE="${NODEHUB_DIR}/logs/auto-renew-ssl-$(date +%Y%m%d).log"
mkdir -p "${NODEHUB_DIR}/logs"

# ---- 默认配置 (可被环境变量覆盖) ----
SSL_DEST_DIR="${SSL_DEST_DIR:-/etc/ssl}"          # 证书部署目录
RENEW_DAYS="${RENEW_DAYS:-30}"                     # 剩余天数阈值
WGET_TIMEOUT="${WGET_TIMEOUT:-120}"
# 部署后尝试重载的服务 (空格分隔; 未安装/未运行则自动跳过)
RELOAD_SERVICES="${RELOAD_SERVICES:-nginx xray}"

FORCE=0

# ============================================================
# 环境加载: 先 ~/.env (含 NODEHUB_URL), 再项目 .env
# ============================================================
LoadEnv() {
    for _f in "${HOME}/.env" "${NODEHUB_DIR}/.env"; do
        if [ -f "$_f" ]; then
            # shellcheck disable=SC1090
            . "$_f" 2>/dev/null || true
        fi
    done
}
LoadEnv

# 下载源 base: 优先专用 SSL_SYNC_BASE_URL, 否则回退 ${NODEHUB_URL}/ssl
SSL_BASE_URL="${SSL_SYNC_BASE_URL:-}"
if [ -z "$SSL_BASE_URL" ] && [ -n "${NODEHUB_URL:-}" ]; then
    SSL_BASE_URL="${NODEHUB_URL%/}/ssl"
fi

# ============================================================
# 工具函数
# ============================================================
Log() {
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${_ts}] $*" | tee -a "$LOG_FILE"
}

NotifyTG() {
    [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ] && return 0
    curl -s --connect-timeout 5 --max-time 15 \
        -d "chat_id=${TG_CHAT_ID}&text=$1" \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1 || true
}

# 返回某证书剩余天数 (stdout):
#   -1 = 文件不存在;  -2 = 解析失败(损坏);  N = 剩余天数 (可为负)
DaysLeft() {
    _pem="$1"
    [ -f "$_pem" ] || { echo "-1"; return; }
    _end=$(openssl x509 -enddate -noout -in "$_pem" 2>/dev/null | cut -d= -f2-)
    [ -n "$_end" ] || { echo "-2"; return; }
    _end_ep=$(date -d "$_end" +%s 2>/dev/null) || { echo "-2"; return; }
    [ -n "$_end_ep" ] || { echo "-2"; return; }
    _now_ep=$(date +%s)
    echo $(( (_end_ep - _now_ep) / 86400 ))
}

# 校验 pem 可解析, key 可解析, 且公私钥配对 (兼容 RSA / EC); 成功返回 0
VerifyCert() {
    _pem="$1"; _key="$2"
    openssl x509 -in "$_pem" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "$_key" -noout >/dev/null 2>&1 || return 1
    _cpk=$(openssl x509 -in "$_pem" -pubkey -noout 2>/dev/null | openssl md5 2>/dev/null)
    _kpk=$(openssl pkey -in "$_key" -pubout 2>/dev/null     | openssl md5 2>/dev/null)
    [ -n "$_cpk" ] && [ "$_cpk" = "$_kpk" ]
}

# ============================================================
# 续期单个域名
#   全局 _CHANGE: 成功部署新证书时置为 "yes"
#   返回: 0 = 成功(更新或跳过);  非0 = 失败
# ============================================================
RenewDomain() {
    _domain="$1"
    _CHANGE=""
    Log "--- ${_domain} ---"

    _dest_pem="${SSL_DEST_DIR}/${_domain}.pem"
    _dest_key="${SSL_DEST_DIR}/${_domain}.key"
    _days=$(DaysLeft "$_dest_pem")

    # 30 天阈值判断 (--force 时跳过)
    if [ "$FORCE" -eq 0 ] && [ "$_days" -ge "$RENEW_DAYS" ]; then
        Log "✅ ${_domain}: 剩余 ${_days} 天 (≥ ${RENEW_DAYS}), 跳过"
        return 0
    fi
    if [ "$_days" -lt 0 ]; then
        Log "⏳ ${_domain}: 本地无证书/损坏, 开始首次部署"
    else
        Log "⚠️  ${_domain}: 剩余 ${_days} 天 (< ${RENEW_DAYS}), 开始续期"
    fi

    _tmp="$(mktemp -d)"

    # 下载到空暂存区 (wget -N 时间戳模式; 每次暂存区为空 → 均拉取,
    # 避免 pem/key 因远端时间戳不一致导致只更新一半而配对失败)
    if ! wget -N -q -T "$WGET_TIMEOUT" -P "$_tmp" "${SSL_BASE_URL}/${_domain}.pem"; then
        Log "❌ ${_domain}: 下载 .pem 失败 -> ${SSL_BASE_URL}/${_domain}.pem"
        rm -rf "$_tmp"; return 1
    fi
    if ! wget -N -q -T "$WGET_TIMEOUT" -P "$_tmp" "${SSL_BASE_URL}/${_domain}.key"; then
        Log "❌ ${_domain}: 下载 .key 失败 -> ${SSL_BASE_URL}/${_domain}.key"
        rm -rf "$_tmp"; return 1
    fi

    # 校验下载产物
    if ! VerifyCert "${_tmp}/${_domain}.pem" "${_tmp}/${_domain}.key"; then
        Log "❌ ${_domain}: 证书/私钥校验失败 (配对或格式错误), 保留旧证书"
        rm -rf "$_tmp"; return 1
    fi

    # 远端无更新则保持现状
    if [ -f "$_dest_pem" ] && cmp -s "${_tmp}/${_domain}.pem" "$_dest_pem" \
                            && cmp -s "${_tmp}/${_domain}.key" "$_dest_key"; then
        Log "ℹ️  ${_domain}: 远端无更新, 保持现状"
        rm -rf "$_tmp"; return 0
    fi

    # 原子部署
    install -m 0644 -o root -g root "${_tmp}/${_domain}.pem" "$_dest_pem"
    install -m 0600 -o root -g root "${_tmp}/${_domain}.key" "$_dest_key"
    rm -rf "$_tmp"

    _new=$(DaysLeft "$_dest_pem")
    _CHANGE="yes"
    Log "✅ ${_domain}: 部署成功, 新证书剩余 ${_new} 天"
    return 0
}

# ============================================================
# 重载服务 (仅重载已运行的服务; reload 失败则回退 restart)
# ============================================================
ReloadServices() {
    for _svc in $RELOAD_SERVICES; do
        if ! command -v systemctl >/dev/null 2>&1; then
            return 0
        fi
        systemctl list-unit-files 2>/dev/null | grep -q "^${_svc}\.service" || continue
        systemctl is-active "$_svc" >/dev/null 2>&1 || { Log "ℹ️  ${_svc} 未运行, 跳过"; continue; }
        if systemctl reload "$_svc" 2>/dev/null; then
            Log "🔄 reload ${_svc} 完成"
        elif systemctl restart "$_svc" 2>/dev/null; then
            Log "🔄 restart ${_svc} 完成"
        else
            Log "⚠️  ${_svc} reload/restart 失败"
        fi
    done
}

# ============================================================
# 安装每晚运行的 cron 任务
# ============================================================
InstallCron() {
    _self="${SCRIPT_DIR}/$(basename "$0")"
    _entry="15 4 * * * /bin/sh ${_self} >> ${NODEHUB_DIR}/logs/auto-renew-ssl.cron.log 2>&1"
    _tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "auto-renew-ssl.sh" > "$_tmp_cron" || true
    echo "$_entry" >> "$_tmp_cron"
    crontab "$_tmp_cron"
    rm -f "$_tmp_cron"
    echo "✅ 已安装 cron 任务 (每晚 04:15):"
    echo "    ${_entry}"
}

Usage() {
    sed -n '3,30p' "$0"
}

# ============================================================
# 参数解析
# ============================================================
while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-cron) InstallCron; exit 0 ;;
        -f|--force)     FORCE=1; shift ;;
        -h|--help)      Usage; exit 0 ;;
        *)              break ;;
    esac
done

# 域名: 参数 > SSL_DOMAINS
if [ "$#" -gt 0 ]; then
    DOMAINS="$*"
elif [ -n "${SSL_DOMAINS:-}" ]; then
    DOMAINS="$SSL_DOMAINS"
else
    Log "❌ 未指定域名: 请用参数传入, 或在 .env 设置 SSL_DOMAINS"
    exit 1
fi

# ============================================================
# 前置校验
# ============================================================
if [ -z "${SSL_BASE_URL:-}" ]; then
    Log "❌ 未配置下载源: 请在 ~/.env 设置 NODEHUB_URL, 或在 .env 设置 SSL_SYNC_BASE_URL"
    exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
    Log "❌ 缺少 openssl"; exit 1
fi
if ! command -v wget >/dev/null 2>&1; then
    Log "❌ 缺少 wget"; exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    Log "❌ 需要 root 权限以写入 ${SSL_DEST_DIR}"; exit 1
fi
mkdir -p "$SSL_DEST_DIR"

# ============================================================
# 主流程
# ============================================================
Log "===== auto-renew-ssl.sh 开始 ====="
Log "下载源 : ${SSL_BASE_URL}"
Log "部署到 : ${SSL_DEST_DIR}"
if [ "$FORCE" -eq 1 ]; then
    Log "模式   : 强制同步 (--force)"
else
    Log "阈值   : 剩余 < ${RENEW_DAYS} 天续期"
fi
Log "域名   : ${DOMAINS}"

_updated=""
_failed=""
for _d in $DOMAINS; do
    _CHANGE=""
    if RenewDomain "$_d"; then
        [ -n "$_CHANGE" ] && _updated="${_updated:+$_updated }$_d"
    else
        _failed="${_failed:+$_failed }$_d"
    fi
done

if [ -n "$_updated" ]; then
    ReloadServices
    Log "✅ 本次已部署: ${_updated}"
    NotifyTG "auto-renew-ssl 已部署: ${_updated}"
else
    Log "ℹ️  本次无需更新任何证书"
fi

if [ -n "$_failed" ]; then
    Log "❌ 本次失败: ${_failed}"
    NotifyTG "auto-renew-ssl 失败: ${_failed}"
    Log "===== auto-renew-ssl.sh 完成 (含失败) ====="
    exit 1
fi

Log "===== auto-renew-ssl.sh 完成 ====="
