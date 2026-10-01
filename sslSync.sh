#!/bin/sh
# ============================================================
# sslSync.sh — /etc/ssl 证书批量自动同步 (node 端)
#
# 功能: 定期从 ${NODEHUB_URL}/ssl/ 同步证书到 /etc/ssl;
#       任一证书内容有变化 → 重启 nginx + xray 使其生效;
#       全部无变化 → 什么都不做 (不重启, 零扰动)。
#
# 省流量设计:
#   * 下载目录常驻 /tmp/sslSync (不清理), wget -N 用本地 mtime 与服务端
#     Last-Modified 比对 → 无更新时每次只发一个 If-Modified-Since 304
#     探测请求, 不重传文件体
#   * 是否"有变化"以 cmp 内容比对为准 (非 mtime) → 远端仅重写时间戳/
#     权限不误判; /tmp 缓存被清 (机器重启等) 后也只是多一次全量下载,
#     cmp 发现内容相同照样不重启
#
# 安全设计 (镜像 nodeAgent.sh::SyncSSL 范式):
#   * 两阶段: 先全部下载+校验, 校验通过的域名才统一落盘 → 杜绝
#     "新 key + 旧 pem" 半更新中间态被进程重启时加载 (TLS 握手失败)
#   * 校验: PEM/KEY 文件头 + openssl 公钥配对 (openssl 可用时)
#   * 只处理 /etc/ssl 顶层 *.pem 及同名 .key, 不递归 /etc/ssl/certs、
#     /etc/ssl/private (系统 CA 目录); *.bak* / *backup* / *.self.* /
#     snitest.* 一律跳过 (远端无对应文件, 拉了也是 404)
#
# 环境: ~/.env 提供 NODEHUB_URL (basic-auth 直接内嵌 URL:
#       https://user:pass@host/... , wget 原生支持)
# 依赖: wget (必需) / openssl (可选, 配对校验) / systemctl (可选)
# cron: root 运行时幂等自注册到 /etc/crontab, 缺省每日 03:30;
#       可在 ~/.env 用 SSL_SYNC_CRON="分 时 * * *" 覆盖, 置空则不注册
# ============================================================

set -u

SSL_DIR="/etc/ssl"
CACHE_DIR="/tmp/sslSync"                 # wget -N 时间戳锚点, 常驻不清理
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
LOG_FILE="${HOME}/sslSync-$(date +%Y%m%d).log"

# ------------------------------------------------------------
# 工具函数
# ------------------------------------------------------------
Log() {
    # tee 写日志失败 (如 $HOME 不可写) 时至少保证 stdout 有输出
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "$*"
}

# 抹掉 URL 内嵌 basic-auth 的 user:pass, 用于日志脱敏
SafeUrl() {
    printf '%s' "$1" | sed 's#://[^/@]*@#://***@#'
}

# ------------------------------------------------------------
# 环境加载与校验
# ------------------------------------------------------------
LoadEnv() {
    _envf="${HOME}/.env"
    if [ ! -f "$_envf" ]; then
        Log "❌ ${_envf} 不存在, 请先配置 NODEHUB_URL"
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$_envf" || { Log "❌ 加载 ${_envf} 失败"; exit 1; }

    if [ -z "${NODEHUB_URL:-}" ]; then
        Log "❌ NODEHUB_URL 未设置, 请在 ${_envf} 中配置"
        exit 1
    fi

    # scheme 修补 (与 nodeAgent.sh 同口径): 无 scheme 补 https://, 显式 http 告警
    case "$NODEHUB_URL" in
        https://*) : ;;
        http://*)  Log "⚠️  NODEHUB_URL 为 http:// — 证书分发走明文, 建议改为 https://" ;;
        *)         NODEHUB_URL="https://${NODEHUB_URL}" ;;
    esac

    SSL_BASE="${NODEHUB_URL%/}/ssl"
    Log "✅ 环境就绪: 源=$(SafeUrl "$SSL_BASE")/  缓存=${CACHE_DIR}  目标=${SSL_DIR}"
}

# ------------------------------------------------------------
# wget -N 下载单文件到缓存目录
# 返回: 0 = 成功 (含 304 未变化); 非 0 = 失败 (已记日志)
# ------------------------------------------------------------
FetchOne() {
    # 不用 -q: 失败时需从 stderr 提取真实原因 (如 ERROR 404);
    # 成功时输出全部进变量, 对外保持静默
    _fo_err=$(wget -N -T 30 --tries=1 -P "$CACHE_DIR" "${SSL_BASE}/$1" 2>&1)
    _fo_rc=$?
    if [ "$_fo_rc" -ne 0 ]; then
        # wget 报错会回显完整 URL (含 user:pass), 落日志前先脱敏, 只取末行
        _fo_err=$(printf '%s' "$_fo_err" | sed 's#://[^/@]*@#://***@#g' | tail -n 1)
        Log "⚠️  $1 下载失败 (rc=${_fo_rc}): ${_fo_err}"
        return "$_fo_rc"
    fi
    return 0
}

# ------------------------------------------------------------
# 主同步流程: 下载 → 校验 → 比对 → 部署 → 按需重启
# 返回: 0 = 无变化或全部成功; 1 = 存在失败 (下载/校验/部署/重启)
# ------------------------------------------------------------
SyncCerts() {
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR" 2>/dev/null   # 缓存含私钥, 目录收紧为 root only

    _changed=""                          # 有变化的域名列表 (空格分隔)
    _checked=0                           # 实际处理的域名数
    _fail=0                              # 汇总失败标志

    for _pem in "$SSL_DIR"/*.pem; do
        [ -f "$_pem" ] || continue
        _base=${_pem##*/}
        case "$_base" in
            *.bak*|*.backup*|*.self.*|snitest.*) continue ;;   # 备份/自签/测试文件, 远端无对应
        esac
        _dom=${_base%.pem}
        _checked=$((_checked + 1))

        # 1) wget -N 拉取 pem + key — key/pem 任一下载失败则整个域名跳过,
        #    绝不半更新 (install 阶段只处理两侧文件齐全且校验通过的域名)
        if ! FetchOne "${_dom}.pem" || ! FetchOne "${_dom}.key"; then
            _fail=1
            continue
        fi
        chmod 600 "${CACHE_DIR}/${_dom}.key" 2>/dev/null || true

        # 2) 格式校验 — 防源端文件损坏/被篡改成错误内容
        if ! grep -q 'BEGIN CERTIFICATE' "${CACHE_DIR}/${_dom}.pem" 2>/dev/null; then
            Log "❌ ${_dom}.pem 不含 CERTIFICATE — 源文件可能损坏, 保持旧证书"
            _fail=1
            continue
        fi
        if ! grep -q 'PRIVATE KEY' "${CACHE_DIR}/${_dom}.key" 2>/dev/null; then
            Log "❌ ${_dom}.key 不含 PRIVATE KEY — 源文件可能损坏, 保持旧证书"
            _fail=1
            continue
        fi

        # 3) 配对校验 (openssl 可用时) — 只查文件头不查配对, 会漏掉
        #    "新 key + 旧 pem" 这类半更新 (远端分发出错并非不可能)
        if command -v openssl >/dev/null 2>&1; then
            _cpk=$(openssl x509 -in "${CACHE_DIR}/${_dom}.pem" -pubkey -noout 2>/dev/null | openssl md5 2>/dev/null || true)
            _kpk=$(openssl pkey -in "${CACHE_DIR}/${_dom}.key" -pubout 2>/dev/null | openssl md5 2>/dev/null || true)
            if [ -z "$_cpk" ] || [ "$_cpk" != "$_kpk" ]; then
                Log "❌ ${_dom} 证书与私钥不配对 — 源文件可能损坏, 保持旧证书"
                _fail=1
                continue
            fi
        fi

        # 4) 内容比对 (cmp, 非 mtime) — pem/key 任一不同才算变化
        if cmp -s "${CACHE_DIR}/${_dom}.pem" "${SSL_DIR}/${_dom}.pem" 2>/dev/null \
           && cmp -s "${CACHE_DIR}/${_dom}.key" "${SSL_DIR}/${_dom}.key" 2>/dev/null; then
            continue
        fi
        _changed="${_changed} ${_dom}"
    done

    # 5) 全部无变化 → 不重启, 直接返回 (最常见路径, 零扰动)
    if [ -z "$_changed" ]; then
        Log "✅ ${_checked} 个域名证书均无变化, 不重启服务"
        return "$_fail"
    fi

    # 6) 统一部署 — install 单文件覆盖 + 权限收紧 (key 600 / pem 644)
    Log "📝 检测到证书变化:${_changed} → 开始部署"
    for _d in $_changed; do
        if ! install -m 0600 "${CACHE_DIR}/${_d}.key" "${SSL_DIR}/${_d}.key" 2>/dev/null; then
            Log "❌ 写入 ${SSL_DIR}/${_d}.key 失败"
            _fail=1
        fi
        if ! install -m 0644 "${CACHE_DIR}/${_d}.pem" "${SSL_DIR}/${_d}.pem" 2>/dev/null; then
            Log "❌ 写入 ${SSL_DIR}/${_d}.pem 失败"
            _fail=1
        fi
    done
    Log "✅ 部署完成:${_changed}"

    # 7) 有更新 → 重启 nginx + xray 让新证书生效
    RestartServices || _fail=1
    return "$_fail"
}

# ------------------------------------------------------------
# 重启 nginx
# 有 systemd: nginx -t 预检后 systemctl restart + is-active 轮询验证
# 无 systemd: 退回 nginx -s reload (同样能加载新证书, 且不断连)
# ------------------------------------------------------------
RestartNginx() {
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
        command -v nginx >/dev/null 2>&1 \
            && { nginx -t 2>/dev/null || Log "⚠️  nginx -t 配置校验未通过 (仍尝试重启)"; }
        if ! systemctl restart nginx 2>/dev/null; then
            Log "❌ systemctl restart nginx 失败"
            return 1
        fi
        _i=0
        while [ "$_i" -lt 5 ]; do
            sleep 1
            _i=$((_i + 1))
            [ "$(systemctl is-active nginx 2>/dev/null)" = "active" ] && break
        done
        if [ "$(systemctl is-active nginx 2>/dev/null)" = "active" ]; then
            Log "✅ nginx 已重启 (active)"
            return 0
        fi
        Log "❌ nginx 重启后健康验证失败 (is-active 非 active)"
        return 1
    fi

    if command -v nginx >/dev/null 2>&1; then
        if nginx -s reload 2>/dev/null; then
            Log "✅ nginx 已 reload (本机无 systemd/nginx.service, reload 同样加载新证书)"
            return 0
        fi
        Log "❌ nginx -s reload 失败"
        return 1
    fi

    Log "ℹ️  nginx 与 systemctl 均不可用, 跳过 nginx"
    return 0
}

# ------------------------------------------------------------
# 重启 xray (镜像 nodeAgent.sh::RestartXrayWithHealthCheck)
# 注: xray 不支持 SIGHUP, reload 等同杀进程, 必须 restart;
#     restart 后轮询 is-active, 再用端口监听兜底确认真的起来了
# ------------------------------------------------------------
RestartXray() {
    command -v systemctl >/dev/null 2>&1 \
        || { Log "ℹ️  systemctl 不存在, 跳过 xray"; return 0; }
    systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service' \
        || { Log "ℹ️  xray.service 未安装, 跳过 xray"; return 0; }

    if ! systemctl restart xray 2>/dev/null; then
        Log "❌ systemctl restart xray 失败 —— 请检查 xray.service / config.json / 证书格式"
        return 1
    fi

    _i=0
    while [ "$_i" -lt 5 ]; do
        sleep 1
        _i=$((_i + 1))
        [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && break
    done
    if [ "$(systemctl is-active xray 2>/dev/null)" = "active" ]; then
        Log "✅ xray 已重启 (active)"
        return 0
    fi
    # 兜底: is-active 偶有滞后, 再用端口监听确认
    if command -v ss >/dev/null 2>&1 && ss -tlnp 2>/dev/null | grep -q xray; then
        Log "✅ xray 端口监听正常, 视为健康 (is-active 暂未刷新)"
        return 0
    fi
    Log "❌ xray 健康验证失败 (is-active 非 active 且无端口监听) —— 可能未起来, 请人工介入"
    return 1
}

RestartServices() {
    _rs_fail=0
    RestartNginx || _rs_fail=1
    RestartXray  || _rs_fail=1
    return "$_rs_fail"
}

# ------------------------------------------------------------
# crontab 幂等自注册 (镜像 sync.sh: 先删旧条目再追加, 仅 root)
# 缺省每日 03:30 — 错开 03:00 的 sync.sh (GeoData/Xray 插件) 流量高峰
# ------------------------------------------------------------
InstallCron() {
    if [ "$(id -u)" != "0" ]; then
        Log "ℹ️  非 root 运行, 跳过 crontab 自注册 (同步照常)"
        return 0
    fi
    _cron_expr="${SSL_SYNC_CRON:-30 3 * * *}"
    if [ -z "$_cron_expr" ]; then
        Log "ℹ️  SSL_SYNC_CRON 为空, 跳过 crontab 自注册"
        return 0
    fi
    # sed 地址用 \#...# 作定界符容纳路径中的 /
    if ! sed -i "\#${SELF}#d" /etc/crontab 2>/dev/null; then
        Log "⚠️  /etc/crontab 写入失败 — 请检查权限"
        return 0
    fi
    if ! echo "${_cron_expr} root ${SELF}" >> /etc/crontab 2>/dev/null; then
        Log "⚠️  /etc/crontab 追加失败"
        return 0
    fi
    Log "✅ crontab 已注册: ${_cron_expr} ${SELF}"
}

# ------------------------------------------------------------
# 旧日志清理: 只保留最近 7 天 (失败不阻断)
# ------------------------------------------------------------
CleanOldLogs() {
    find "$HOME" -maxdepth 1 -name 'sslSync-*.log' -mtime +7 -delete 2>/dev/null || true
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
Log "===== sslSync.sh 开始 ====="
LoadEnv
InstallCron
CleanOldLogs
if SyncCerts; then
    Log "===== sslSync.sh 完成 ====="
    exit 0
fi
Log "===== sslSync.sh 完成 (部分失败, 见上方日志) ====="
exit 1
