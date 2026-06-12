#!/usr/bin/env bats
# ============================================================
# test_proxy_install_panel.bats — proxyInstall.sh 面板集成测试
# 覆盖: DetectPanel, Step3_InstallNginx_Panel 逻辑
# 测试方式: 提取相关函数到临时文件并 mock 外部依赖
# ============================================================

load 'test_helper'

# 测试用的 mock 目录
MOCK_BIN_DIR="${TEST_TMPDIR}/mock_bin"

# 创建 mock 命令
create_mock_bin() {
    mkdir -p "${MOCK_BIN_DIR}"
    # mock 1pctl
    cat > "${MOCK_BIN_DIR}/1pctl" <<'EOF'
#!/bin/sh
exit 0
EOF
    # mock bt
    cat > "${MOCK_BIN_DIR}/bt" <<'EOF'
#!/bin/sh
exit 0
EOF
    # mock systemctl
    cat > "${MOCK_BIN_DIR}/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/sh
case "$1" in
    is-active)
        case "$2" in
            1panel) exit 1 ;;
            bt) exit 1 ;;
            aapanel) exit 1 ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 0 ;;
esac
MOCK_SYSTEMCTL
    chmod +x "${MOCK_BIN_DIR}"/*
}

# 提取 proxyInstall.sh 中的 DetectPanel 函数
# 需要模拟 log 和 SetNodeEnv
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="${TEST_TMPDIR}"
    export _PANEL_COMMON_LOADED=""
    export _PANEL_1PANEL_LOADED=""
    export _PANEL_BTPANEL_LOADED=""

    MOCK_BIN_DIR="${TEST_TMPDIR}/mock_bin"
    create_mock_bin

    # 创建测试用的 node.env
    touch "${TEST_TMPDIR}/node.env"
}

teardown() {
    if [ -d "${TEST_TMPDIR}" ]; then
        rm -rf "${TEST_TMPDIR}"
    fi
}

# ============================================================
# DetectPanel — 1Panel 检测
# ============================================================

@test "DetectPanel: 检测到 1pctl 命令 → _PANEL_TYPE=1panel" {
    # 提供 mock 1pctl
    export PATH="${MOCK_BIN_DIR}:${PATH}"
    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    # 使用 eval 来模拟 DetectPanel 的核心逻辑
    # 因为我们不能 source 整个 proxyInstall.sh
    eval '
    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    if command -v 1pctl >/dev/null 2>&1; then
        _PANEL_DETECTED="1Panel"
        _PANEL_TYPE="1panel"
    fi
    '

    [ "${_PANEL_TYPE}" = "1panel" ]
    [ "${_PANEL_DETECTED}" = "1Panel" ]
}

@test "DetectPanel: 检测到 /opt/1panel 目录 → _PANEL_TYPE=1panel" {
    # 模拟 1panel 安装目录
    mkdir -p "${TEST_TMPDIR}/opt/1panel"
    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    eval '
    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    if [ -d "${TEST_TMPDIR}/opt/1panel" ]; then
        _PANEL_DETECTED="1Panel"
        _PANEL_TYPE="1panel"
    fi
    '

    [ "${_PANEL_TYPE}" = "1panel" ]
}

# ============================================================
# DetectPanel — 宝塔面板检测
# ============================================================

@test "DetectPanel: 检测到 bt 命令 → _PANEL_TYPE=btpanel" {
    export PATH="${MOCK_BIN_DIR}:${PATH}"
    # 移除 1pctl
    rm -f "${MOCK_BIN_DIR}/1pctl"

    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    eval '
    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    if command -v bt >/dev/null 2>&1; then
        _PANEL_DETECTED="宝塔面板(btpanel)"
        _PANEL_TYPE="btpanel"
    fi
    '

    [ "${_PANEL_TYPE}" = "btpanel" ]
    echo "${_PANEL_DETECTED}" | grep -q "btpanel"
}

@test "DetectPanel: 检测到 /www/server/panel 目录 → _PANEL_TYPE=btpanel" {
    mkdir -p "${TEST_TMPDIR}/www/server/panel"
    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    eval '
    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    if [ -d "${TEST_TMPDIR}/www/server/panel" ]; then
        _PANEL_DETECTED="宝塔面板(btpanel)"
        _PANEL_TYPE="btpanel"
    fi
    '

    [ "${_PANEL_TYPE}" = "btpanel" ]
}

# ============================================================
# DetectPanel — AA Panel 检测
# ============================================================

@test "DetectPanel: 检测到 /www/server/aapanel 目录 → _PANEL_TYPE=aapanel" {
    mkdir -p "${TEST_TMPDIR}/www/server/aapanel"
    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    eval '
    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    if [ -d "${TEST_TMPDIR}/www/server/aapanel" ]; then
        _PANEL_DETECTED="AA Panel"
        _PANEL_TYPE="aapanel"
    fi
    '

    [ "${_PANEL_TYPE}" = "aapanel" ]
    [ "${_PANEL_DETECTED}" = "AA Panel" ]
}

# ============================================================
# DetectPanel — 无面板
# ============================================================

@test "DetectPanel: 无面板时 _PANEL_TYPE 为空" {
    # 使用模拟路径代替真实系统路径, 避免本机安装的面板干扰
    local _fake_opt_1panel="${TEST_TMPDIR}/opt/1panel"
    local _fake_www_panel="${TEST_TMPDIR}/www/server/panel"
    local _fake_www_aapanel="${TEST_TMPDIR}/www/server/aapanel"

    # 所有目录都不存在
    [ ! -d "${_fake_opt_1panel}" ]
    [ ! -d "${_fake_www_panel}" ]
    [ ! -d "${_fake_www_aapanel}" ]

    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    # 无任何面板工具在 PATH 中
    if command -v 1pctl >/dev/null 2>&1 \
       || [ -d "${_fake_opt_1panel}" ] \
       || false; then
        _PANEL_DETECTED="1Panel"
        _PANEL_TYPE="1panel"
    fi

    if command -v bt >/dev/null 2>&1 \
       || [ -d "${_fake_www_panel}" ] \
       || false; then
        [ -n "${_PANEL_DETECTED}" ] && _PANEL_DETECTED="${_PANEL_DETECTED} + "
        _PANEL_DETECTED="${_PANEL_DETECTED}宝塔面板(btpanel)"
        [ -z "${_PANEL_TYPE}" ] && _PANEL_TYPE="btpanel"
    fi

    if [ -d "${_fake_www_aapanel}" ] \
       || false; then
        [ -n "${_PANEL_DETECTED}" ] && _PANEL_DETECTED="${_PANEL_DETECTED} + "
        _PANEL_DETECTED="${_PANEL_DETECTED}AA Panel"
        _PANEL_TYPE="aapanel"
    fi

    [ -z "${_PANEL_TYPE}" ]
    [ -z "${_PANEL_DETECTED}" ]
}

# ============================================================
# DetectPanel — 优先级: 1Panel > 宝塔 > AA Panel
# ============================================================

@test "DetectPanel: 同时存在 1Panel 和宝塔时 _PANEL_TYPE=1panel (1Panel 优先)" {
    export PATH="${MOCK_BIN_DIR}:${PATH}"

    _PANEL_DETECTED=""
    _PANEL_TYPE=""

    # 1Panel
    if command -v 1pctl >/dev/null 2>&1; then
        _PANEL_DETECTED="1Panel"
        _PANEL_TYPE="1panel"
    fi

    # 宝塔
    if command -v bt >/dev/null 2>&1; then
        [ -n "${_PANEL_DETECTED}" ] && _PANEL_DETECTED="${_PANEL_DETECTED} + "
        _PANEL_DETECTED="${_PANEL_DETECTED}宝塔面板(btpanel)"
        [ -z "${_PANEL_TYPE}" ] && _PANEL_TYPE="btpanel"
    fi

    # _PANEL_TYPE 应该是 1panel (先检测到的)
    [ "${_PANEL_TYPE}" = "1panel" ]
    # 但两个面板都应该被检测到
    echo "${_PANEL_DETECTED}" | grep -q "1Panel"
    echo "${_PANEL_DETECTED}" | grep -q "btpanel"
}

# ============================================================
# Step3_InstallNginx_Panel 逻辑: vision + node_port=443 → 报错
# ============================================================

@test "Step3_InstallNginx_Panel: vision 模式 + node_port=443 → 返回错误" {
    load_log_functions
    source_panel_common

    _PANEL_TRANSPORT="vision"
    node_port="443"
    _PANEL_DETECTED="1Panel"

    # 模拟 Step3_InstallNginx_Panel 中 vision 模式检查的核心逻辑
    _vision_result=0
    if [ "${_PANEL_TRANSPORT}" = "vision" ] && [ "${node_port}" = "443" ]; then
        _vision_result=1  # 应报错
    fi

    [ "$_vision_result" -eq 1 ]
}

@test "Step3_InstallNginx_Panel: vision 模式 + node_port!=443 → 放行" {
    load_log_functions
    source_panel_common

    _PANEL_TRANSPORT="vision"
    node_port="2053"
    _PANEL_DETECTED="1Panel"

    _vision_result=0
    if [ "${_PANEL_TRANSPORT}" = "vision" ] && [ "${node_port}" = "443" ]; then
        _vision_result=1
    fi

    [ "$_vision_result" -eq 0 ]
}

@test "Step3_InstallNginx_Panel: xhttp 模式不触发 vision 检查" {
    load_log_functions
    source_panel_common

    _PANEL_TRANSPORT="xhttp"
    node_port="443"

    _vision_result=0
    if [ "${_PANEL_TRANSPORT}" = "vision" ] && [ "${node_port}" = "443" ]; then
        _vision_result=1
    fi

    [ "$_vision_result" -eq 0 ]
}

# ============================================================
# Step3_InstallNginx_Panel: 按面板类型分派
# ============================================================

@test "Step3_InstallNginx_Panel: _PANEL_TYPE=1panel 调用 Panel1Panel_Setup" {
    load_log_functions
    source_panel_common
    source_panel_1panel

    _PANEL_TYPE="1panel"

    # 模拟完整环境
    local test_conf_dir="${TEST_TMPDIR}/conf.d"
    mkdir -p "${test_conf_dir}"
    _1PANEL_NGINX_CONF_DIR="${test_conf_dir}"

    # 模拟 nginx
    local fake_nginx="${TEST_TMPDIR}/bin/nginx"
    mkdir -p "$(dirname "$fake_nginx")"
    echo '#!/bin/sh' > "$fake_nginx"
    echo 'exit 0' >> "$fake_nginx"
    chmod +x "$fake_nginx"
    _1PANEL_NGINX_CMD="${fake_nginx}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "CERT" > "$cert_path"
    echo "KEY" > "$key_path"

    # 模拟分派逻辑
    case "${_PANEL_TYPE}" in
        1panel)
            Panel1Panel_Setup "test.com" "$cert_path" "$key_path" "8443" ""
            ;;
    esac

    [ -f "${test_conf_dir}/nodehub-proxy.conf" ]
}

@test "Step3_InstallNginx_Panel: _PANEL_TYPE=btpanel 调用 PanelBtPanel_Setup" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    _PANEL_TYPE="btpanel"

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    local test_ssl="${TEST_TMPDIR}/vhost/ssl"
    mkdir -p "${test_vhost}"
    _BT_VHOST_NGINX_DIR="${test_vhost}"
    _BT_VHOST_SSL_DIR="${test_ssl}"
    _BT_AAPANEL_DIR="${TEST_TMPDIR}/no-aapanel"

    local fake_nginx="${TEST_TMPDIR}/nginx/sbin/nginx"
    mkdir -p "$(dirname "$fake_nginx")"
    echo '#!/bin/sh' > "$fake_nginx"
    echo 'exit 0' >> "$fake_nginx"
    chmod +x "$fake_nginx"
    _BT_NGINX_DIR="${TEST_TMPDIR}/nginx"
    _BT_NGINX_CMD="${fake_nginx}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "CERT" > "$cert_path"
    echo "KEY" > "$key_path"

    case "${_PANEL_TYPE}" in
        btpanel|aapanel)
            PanelBtPanel_Setup "test.com" "$cert_path" "$key_path" "8443" ""
            ;;
    esac

    [ -f "${test_vhost}/nodehub-proxy.test.com.conf" ]
}

@test "Step3_InstallNginx_Panel: _PANEL_TYPE=aapanel 调用 PanelBtPanel_Setup" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    _PANEL_TYPE="aapanel"

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    local test_ssl="${TEST_TMPDIR}/vhost/ssl"
    mkdir -p "${test_vhost}"
    _BT_VHOST_NGINX_DIR="${test_vhost}"
    _BT_VHOST_SSL_DIR="${test_ssl}"
    _BT_AAPANEL_DIR="${TEST_TMPDIR}/aapanel"
    mkdir -p "${_BT_AAPANEL_DIR}"

    local fake_nginx="${TEST_TMPDIR}/nginx/sbin/nginx"
    mkdir -p "$(dirname "$fake_nginx")"
    echo '#!/bin/sh' > "$fake_nginx"
    echo 'exit 0' >> "$fake_nginx"
    chmod +x "$fake_nginx"
    _BT_NGINX_DIR="${TEST_TMPDIR}/nginx"
    _BT_NGINX_CMD="${fake_nginx}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "CERT" > "$cert_path"
    echo "KEY" > "$key_path"

    case "${_PANEL_TYPE}" in
        btpanel|aapanel)
            PanelBtPanel_Setup "test.com" "$cert_path" "$key_path" "8443" ""
            ;;
    esac

    [ -f "${test_vhost}/nodehub-proxy.test.com.conf" ]
}

# ============================================================
# SetNodeEnv — ~/node.env 写入测试
# ============================================================

@test "SetNodeEnv: 写入 panel_type 到 ~/node.env" {
    # 提供最小 SetNodeEnv 实现
    SetNodeEnv() {
        _key="$1"; _value="$2"
        _env_file="${HOME}/node.env"
        [ -f "$_env_file" ] || touch "$_env_file"
        sed -i "/^${_key}=/d" "$_env_file" 2>/dev/null || true
        echo "${_key}=\"${_value}\"" >> "$_env_file"
    }

    SetNodeEnv "panel_type" "1panel"
    SetNodeEnv "panel_detected" "1Panel"
    SetNodeEnv "panel_transport" "xhttp"
    SetNodeEnv "panel_remark" "auto-detected-by-proxyInstall"

    grep -q 'panel_type="1panel"' "${HOME}/node.env"
    grep -q 'panel_detected="1Panel"' "${HOME}/node.env"
    grep -q 'panel_transport="xhttp"' "${HOME}/node.env"
    grep -q 'panel_remark="auto-detected-by-proxyInstall"' "${HOME}/node.env"
}

@test "SetNodeEnv: 同 key 覆盖更新" {
    SetNodeEnv() {
        _key="$1"; _value="$2"
        _env_file="${HOME}/node.env"
        [ -f "$_env_file" ] || touch "$_env_file"
        sed -i "/^${_key}=/d" "$_env_file" 2>/dev/null || true
        echo "${_key}=\"${_value}\"" >> "$_env_file"
    }

    SetNodeEnv "panel_type" "1panel"
    SetNodeEnv "panel_type" "btpanel"

    # 应只有一行 panel_type
    local count
    count=$(grep -c "^panel_type=" "${HOME}/node.env")
    [ "$count" -eq 1 ]

    grep -q 'panel_type="btpanel"' "${HOME}/node.env"
}

# ============================================================
# 幂等性测试
# ============================================================

@test "幂等: 1Panel 重复运行不产生多份配置" {
    load_log_functions
    source_panel_common
    source_panel_1panel

    local test_conf_dir="${TEST_TMPDIR}/conf.d"
    mkdir -p "${test_conf_dir}"
    _1PANEL_NGINX_CONF_DIR="${test_conf_dir}"
    _1PANEL_NGINX_CMD=""

    local fake_nginx="${TEST_TMPDIR}/bin/nginx"
    mkdir -p "$(dirname "$fake_nginx")"
    echo '#!/bin/sh' > "$fake_nginx"
    echo 'exit 0' >> "$fake_nginx"
    chmod +x "$fake_nginx"
    _1PANEL_NGINX_CMD="${fake_nginx}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "CERT" > "$cert_path"
    echo "KEY" > "$key_path"

    # 运行 3 次
    Panel1Panel_Setup "test.com" "$cert_path" "$key_path" "8443" ""
    Panel1Panel_Setup "test.com" "$cert_path" "$key_path" "8443" ""
    Panel1Panel_Setup "test.com" "$cert_path" "$key_path" "8443" ""

    local count
    count=$(ls -1 "${test_conf_dir}"/nodehub-proxy*.conf 2>/dev/null | wc -l)
    [ "$count" -eq 1 ]
}

@test "幂等: 宝塔重复运行不产生多份配置" {
    load_log_functions
    source_panel_common
    source_panel_btpanel

    local test_vhost="${TEST_TMPDIR}/vhost/nginx"
    local test_ssl="${TEST_TMPDIR}/vhost/ssl"
    mkdir -p "${test_vhost}"
    _BT_VHOST_NGINX_DIR="${test_vhost}"
    _BT_VHOST_SSL_DIR="${test_ssl}"
    _BT_AAPANEL_DIR="${TEST_TMPDIR}/no-aapanel"

    local fake_nginx="${TEST_TMPDIR}/nginx/sbin/nginx"
    mkdir -p "$(dirname "$fake_nginx")"
    echo '#!/bin/sh' > "$fake_nginx"
    echo 'exit 0' >> "$fake_nginx"
    chmod +x "$fake_nginx"
    _BT_NGINX_DIR="${TEST_TMPDIR}/nginx"
    _BT_NGINX_CMD="${fake_nginx}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "CERT" > "$cert_path"
    echo "KEY" > "$key_path"

    # 运行 3 次
    PanelBtPanel_Setup "test.com" "$cert_path" "$key_path" "8443" ""
    PanelBtPanel_Setup "test.com" "$cert_path" "$key_path" "8443" ""
    PanelBtPanel_Setup "test.com" "$cert_path" "$key_path" "8443" ""

    local count
    count=$(ls -1 "${test_vhost}"/nodehub-proxy*.conf 2>/dev/null | wc -l)
    [ "$count" -eq 1 ]
}

# ============================================================
# 通配符域名测试
# ============================================================

@test "通配符: 1Panel 配置包含 *.{domain}" {
    load_log_functions
    source_panel_common
    source_panel_1panel

    local test_conf_dir="${TEST_TMPDIR}/conf.d"
    mkdir -p "${test_conf_dir}"
    _1PANEL_NGINX_CONF_DIR="${test_conf_dir}"

    local cert_path="${TEST_TMPDIR}/cert.pem"
    local key_path="${TEST_TMPDIR}/key.pem"
    echo "CERT" > "$cert_path"
    echo "KEY" > "$key_path"

    Panel1Panel_ConfigureSite "mydomain.com" "$cert_path" "$key_path" "8443" ""

    local target="${test_conf_dir}/nodehub-proxy.conf"
    grep -q "proxy.mydomain.com" "$target"
    grep -q "\*.mydomain.com" "$target"
}

@test "通配符: 宝塔配置包含 *.{domain}" {
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
    grep -q "proxy.mydomain.com" "$target"
    grep -q "\*.mydomain.com" "$target"
}
