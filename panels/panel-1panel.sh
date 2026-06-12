#!/bin/sh
# ============================================================
# panel-1panel.sh — 1Panel 面板的 Nginx 代理配置脚本
# 功能: 在 1Panel 管理的 OpenResty 中配置 xray 反向代理
# 
# 1Panel 使用 OpenResty 管理 Nginx:
#   - 安装路径: /opt/1panel/apps/openresty/openresty/
#   - 站点配置: /opt/1panel/apps/openresty/openresty/conf/conf.d/
#   - 全局配置: /opt/1panel/apps/openresty/openresty/conf/nginx.conf
#   - SSL 证书: /opt/1panel/ssl/ 或 /etc/ssl/
#
# 调用方式: 被 proxyInstall.sh source 引入
# 入口函数: Panel1Panel_Setup
# ============================================================

# 防止重复 source
[ -n "${_PANEL_1PANEL_LOADED:-}" ] && return 0
_PANEL_1PANEL_LOADED=1

# 1Panel OpenResty 路径常量
_1PANEL_OPENRESTY_DIR="/opt/1panel/apps/openresty/openresty"
_1PANEL_NGINX_CONF_DIR="${_1PANEL_OPENRESTY_DIR}/conf/conf.d"
_1PANEL_NGINX_BIN="${_1PANEL_OPENRESTY_DIR}/sbin/nginx"
_1PANEL_NGINX_CMD=""

# ============================================================
# 检测 1Panel 的 nginx/OpenResty 可执行文件
# ============================================================
Panel1Panel_FindNginx() {
    # 优先使用 1Panel 的 OpenResty
    if [ -x "${_1PANEL_OPENRESTY_DIR}/sbin/nginx" ]; then
        _1PANEL_NGINX_CMD="${_1PANEL_OPENRESTY_DIR}/sbin/nginx"
        log info "1Panel OpenResty: ${_1PANEL_NGINX_CMD}"
        return 0
    fi

    # Docker 模式: 1Panel 可能用 docker 运行 OpenResty
    if command -v docker >/dev/null 2>&1; then
        _container=$(docker ps --filter "name=openresty" --format '{{.Names}}' 2>/dev/null | head -1 || true)
        if [ -n "$_container" ]; then
            _1PANEL_NGINX_CMD="docker exec ${_container} nginx"
            log info "1Panel OpenResty (Docker): ${_container}"
            return 0
        fi
    fi

    # 兜底: 系统 nginx
    if command -v nginx >/dev/null 2>&1; then
        _1PANEL_NGINX_CMD="nginx"
        log info "1Panel 使用系统 nginx"
        return 0
    fi

    log error "1Panel: 未找到 nginx/OpenResty"
    return 1
}

# ============================================================
# 确保 conf.d 目录存在
# ============================================================
Panel1Panel_EnsureDirs() {
    if [ ! -d "${_1PANEL_NGINX_CONF_DIR}" ]; then
        mkdir -p "${_1PANEL_NGINX_CONF_DIR}"
        log info "创建 1Panel nginx 配置目录: ${_1PANEL_NGINX_CONF_DIR}"
    fi
}

# ============================================================
# 在 1Panel 中创建/更新 proxy.{domain} 网站
# 策略: 
#   1. 检查是否已有 nodehub-proxy.conf，有则更新
#   2. 没有则创建新的
#   3. 同时更新 1Panel 的网站数据库 (如可用)
# ============================================================
Panel1Panel_ConfigureSite() {
    _domain="$1"
    _cert_path="$2"
    _key_path="$3"
    _xray_port="$4"
    _panel_proxy_conf="$5"  # 面板 API 下发的 nginx 配置

    _conf_name="nodehub-proxy.conf"
    _target_conf="${_1PANEL_NGINX_CONF_DIR}/${_conf_name}"

    log info "1Panel: 配置 proxy.${_domain} → xray:${_xray_port}"

    # 检查是否已有配置 (重复配置场景)
    if [ -f "$_target_conf" ]; then
        _old_domain=$(grep -oP 'server_name\s+proxy\.\K[^;\s]+' "$_target_conf" 2>/dev/null || true)
        if [ "$_old_domain" = "$_domain" ]; then
            log info "1Panel: 已存在 ${_conf_name} (${_domain})，更新配置"
        else
            log info "1Panel: 已存在 ${_conf_name} 但域名不同 (${_old_domain}→${_domain})，覆盖更新"
        fi
    fi

    # 生成 nginx 配置 (调用 panel-common.sh 中的 GenerateProxyServerBlock)
    GenerateProxyServerBlock "$_domain" "$_cert_path" "$_key_path" "$_xray_port" "$_panel_proxy_conf" > "$_target_conf"

    log info "1Panel: 配置已写入 ${_target_conf}"
}

# ============================================================
# 测试并重载 1Panel nginx
# ============================================================
Panel1Panel_ReloadNginx() {
    log info "1Panel: 测试 nginx 配置..."

    if [ -n "${_1PANEL_NGINX_CMD}" ]; then
        # 测试配置
        ${_1PANEL_NGINX_CMD} -t 2>&1 || {
            log error "1Panel nginx 配置检查失败"
            return 1
        }

        # 重载配置
        ${_1PANEL_NGINX_CMD} -s reload 2>&1 || {
            log warn "1Panel nginx reload 失败，尝试 restart"
            if echo "$_1PANEL_NGINX_CMD" | grep -q "docker exec"; then
                _container=$(echo "$_1PANEL_NGINX_CMD" | awk '{print $3}')
                docker restart "$_container" 2>&1 || {
                    log error "1Panel nginx restart 失败"
                    return 1
                }
            else
                systemctl restart openresty 2>/dev/null || systemctl restart nginx 2>/dev/null || {
                    log error "1Panel nginx restart 失败"
                    return 1
                }
            fi
        }
    else
        # 兜底: 通过 1pctl 重启
        1pctl restart openresty 2>/dev/null || {
            systemctl restart openresty 2>/dev/null || systemctl restart nginx 2>/dev/null || {
                log error "1Panel: 无法重载 nginx"
                return 1
            }
        }
    fi

    log info "1Panel: nginx 已重载"
}

# ============================================================
# 清理旧的重复配置 (去重)
# 确保 nodehub-proxy 配置只出现一次
# ============================================================
Panel1Panel_CleanupDuplicates() {
    _count=$(ls -1 "${_1PANEL_NGINX_CONF_DIR}"/nodehub-proxy*.conf 2>/dev/null | wc -l || echo 0)
    if [ "$_count" -gt 1 ]; then
        log warn "1Panel: 发现 ${_count} 个 nodehub-proxy 配置文件，清理重复项"
        # 保留最新的，删除旧的
        ls -t "${_1PANEL_NGINX_CONF_DIR}"/nodehub-proxy*.conf | tail -n +2 | while read -r _f; do
            log warn "  删除: ${_f}"
            rm -f "$_f"
        done
    fi
}

# ============================================================
# 主入口: 1Panel 面板 Nginx 代理配置
# 参数: $1=root_domain, $2=cert_path, $3=key_path, $4=xray_port
#       $5=panel_proxy_conf (可选，面板 API 下发的配置)
# ============================================================
Panel1Panel_Setup() {
    _domain="${1:?domain 参数缺失}"
    _cert_path="${2:?cert_path 参数缺失}"
    _key_path="${3:?key_path 参数缺失}"
    _xray_port="${4:?xray_port 参数缺失}"
    _panel_proxy_conf="${5:-}"

    log info "===== 1Panel 面板 Nginx 代理配置 ====="

    # 1. 检测 nginx
    Panel1Panel_FindNginx || return 1

    # 2. 确保目录存在
    Panel1Panel_EnsureDirs

    # 3. 清理重复配置
    Panel1Panel_CleanupDuplicates

    # 4. 配置网站
    Panel1Panel_ConfigureSite "$_domain" "$_cert_path" "$_key_path" "$_xray_port" "$_panel_proxy_conf"

    # 5. 测试并重载
    Panel1Panel_ReloadNginx

    log info "===== 1Panel 面板 Nginx 代理配置完成 ====="
    return 0
}
