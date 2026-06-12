#!/usr/bin/env bats
# ============================================================
# test_panel_btpanel.bats — panel-btpanel.sh 宝塔/AA Panel 测试
# 覆盖: PanelBtPanel_FindNginx, PanelBtPanel_EnsureDirs,
#        PanelBtPanel_InstallCert, PanelBtPanel_ConfigureSite,
#        PanelBtPanel_CleanupDuplicates, PanelBtPanel_Setup
# ============================================================

load 'test_helper'

# ============================================================
# PanelBtPanel_FindNginx 测试
# ============================================================

@test "PanelBtPanel_FindNginx: 宝塔安装的 nginx 优先" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local fake_nginx="${TEST_TMPDIR}/nginx/sbin/nginx"
    mkdir -p "$(dirname "$fake_nginx")"
    echo '#!/bin/sh' > "$fake_nginx"
    echo 'echo "bt-nginx"' >> "$fake_nginx"
    chmod +x "$fake_nginx"

    _BT_NGINX_DIR="${TEST_TMPDIR}/nginx"
    _BT_NGINX_CMD=""

    PanelBtPanel_FindNginx
    [ "${_BT_NGINX_CMD}" = "${TEST_TMPDIR}/nginx/sbin/nginx" ]
}

@test "PanelBtPanel_FindNginx: 兜底使用系统 nginx" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    _BT_NGINX_DIR="${TEST_TMPDIR}/nonexistent"
    _BT_NGINX_CMD=""

    if command -v nginx >/dev/null 2>&1; then
        PanelBtPanel_FindNginx
        [ "${_BT_NGINX_CMD}" = "nginx" ]
    else
        skip "系统无 nginx"
    fi
}

@test "PanelBtPanel_FindNginx: 无 nginx 时返回错误" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    _BT_NGINX_DIR="${TEST_TMPDIR}/nonexistent"
    _BT_NGINX_CMD=""
    local orig_path="$PATH"
    export PATH="/usr/bin:/bin"

    # 确保系统 nginx 也不可用
    if command -v nginx >/dev/null 2>&1; then
        export PATH="$orig_path"
        skip "系统有 nginx, 无法测试无 nginx 场景"
    fi

    run PanelBtPanel_FindNginx
    [ "$status" -ne 0 ]
    export PATH="$orig_path"
}

# ============================================================
# PanelBtPanel_EnsureDirs 测试
# ============================================================

@test "PanelBtPanel_EnsureDirs: 创建 vhost 目录" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    local test_ssl="${TEST_TMPDIR}/vhost/ssl"
    _BT_VHOST_NGINX_DIR="${test_vhost}"
    _BT_VHOST_SSL_DIR="${test_ssl}"

    [ ! -d "${test_vhost}" ]
    PanelBtPanel_EnsureDirs
    [ -d "${test_vhost}" ]
    [ -d "${test_ssl}" ]
}

# ============================================================
# PanelBtPanel_InstallCert 测试
# ============================================================

@test "PanelBtPanel_InstallCert: 复制证书到宝塔标准路径" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_ssl_dir="${TEST_TMPDIR}/ssl"
    _BT_VHOST_SSL_DIR="${test_ssl_dir}"

    local cert_src="${TEST_TMPDIR}/src_cert.pem"
    local key_src="${TEST_TMPDIR}/src_key.pem"
    echo "CERT CONTENT" > "$cert_src"
    echo "KEY CONTENT" > "$key_src"

    PanelBtPanel_InstallCert "example.com" "$cert_src" "$key_src"

    [ -f "${test_ssl_dir}/example.com/fullchain.pem" ]
    [ -f "${test_ssl_dir}/example.com/privkey.pem" ]
    grep -q "CERT CONTENT" "${test_ssl_dir}/example.com/fullchain.pem"
    grep -q "KEY CONTENT" "${test_ssl_dir}/example.com/privkey.pem"
}

@test "PanelBtPanel_InstallCert: privkey 权限 600" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_ssl_dir="${TEST_TMPDIR}/ssl"
    _BT_VHOST_SSL_DIR="${test_ssl_dir}"

    local cert_src="${TEST_TMPDIR}/src_cert.pem"
    local key_src="${TEST_TMPDIR}/src_key.pem"
    echo "CERT" > "$cert_src"
    echo "KEY" > "$key_src"

    PanelBtPanel_InstallCert "example.com" "$cert_src" "$key_src"

    local key_perms
    key_perms=$(stat -c '%a' "${test_ssl_dir}/example.com/privkey.pem" 2>/dev/null || stat -f '%Lp' "${test_ssl_dir}/example.com/privkey.pem")
    [ "$key_perms" = "600" ]
}

@test "PanelBtPanel_InstallCert: fullchain 权限 644" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_ssl_dir="${TEST_TMPDIR}/ssl"
    _BT_VHOST_SSL_DIR="${test_ssl_dir}"

    local cert_src="${TEST_TMPDIR}/src_cert.pem"
    local key_src="${TEST_TMPDIR}/src_key.pem"
    echo "CERT" > "$cert_src"
    echo "KEY" > "$key_src"

    PanelBtPanel_InstallCert "example.com" "$cert_src" "$key_src"

    local cert_perms
    cert_perms=$(stat -c '%a' "${test_ssl_dir}/example.com/fullchain.pem" 2>/dev/null || stat -f '%Lp' "${test_ssl_dir}/example.com/fullchain.pem")
    [ "$cert_perms" = "644" ]
}

@test "PanelBtPanel_InstallCert: 多域名证书隔离" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_ssl_dir="${TEST_TMPDIR}/ssl"
    _BT_VHOST_SSL_DIR="${test_ssl_dir}"

    echo "CERT A" > "${TEST_TMPDIR}/cert_a.pem"
    echo "KEY A" > "${TEST_TMPDIR}/key_a.pem"
    echo "CERT B" > "${TEST_TMPDIR}/cert_b.pem"
    echo "KEY B" > "${TEST_TMPDIR}/key_b.pem"

    PanelBtPanel_InstallCert "domain-a.com" "${TEST_TMPDIR}/cert_a.pem" "${TEST_TMPDIR}/key_a.pem"
    PanelBtPanel_InstallCert "domain-b.com" "${TEST_TMPDIR}/cert_b.pem" "${TEST_TMPDIR}/key_b.pem"

    [ -f "${test_ssl_dir}/domain-a.com/fullchain.pem" ]
    [ -f "${test_ssl_dir}/domain-b.com/fullchain.pem" ]
    grep -q "CERT A" "${test_ssl_dir}/domain-a.com/fullchain.pem"
    grep -q "CERT B" "${test_ssl_dir}/domain-b.com/fullchain.pem"
}

# ============================================================
# PanelBtPanel_ConfigureSite 测试
# ============================================================

@test "PanelBtPanel_ConfigureSite: 生成含域名的配置文件" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    mkdir -p "${test_vhost}"
    _BT_VHOST_NGINX_DIR="${test_vhost}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "CERT" > "$cert_path"
    echo "KEY" > "$key_path"

    PanelBtPanel_ConfigureSite "mydomain.com" "$cert_path" "$key_path" "8443" ""

    local target="${test_vhost}/nodehub-proxy.mydomain.com.conf"
    [ -f "$target" ]
    grep -q "proxy.mydomain.com" "$target"
    grep -q "127.0.0.1:8443" "$target"
}

@test "PanelBtPanel_ConfigureSite: 同域名文件覆盖 (幂等)" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    mkdir -p "${test_vhost}"
    _BT_VHOST_NGINX_DIR="${test_vhost}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "CERT" > "$cert_path"
    echo "KEY" > "$key_path"

    PanelBtPanel_ConfigureSite "mydomain.com" "$cert_path" "$key_path" "8443" ""
    PanelBtPanel_ConfigureSite "mydomain.com" "$cert_path" "$key_path" "9999" ""

    local count
    count=$(ls -1 "${test_vhost}"/nodehub-proxy.mydomain.com*.conf 2>/dev/null | wc -l)
    [ "$count" -eq 1 ]

    grep -q "127.0.0.1:9999" "${test_vhost}/nodehub-proxy.mydomain.com.conf"
}

@test "PanelBtPanel_ConfigureSite: 多域名不冲突" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    mkdir -p "${test_vhost}"
    _BT_VHOST_NGINX_DIR="${test_vhost}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "CERT" > "$cert_path"
    echo "KEY" > "$key_path"

    PanelBtPanel_ConfigureSite "aaa.com" "$cert_path" "$key_path" "8443" ""
    PanelBtPanel_ConfigureSite "bbb.com" "$cert_path" "$key_path" "9443" ""

    [ -f "${test_vhost}/nodehub-proxy.aaa.com.conf" ]
    [ -f "${test_vhost}/nodehub-proxy.bbb.com.conf" ]
    grep -q "127.0.0.1:8443" "${test_vhost}/nodehub-proxy.aaa.com.conf"
    grep -q "127.0.0.1:9443" "${test_vhost}/nodehub-proxy.bbb.com.conf"
}

# ============================================================
# PanelBtPanel_CleanupDuplicates 测试
# ============================================================

@test "PanelBtPanel_CleanupDuplicates: 清理旧格式 nodehub-proxy.conf" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    mkdir -p "${test_vhost}"
    _BT_VHOST_NGINX_DIR="${test_vhost}"

    echo "old config" > "${test_vhost}/nodehub-proxy.conf"
    echo "new config" > "${test_vhost}/nodehub-proxy.example.com.conf"

    PanelBtPanel_CleanupDuplicates "example.com"

    [ ! -f "${test_vhost}/nodehub-proxy.conf" ]
    [ -f "${test_vhost}/nodehub-proxy.example.com.conf" ]
}

@test "PanelBtPanel_CleanupDuplicates: 无旧配置时不报错" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    mkdir -p "${test_vhost}"
    _BT_VHOST_NGINX_DIR="${test_vhost}"

    run PanelBtPanel_CleanupDuplicates "example.com"
    [ "$status" -eq 0 ]
}

# ============================================================
# PanelBtPanel_Setup 集成测试
# ============================================================

@test "PanelBtPanel_Setup: 完整流程 — nginx 查找 + 目录创建 + SSL 安装 + 配置生成" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    local test_ssl="${TEST_TMPDIR}/vhost/ssl"
    _BT_VHOST_NGINX_DIR="${test_vhost}"
    _BT_VHOST_SSL_DIR="${test_ssl}"
    _BT_AAPANEL_DIR="${TEST_TMPDIR}/no-aapanel"

    # 模拟 nginx
    local fake_nginx="${TEST_TMPDIR}/nginx/sbin/nginx"
    mkdir -p "$(dirname "$fake_nginx")"
    cat > "$fake_nginx" <<'SCRIPT'
#!/bin/sh
case "$1" in
    -t) echo "nginx config test OK"; exit 0;;
    -s) echo "nginx reloaded"; exit 0;;
    *)  exit 0;;
esac
SCRIPT
    chmod +x "$fake_nginx"
    _BT_NGINX_DIR="${TEST_TMPDIR}/nginx"
    _BT_NGINX_CMD="${fake_nginx}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "FAKE CERT DATA" > "$cert_path"
    echo "FAKE KEY DATA" > "$key_path"

    PanelBtPanel_Setup "test.com" "$cert_path" "$key_path" "8443" ""

    # 验证 SSL 证书安装
    [ -f "${test_ssl}/test.com/fullchain.pem" ]
    [ -f "${test_ssl}/test.com/privkey.pem" ]

    # 验证 nginx 配置生成
    [ -f "${test_vhost}/nodehub-proxy.test.com.conf" ]
    grep -q "proxy.test.com" "${test_vhost}/nodehub-proxy.test.com.conf"
    grep -q "127.0.0.1:8443" "${test_vhost}/nodehub-proxy.test.com.conf"
}

@test "PanelBtPanel_Setup: AA Panel 模式 (aapanel 目录存在)" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    local test_ssl="${TEST_TMPDIR}/vhost/ssl"
    _BT_VHOST_NGINX_DIR="${test_vhost}"
    _BT_VHOST_SSL_DIR="${test_ssl}"
    _BT_AAPANEL_DIR="${TEST_TMPDIR}/aapanel"
    mkdir -p "${_BT_AAPANEL_DIR}"

    # 模拟 nginx
    local fake_nginx="${TEST_TMPDIR}/nginx/sbin/nginx"
    mkdir -p "$(dirname "$fake_nginx")"
    cat > "$fake_nginx" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
    chmod +x "$fake_nginx"
    _BT_NGINX_DIR="${TEST_TMPDIR}/nginx"
    _BT_NGINX_CMD="${fake_nginx}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "CERT" > "$cert_path"
    echo "KEY" > "$key_path"

    PanelBtPanel_Setup "test.com" "$cert_path" "$key_path" "8443" ""

    # 验证配置已生成
    [ -f "${test_vhost}/nodehub-proxy.test.com.conf" ]
}

@test "PanelBtPanel_Setup: 缺少必需参数时返回错误" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    # 不传 domain 参数
    run PanelBtPanel_Setup "" "/ssl/cert.pem" "/ssl/key.pem" "8443"
    [ "$status" -ne 0 ]
}
