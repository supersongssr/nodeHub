#!/bin/sh
# ============================================================
# sync.sh — 节点数据同步 (兼首次初始化)
# 任务: 确保目录结构 + 安装crontab + SSL同步 + GeoData更新 + Xray检测
# 部署: 手动运行一次即可, 会自动加入 crontab 每晚 03:00 运行
# ============================================================

# ============================================================
# 环境变量 (项目目录/.env)
# ============================================================
# [必填] Telegram 通知
#   TG_BOT_TOKEN           — Telegram Bot Token
#   TG_CHAT_ID             — Telegram Chat ID
#
# [必填] SSL 证书同步
#   SSL_SYNC_BASE_URL      — 证书下载地址
#   SSL_DOMAINS            — 待同步域名列表, 空格分隔
# ============================================================

set -eu

NODEHUB_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${NODEHUB_DIR}/logs/sync-$(date +%Y%m%d).log"

# ============================================================
# 环境加载与校验
# ============================================================
ENV_FILE="${NODEHUB_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE" || { echo "❌ 加载 ${ENV_FILE} 失败"; exit 1; }
else
    echo "❌ ${ENV_FILE} 不存在，请先创建并配置以下变量:"; echo ""
    echo "  TG_BOT_TOKEN       — Telegram Bot Token, 用于发送通知"
    echo "  TG_CHAT_ID         — Telegram Chat ID, 通知目标聊天"
    echo "  SSL_SYNC_BASE_URL  — 证书下载地址"
    echo "  SSL_DOMAINS        — 待同步域名列表"
    exit 1
fi

_err=""
[ -z "${TG_BOT_TOKEN:-}" ]   && _err="${_err}  ❌ TG_BOT_TOKEN — Telegram Bot Token\n"
[ -z "${TG_CHAT_ID:-}" ]     && _err="${_err}  ❌ TG_CHAT_ID — Telegram Chat ID\n"
[ -z "${SSL_SYNC_BASE_URL:-}" ] && _err="${_err}  ❌ SSL_SYNC_BASE_URL — 证书下载地址\n"
[ -z "${SSL_DOMAINS:-}" ]       && _err="${_err}  ❌ SSL_DOMAINS — 待同步域名列表\n"

if [ -n "$_err" ]; then
    echo "❌ 以下必需环境变量未设置:"; echo ""
    printf "%b" "$_err"
    echo ""
    echo "请在 ${ENV_FILE} 中配置以上变量"
    exit 1
fi

echo "✅ sync.sh 环境变量校验通过"

# ============================================================
# 工具函数
# ============================================================
Log() {
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

NotifyTG() {
    # 通知为 “尽力而为”, 任何失败都不得中断主流程 (配合 set -e)
    if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
        return 0
    fi
    curl -s --connect-timeout 5 --max-time 15 \
        -d "chat_id=${TG_CHAT_ID}&text=from:sync:$1" \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1 || true
}

# ============================================================
# Step 0: 初始化 (幂等)
# ============================================================
Init() {
    Log "=== 初始化 ==="

    # 创建数据目录
    mkdir -p "${NODEHUB_DIR}/ssl/logs"
    mkdir -p "${NODEHUB_DIR}/geodat"
    mkdir -p "${NODEHUB_DIR}/xray"
    mkdir -p "${NODEHUB_DIR}/logs"

    # 初始化 geodat 版本追踪
    touch "${NODEHUB_DIR}/geodat/config.sh"

    # 安装 crontab: 每晚 03:00 运行自身
    sed -i '/sync\.sh/d' /etc/crontab
    echo "0 3 * * * root /bin/sh ${NODEHUB_DIR}/sync.sh" >> /etc/crontab

    Log "目录就绪, crontab 已配置 (03:00)"
}

# ============================================================
# Step 1: SSL 证书同步
# ============================================================
SyncSSL() {
    Log "=== 同步 SSL 证书 ==="

    SSL_DIR="${NODEHUB_DIR}/ssl"
    SSL_LOG="${SSL_DIR}/logs/ssl-check.log"

    # 从 .env 读取 SSL 同步地址和域名列表
    BASE_URL="${SSL_SYNC_BASE_URL}"
    DOMAINS="${SSL_DOMAINS}"

    updated=0
    failed=0

    for domain in $DOMAINS; do
        Log "同步: $domain"

        # 用 if 条件包裹 wget, 使其免受 set -e 影响 (条件中的命令不会触发 errexit)
        if wget -N -q -T 30 -P "$SSL_DIR" "${BASE_URL}/${domain}.pem" 2>/dev/null && \
           wget -N -q -T 30 -P "$SSL_DIR" "${BASE_URL}/${domain}.key" 2>/dev/null; then
            updated=$((updated + 1))
            Log "完成: $domain"
        else
            failed=$((failed + 1))
            Log "失败: $domain"
        fi
    done

    Log "SSL — 成功: $updated, 失败: $failed"

    if [ "$failed" -gt 0 ]; then
        NotifyTG "SSL同步完成, 成功:${updated} 失败:${failed}"
    else
        NotifyTG "SSL同步全部成功, 共${updated}个域名"
    fi
}

# ============================================================
# Step 2: GeoData 更新
# ============================================================
SyncGeoData() {
    Log "=== 更新 GeoData ==="

    GEO_DIR="${NODEHUB_DIR}/geodat"
    CONF="${GEO_DIR}/config.sh"

    geositeVersion=""
    geoipVersion=""
    . "$CONF"

    # --- geosite ---
    new_geosite=$(wget -qO- -t1 -T 15 \
        "https://api.github.com/repos/v2fly/domain-list-community/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null || echo "")

    if [ -n "$new_geosite" ] && [ "$new_geosite" != "$geositeVersion" ]; then
        Log "geosite: ${geositeVersion:-无} → ${new_geosite}"
        if wget -N -q -T 120 -P "$GEO_DIR" \
            "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"; then
            mv -f "${GEO_DIR}/dlc.dat" "${GEO_DIR}/geosite.dat"
            sed -i '/^geositeVersion=/d' "$CONF" 2>/dev/null || true
            echo "geositeVersion=${new_geosite}" >> "$CONF"
            Log "geosite 更新完成"
        else
            Log "geosite 下载失败, 跳过"
        fi
    else
        Log "geosite 未变化"
    fi

    # --- geoip ---
    new_geoip=$(wget -qO- -t1 -T 15 \
        "https://api.github.com/repos/v2fly/geoip/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null || echo "")

    if [ -n "$new_geoip" ] && [ "$new_geoip" != "$geoipVersion" ]; then
        Log "geoip: ${geoipVersion:-无} → ${new_geoip}"
        if wget -N -q -T 120 -P "$GEO_DIR" \
            "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"; then
            sed -i '/^geoipVersion=/d' "$CONF" 2>/dev/null || true
            echo "geoipVersion=${new_geoip}" >> "$CONF"
            Log "geoip 更新完成"
        else
            Log "geoip 下载失败, 跳过"
        fi
    else
        Log "geoip 未变化"
    fi
}


# ============================================================
# Step 3: Xray 更新检测
# ============================================================
SyncXray() {
    Log "=== 检查 Xray ==="

    XRAY_DIR="${NODEHUB_DIR}/xray"

    latest=$(wget -qO- -t1 -T 15 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null || echo "")

    if [ -z "$latest" ]; then
        Log "Xray: 无法获取版本, 跳过"
        return 0
    fi

    current=""
    [ -f "${XRAY_DIR}/.version" ] && current=$(cat "${XRAY_DIR}/.version")

    if [ "$latest" = "$current" ]; then
        Log "Xray: 已是最新 ${latest}"
        return 0
    fi

    Log "Xray: ${current:-无} → ${latest}, 下载中..."

    wget -N -q -T 120 -P "$XRAY_DIR" \
        "https://github.com/supersongssr/xray-plugin-srp/releases/download/v0.0.9/xray-plugin-srp-v0.0.9" \
        || { Log "Xray: srp 下载失败"; return 1; }

    wget -N -q -T 120 -P "$XRAY_DIR" \
        "https://github.com/supersongssr/xray-plugin-ssp/releases/download/v0.0.9/xray-plugin-ssp-v0.0.9" \
        || { Log "Xray: ssp 下载失败"; return 1; }

    echo "$latest" > "${XRAY_DIR}/.version"
    Log "Xray: 已更新到 ${latest}"
}

# ============================================================
# 主流程
# ============================================================
Log "===== sync.sh 开始 ====="
Init
SyncSSL
SyncGeoData
SyncXray
Log "===== sync.sh 完成 ====="
