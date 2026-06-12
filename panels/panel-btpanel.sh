#!/bin/sh
# ============================================================
# panel-btpanel.sh — 宝塔面板 (btpanel) / AA Panel 的 Nginx 代理配置脚本
# 功能: 在宝塔管理的 Nginx 中配置 xray 反向代理
#
# 宝塔面板 Nginx 路径:
#   - Nginx 目录: /www/server/nginx/
#   - 站点配置: /www/server/panel/vhost/nginx/
#   - SSL 证书: /www/server/panel/vhost/ssl/
#   - 宝塔 CLI: bt (command -v bt)
#
# AA Panel (国际版) 路径:
#   - 安装目录: /www/server/aapanel/
#   - 其余与宝塔面板共用 /www/server/nginx/ 和 vhost 目录
#
# 调用方式: 被 proxyInstall.sh source 引入
# 入口函数: PanelBtPanel_Setup
# ============================================================

# 防止重复 source
[ -n "${_PANEL_BTPANEL_LOADED:-}" ] && return 0
_PANEL_BTPANEL_LOADED=1

# 宝塔面板路径常量
_BT_PANEL_DIR="/www/server/panel"
_BT_AAPANEL_DIR="/www/server/aapanel"
_BT_NGINX_DIR="/www/server/nginx"
_BT_VHOST_NGINX_DIR="/www/server/panel/vhost/nginx"
_BT_VHOST_SSL_DIR="/www/server/panel/vhost/ssl"
_BT_NGINX_CMD=""

# ============================================================
# 检测宝塔的 Nginx 可执行文件
# ============================================================
PanelBtPanel_FindNginx() {
    # 优先宝塔安装的 nginx
    if [ -x "${_BT_NGINX_DIR}/sbin/nginx" ]; then
        _BT_NGINX_CMD="${_BT_NGINX_DIR}/sbin/nginx"
        log info "宝塔 nginx: ${_BT_NGINX_CMD}"
        return 0
    fi

    # 兜底: 系统 nginx
    if command -v nginx >/dev/null 2>&1; then
        _BT_NGINX_CMD="nginx"
        log info "宝塔: 使用系统 nginx"
        return 0
    fi

    log error "宝塔: 未找到 nginx"
    return 1
}

# ============================================================
# 确保必要目录存在
# ============================================================
PanelBtPanel_EnsureDirs() {
    if [ ! -d "${_BT_VHOST_NGINX_DIR}" ]; then
        mkdir -p "${_BT_VHOST_NGINX_DIR}" && log info "创建宝塔 vhost nginx 目录"
    fi
    if [ ! -d "${_BT_VHOST_SSL_DIR}" ]; then
        mkdir -p "${_BT_VHOST_SSL_DIR}" && log info "创建宝塔 vhost ssl 目录"
    fi
}

# ============================================================
# 将 SSL 证书链接/复制到宝塔证书目录
# 宝塔面板 SSL 证书存储格式: /www/server/panel/vhost/ssl/{domain}/
#   - fullchain.pem
#   - privkey.pem
# ============================================================
PanelBtPanel_InstallCert() {
    _domain="$1"
    _cert_src="$2"
    _key_src="$3"

    _ssl_dir="${_BT_VHOST_SSL_DIR}/${_domain}"
    mkdir -p "$_ssl_dir"

    # 复制证书文件
    cp -f "$_cert_src" "${_ssl_dir}/fullchain.pem"
    cp -f "$_key_src" "${_ssl_dir}/privkey.pem"
    chmod 600 "${_ssl_dir}/privkey.pem"
    chmod 644 "${_ssl_dir}/fullchain.pem"

    log info "宝塔: SSL 证书已安装到 ${_ssl_dir}/"
}

# ============================================================
# 在宝塔中创建/更新 proxy.{domain} 网站
# 策略:
#   1. 生成 nodehub-proxy.{domain}.conf 到宝塔 vhost 目录
#   2. 同名文件覆盖更新 (重复配置不产生多个)
#   3. 通过 bt CLI 注册网站 (如可用)
# ============================================================
PanelBtPanel_ConfigureSite() {
    _domain="$1"
    _cert_path="$2"
    _key_path="$3"
    _xray_port="$4"
    _panel_proxy_conf="$5"

    _conf_name="nodehub-proxy.${_domain}.conf"
    _target_conf="${_BT_VHOST_NGINX_DIR}/${_conf_name}"

    log info "宝塔: 配置 proxy.${_domain} → xray:${_xray_port}"

    # 生成 nginx 配置
    GenerateProxyServerBlock "$_domain" "$_cert_path" "$_key_path" "$_xray_port" "$_panel_proxy_conf" > "$_target_conf"

    log info "宝塔: 配置已写入 ${_target_conf}"
}

# ============================================================
# 清理旧的重复配置
# ============================================================
PanelBtPanel_CleanupDuplicates() {
    _dup_domain="$1"

    # 只清理旧格式 nodehub-proxy.conf (不含域名, 难以区分多域名)
    # 宝塔文件名含域名 (nodehub-proxy.{domain}.conf), 同名覆盖即可去重, 不删除其他域名
    _old_conf="${_BT_VHOST_NGINX_DIR}/nodehub-proxy.conf"
    if [ -f "$_old_conf" ]; then
        log info "宝塔: 清理旧格式配置 nodehub-proxy.conf"
        rm -f "$_old_conf"
    fi
}

# ============================================================
# 测试并重载宝塔 nginx
# ============================================================
PanelBtPanel_ReloadNginx() {
    log info "宝塔: 测试 nginx 配置..."

    if [ -n "${_BT_NGINX_CMD}" ]; then
        ${_BT_NGINX_CMD} -t 2>&1 || {
            log error "宝塔 nginx 配置检查失败"
            return 1
        }

        ${_BT_NGINX_CMD} -s reload 2>&1 || {
            log warn "宝塔 nginx reload 失败，尝试 restart"
            /etc/init.d/nginx restart 2>/dev/null || systemctl restart nginx 2>/dev/null || {
                log error "宝塔 nginx restart 失败"
                return 1
            }
        }
    else
        /etc/init.d/nginx restart 2>/dev/null || systemctl restart nginx 2>/dev/null || {
            log error "宝塔: 无法重载 nginx"
            return 1
        }
    fi

    log info "宝塔: nginx 已重载"
}

# ============================================================
# 通过宝塔 CLI 注册网站 (可选，增加面板可见性)
# 宝塔 CLI: bt 命令
# ============================================================
PanelBtPanel_RegisterSite() {
    _site_name="$1"

    if ! command -v bt >/dev/null 2>&1; then
        log debug "宝塔: bt CLI 不可用，跳过网站注册"
        return 0
    fi

    # 检查是否已注册
    _existing=$(bt site list 2>/dev/null | grep -c "${_site_name}" || true)
    if [ "$_existing" -gt 0 ]; then
        log info "宝塔: ${_site_name} 已在面板中注册"
        return 0
    fi

    # 尝试通过 bt CLI 添加网站 (纯静态，用于占位)
    bt site add "${_site_name}" 2>/dev/null && log info "宝塔: 已通过 CLI 注册 ${_site_name}" || {
        log debug "宝塔: bt CLI 添加网站失败 (非致命，nginx 配置已生效)"
    }
}

# ============================================================
# 主入口: 宝塔/AA Panel 面板 Nginx 代理配置
# 参数: $1=root_domain, $2=cert_path, $3=key_path, $4=xray_port
#       $5=panel_proxy_conf (可选，面板 API 下发的配置)
# ============================================================
PanelBtPanel_Setup() {
    _domain="${1:?domain 参数缺失}"
    _cert_path="${2:?cert_path 参数缺失}"
    _key_path="${3:?key_path 参数缺失}"
    _xray_port="${4:?xray_port 参数缺失}"
    _panel_proxy_conf="${5:-}"

    # 判断是宝塔还是 AA Panel
    _bt_variant="宝塔面板"
    [ -d "${_BT_AAPANEL_DIR}" ] && _bt_variant="AA Panel"
    log info "===== ${_bt_variant} Nginx 代理配置 ====="

    # 1. 检测 nginx
    PanelBtPanel_FindNginx || return 1

    # 2. 确保目录存在
    PanelBtPanel_EnsureDirs

    # 3. 安装 SSL 证书到宝塔目录
    PanelBtPanel_InstallCert "$_domain" "$_cert_path" "$_key_path"

    # 4. 清理重复配置
    PanelBtPanel_CleanupDuplicates "$_domain"

    # 5. 配置网站
    PanelBtPanel_ConfigureSite "$_domain" "$_cert_path" "$_key_path" "$_xray_port" "$_panel_proxy_conf"

    # 6. 测试并重载
    PanelBtPanel_ReloadNginx

    # 7. 尝试通过面板 CLI 注册 (非致命)
    PanelBtPanel_RegisterSite "proxy.${_domain}"

    log info "===== ${_bt_variant} Nginx 代理配置完成 ====="
    return 0
}
