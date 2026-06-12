#!/usr/bin/env bats
# ============================================================
# test_helper.bash — 共享测试辅助函数
# 所有测试文件通过: load 'test_helper'
# ============================================================

# 设置项目根目录
PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
PANELS_DIR="${PROJECT_ROOT}/panels"
TEST_TMPDIR=""

# 每个测试前的 setup
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="${TEST_TMPDIR}"
    export _PANEL_COMMON_LOADED=""
    export _PANEL_1PANEL_LOADED=""
    export _PANEL_BTPANEL_LOADED=""

    # 创建测试用的 node.env
    touch "${TEST_TMPDIR}/node.env"

    # 模拟 log 函数 (防止写入 ~/nodeLogs 到真实 HOME)
    # 面板脚本中的 log 函数会使用 ~/nodeLogs, 不影响测试
}

# 每个测试后的 teardown
teardown() {
    if [ -d "${TEST_TMPDIR}" ]; then
        rm -rf "${TEST_TMPDIR}"
    fi
}

# ============================================================
# 辅助函数: 创建测试用的 SSL 证书文件
# ============================================================
create_test_ssl_certs() {
    local cert_dir="${TEST_TMPDIR}/ssl"
    mkdir -p "${cert_dir}"
    echo "FAKE CERT DATA" > "${cert_dir}/test.com.pem"
    echo "FAKE KEY DATA" > "${cert_dir}/test.com.key"
    echo "${cert_dir}/test.com.pem"
}

# ============================================================
# 辅助函数: 创建测试用的 node.json (含 v2_name)
# 参数: $1=v2_name 值
# ============================================================
create_test_node_json() {
    local v2_name="${1:-}"
    cat > "${TEST_TMPDIR}/node.json" <<EOF
{
  "node_id": "test-001",
  "v2_name": "${v2_name}",
  "node_port": 443
}
EOF
}

# ============================================================
# 辅助函数: 创建模拟的面板 proxy.conf
# ============================================================
create_test_proxy_conf() {
    local conf_path="${TEST_TMPDIR}/panel-proxy.conf"
    cat > "${conf_path}" <<'EOF'
upstream xray_backend {
    server 127.0.0.1:8443;
}

server {
    listen 443 ssl;
    server_name proxy.test.com *.test.com;

    ssl_certificate /etc/ssl/test.com.pem;
    ssl_certificate_key /etc/ssl/test.com.key;

    location /xtp-abc123 {
        proxy_pass http://xray_backend;
        proxy_set_header Host $host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location / {
        proxy_pass http://xray_backend;
    }
}
EOF
    echo "${conf_path}"
}

# ============================================================
# 辅助函数: 创建模拟的 proxy.conf (无 upstream, 直接 proxy_pass)
# ============================================================
create_test_proxy_conf_no_upstream() {
    local conf_path="${TEST_TMPDIR}/panel-proxy-no-upstream.conf"
    cat > "${conf_path}" <<'EOF'
server {
    listen 443 ssl;
    server_name proxy.test.com;

    ssl_certificate /etc/ssl/test.com.pem;
    ssl_certificate_key /etc/ssl/test.com.key;

    location /xtp-xyz789 {
        proxy_pass http://127.0.0.1:9999;
    }

    location / {
        proxy_pass http://127.0.0.1:9999;
    }
}
EOF
    echo "${conf_path}"
}

# ============================================================
# 辅助函数: 加载 log 函数 (从 proxyInstall.sh 提取)
# ============================================================
load_log_functions() {
    # 提供 log 和 SetNodeEnv 的最小实现
    eval '
    log() {
        _level="$1"; shift
        : "$@"
    }
    '
    eval '
    SetNodeEnv() {
        _key="$1"; _value="$2"
        _env_file="${HOME}/node.env"
        [ -f "$_env_file" ] || touch "$_env_file"
        flock /tmp/nodeEnv.lock sed -i "/^${_key}=/d" "$_env_file" 2>/dev/null || true
        echo "${_key}=\"${_value}\"" >> "$_env_file"
    }
    '
}

# ============================================================
# 辅助函数: source panel-common.sh
# ============================================================
source_panel_common() {
    . "${PANELS_DIR}/panel-common.sh"
}

# ============================================================
# 辅助函数: source panel-1panel.sh
# ============================================================
source_panel_1panel() {
    . "${PANELS_DIR}/panel-1panel.sh"
}

# ============================================================
# 辅助函数: source panel-btpanel.sh
# ============================================================
source_panel_btpanel() {
    . "${PANELS_DIR}/panel-btpanel.sh"
}
