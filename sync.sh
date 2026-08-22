#!/bin/sh
# ============================================================
# sync.sh — 节点数据同步 (兼首次初始化)
# 任务: 确保目录结构 + GeoData更新 + Xray插件下载 + 每晚 03:00 自注册 crontab
# 说明: 所有下载均使用 wget -N, 由时间戳决定是否真正拉取
# ============================================================

# ============================================================
# 环境变量 (项目目录/.env)
# ============================================================
# [必填] Telegram 通知
#   TG_BOT_TOKEN  — Telegram Bot Token
#   TG_CHAT_ID    — Telegram Chat ID
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
    echo "  TG_BOT_TOKEN  — Telegram Bot Token, 用于发送通知"
    echo "  TG_CHAT_ID    — Telegram Chat ID, 通知目标聊天"
    exit 1
fi

_err=""
[ -z "${TG_BOT_TOKEN:-}" ]   && _err="${_err}  ❌ TG_BOT_TOKEN — Telegram Bot Token\n"
[ -z "${TG_CHAT_ID:-}" ]     && _err="${_err}  ❌ TG_CHAT_ID — Telegram Chat ID\n"

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
    # 通知为 "尽力而为", 任何失败都不得中断主流程 (配合 set -e)
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
    mkdir -p "${NODEHUB_DIR}/geodat"
    mkdir -p "${NODEHUB_DIR}/xray"
    mkdir -p "${NODEHUB_DIR}/logs"

    # 安装 crontab: 每晚 03:00 运行自身 (幂等: 先删旧条目再追加)。
    # 写失败仅告警不中断 — 本脚本 set -eu, 裸写 /etc/crontab (仅 root 可写) 在非 root
    # 排障运行时会直接中止整个 sync, 连 GeoData/Xray 插件更新都做不了。
    # (SSL 同步已交由 nodeAgent.sh:SyncSSL, 此处仅保证 GeoData / Xray 插件
    #   定期更新, 否则二者无任何自动触发源)
    if [ "$(id -u)" = "0" ]; then
        # 用完整路径锚定删除旧条目: 裸 '/sync\.sh/d' 会误删任何名字含 sync.sh 子串的
        # 无关条目 (如 /opt/backup/backup-sync.sh); sed 地址用 \#...# 作定界符容纳路径中的 /
        sed -i "\#${NODEHUB_DIR}/sync.sh#d" /etc/crontab 2>/dev/null || true
        echo "0 3 * * * root /bin/sh ${NODEHUB_DIR}/sync.sh" >> /etc/crontab 2>/dev/null \
            || Log "crontab 写入失败 — 请检查 /etc/crontab 权限"
        Log "目录就绪, crontab 已配置 (03:00)"
    else
        Log "非 root 运行, 跳过 crontab 自注册 (GeoData/Xray 更新照常)"
    fi
}

# ============================================================
# Step 1: GeoData 更新
# 说明: 直接 wget -N 拉取最新 release, 时间戳无更新则跳过下载
# ============================================================
SyncGeoData() {
    Log "=== 更新 GeoData ==="
    GEO_DIR="${NODEHUB_DIR}/geodat"
    _ok=1

    # geosite: 保留 dlc.dat 作为 wget -N 时间戳锚点。
    #   旧实现 `wget ... && mv dlc.dat geosite.dat` 会让本地 dlc.dat 每次消失,
    #   下次 wget -N 无本地文件可比对 → 每次全量重下。
    #   改为下载后 cp 出 geosite.dat, dlc.dat 常驻, wget -N 时间戳判定才生效。
    #   同时把 wget 与 cp 的失败分开记录, 不再把复制失败误报为“下载失败”。
    if wget -N -q -T 120 -P "$GEO_DIR" \
            "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"; then
        cp -f "${GEO_DIR}/dlc.dat" "${GEO_DIR}/geosite.dat" \
            || { Log "geosite: 复制 dlc.dat → geosite.dat 失败"; _ok=0; }
    else
        Log "geosite 下载失败"; _ok=0
    fi

    # geoip: 直接 -P 保存为 geoip.dat, 文件常驻 → wget -N 时间戳判定生效
    if ! wget -N -q -T 120 -P "$GEO_DIR" \
            "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"; then
        Log "geoip 下载失败"; _ok=0
    fi

    # 按各子步骤成败汇总输出, 不再无脑打印“更新完成”
    if [ "$_ok" -eq 1 ]; then
        Log "GeoData 更新完成"
    else
        Log "GeoData 更新流程结束 (部分失败, 见上方日志)"
        _sync_ok=0
    fi
}

# ============================================================
# Step 2: Xray 插件下载
# 说明: 插件更新与 Xray core 版本无关, 直接下载最新插件即可
# ============================================================
SyncXray() {
    Log "=== 下载 Xray 插件 ==="
    XRAY_DIR="${NODEHUB_DIR}/xray"
    _ok=1

    wget -N -q -T 120 -P "$XRAY_DIR" \
        "https://github.com/supersongssr/xray-plugin-srp/releases/download/v0.0.9/xray-plugin-srp-v26.6.27" \
        || { Log "Xray: srp 下载失败"; _ok=0; }

    wget -N -q -T 120 -P "$XRAY_DIR" \
        "https://github.com/supersongssr/xray-plugin-ssp/releases/download/v0.0.9/xray-plugin-ssp-v26.6.27" \
        || { Log "Xray: ssp 下载失败"; _ok=0; }

    wget -N -q -T 120 -P "$XRAY_DIR" https://github.com/supersongssr/xray-plugin-api/releases/download/v0.1.0/xray-plugin-api-v26.6.27 || { Log "Xray: api 下载失败"; _ok=0; }

    # 按子步骤成败汇总输出, 与 SyncGeoData 风格一致
    if [ "$_ok" -eq 1 ]; then
        Log "Xray 插件下载完成"
    else
        Log "Xray 插件下载流程结束 (部分失败, 见上方日志)"
        _sync_ok=0
    fi
}

# ============================================================
# 主流程
# ============================================================
# _sync_ok: 跨步骤成败汇总标志 (1=全部成功), SyncGeoData / SyncXray 任一失败置 0
Log "===== sync.sh 开始 ====="
_sync_ok=1
Init
SyncGeoData
SyncXray
if [ "$_sync_ok" -eq 1 ]; then
    NotifyTG "sync 完成"
else
    NotifyTG "sync 完成 (部分失败, 见日志)"
fi
Log "===== sync.sh 完成 ====="
