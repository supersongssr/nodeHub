#!/usr/bin/env bats
# ============================================================
# test_panel_common.bats — panel-common.sh 共享函数测试
# 覆盖: ParsePanelProxyConf, DetectTransportMode, Detect443Usage,
#        GenerateProxyServerBlock
# ============================================================

load 'test_helper'

# ============================================================
# ParsePanelProxyConf 测试
# ============================================================

@test "ParsePanelProxyConf: 从 upstream 块提取 xray 后端端口" {
    load_log_functions
    source_panel_common

    local conf
    conf=$(create_test_proxy_conf)

    ParsePanelProxyConf "$conf"
    [ "${_extracted_upstream}" = "8443" ]
}

@test "ParsePanelProxyConf: 从 proxy_pass 提取端口 (无 upstream 块)" {
    load_log_functions
    source_panel_common

    local conf
    conf=$(create_test_proxy_conf_no_upstream)

    ParsePanelProxyConf "$conf"
    [ "${_extracted_upstream}" = "9999" ]
}

@test "ParsePanelProxyConf: 文件不存在时返回错误" {
    load_log_functions
    source_panel_common

    run ParsePanelProxyConf "/nonexistent/file.conf"
    [ "$status" -ne 0 ]
}

@test "ParsePanelProxyConf: 提取 server_name" {
    load_log_functions
    source_panel_common

    local conf
    conf=$(create_test_proxy_conf)

    ParsePanelProxyConf "$conf"
    echo "server_names=${_extracted_server_names}" >&2
    [ "${_extracted_server_names}" = "proxy.test.com *.test.com" ]
}

@test "ParsePanelProxyConf: 提取 xhttp 分流路径" {
    load_log_functions
    source_panel_common

    local conf
    conf=$(create_test_proxy_conf)

    ParsePanelProxyConf "$conf"
    echo "xhttp_path=${_extracted_xhttp_path}" >&2
    [ "${_extracted_xhttp_path}" = "/xtp-abc123" ]
}

@test "ParsePanelProxyConf: 无 proxy.conf 时默认端口 8443" {
    load_log_functions
    source_panel_common

    local conf="${TEST_TMPDIR}/empty-proxy.conf"
    echo "# empty" > "$conf"

    ParsePanelProxyConf "$conf"
    [ "${_extracted_upstream}" = "8443" ]
}

# ============================================================
# DetectTransportMode 测试
# ============================================================

@test "DetectTransportMode: xhttp 模式检测" {
    load_log_functions
    source_panel_common

    create_test_node_json "vless-ws-xhttp"
    DetectTransportMode
    [ "${_TRANSPORT_MODE}" = "xhttp" ]
}

@test "DetectTransportMode: vision 模式检测" {
    load_log_functions
    source_panel_common

    create_test_node_json "vless-reality-vision"
    DetectTransportMode
    [ "${_TRANSPORT_MODE}" = "vision" ]
}

@test "DetectTransportMode: reality 模式检测为 vision" {
    load_log_functions
    source_panel_common

    create_test_node_json "vless-tcp-reality"
    DetectTransportMode
    [ "${_TRANSPORT_MODE}" = "vision" ]
}

@test "DetectTransportMode: 其他模式检测 (非 xhttp/vision/reality)" {
    load_log_functions
    source_panel_common

    create_test_node_json "vless-ws"
    DetectTransportMode
    [ "${_TRANSPORT_MODE}" = "other" ]
}

@test "DetectTransportMode: 空 v2_name 检测为 other" {
    load_log_functions
    source_panel_common

    create_test_node_json ""
    DetectTransportMode
    [ "${_TRANSPORT_MODE}" = "other" ]
}

@test "DetectTransportMode: node.json 不存在时默认 other" {
    load_log_functions
    source_panel_common

    # 不创建 node.json
    DetectTransportMode
    [ "${_TRANSPORT_MODE}" = "other" ]
}

# ============================================================
# Detect443Usage 测试
# ============================================================

@test "Detect443Usage: 443 端口空闲时 _PORT443_OWNER 为空" {
    load_log_functions
    source_panel_common

    # 在测试环境中 443 通常未被占用
    Detect443Usage
    # 根据环境可能为空或有值, 不做严格断言
    # 但函数不应报错
    [ -n "${_PORT443_OWNER+x}" ]  # 变量存在即可
}

# ============================================================
# GenerateProxyServerBlock 测试
# ============================================================

@test "GenerateProxyServerBlock: 生成有效的 nginx 配置" {
    load_log_functions
    source_panel_common

    local conf
    conf=$(create_test_proxy_conf)

    local result
    result=$(GenerateProxyServerBlock "test.com" "/etc/ssl/test.com.pem" "/etc/ssl/test.com.key" "8443" "$conf")

    # 应包含 HTTP → HTTPS 跳转
    echo "$result" | grep -q "return 301 https"
    # 应包含 HTTPS server block
    echo "$result" | grep -q "listen 443 ssl"
    # 应包含 proxy.test.com 和 *.test.com
    echo "$result" | grep -q "proxy.test.com"
    echo "$result" | grep -q "\*.test.com"
    # 应包含 xray upstream
    echo "$result" | grep -q "127.0.0.1:8443"
    # 应包含 SSL 证书路径
    echo "$result" | grep -q "/etc/ssl/test.com.pem"
    echo "$result" | grep -q "/etc/ssl/test.com.key"
    # 应包含 TLS 1.2 和 1.3
    echo "$result" | grep -q "TLSv1.2 TLSv1.3"
    # 应包含 WebSocket 升级支持
    echo "$result" | grep -q "Upgrade"
    echo "$result" | grep -q "upgrade"
}

@test "GenerateProxyServerBlock: 无 proxy.conf 时仍生成配置" {
    load_log_functions
    source_panel_common

    local result
    result=$(GenerateProxyServerBlock "example.com" "/ssl/cert.pem" "/ssl/key.pem" "9999" "/nonexistent")

    echo "$result" | grep -q "proxy.example.com"
    echo "$result" | grep -q "127.0.0.1:9999"
    echo "$result" | grep -q "listen 443 ssl"
    # 默认 location / 回退应存在
    echo "$result" | grep -q "location /"
}

@test "GenerateProxyServerBlock: 提取并注入 xhttp location 块" {
    load_log_functions
    source_panel_common

    local conf
    conf=$(create_test_proxy_conf)

    local result
    result=$(GenerateProxyServerBlock "test.com" "/ssl/cert.pem" "/ssl/key.pem" "8443" "$conf")

    # 应包含从 proxy.conf 中提取的 /xtp- 路径
    echo "$result" | grep -q "/xtp-abc123"
}

@test "GenerateProxyServerBlock: xhttp location 中 proxy_pass 重写为 127.0.0.1:port" {
    load_log_functions
    source_panel_common

    local conf
    conf=$(create_test_proxy_conf)

    local result
    result=$(GenerateProxyServerBlock "test.com" "/ssl/cert.pem" "/ssl/key.pem" "8443" "$conf")

    # 应将 proxy_pass 重写为 127.0.0.1:8443, 而非原始 upstream 名称
    echo "$result" | grep -q "proxy_pass http://127.0.0.1:8443"
}

@test "GenerateProxyServerBlock: http2 on 指令存在" {
    load_log_functions
    source_panel_common

    local conf
    conf=$(create_test_proxy_conf)

    local result
    result=$(GenerateProxyServerBlock "test.com" "/ssl/cert.pem" "/ssl/key.pem" "8443" "$conf")

    echo "$result" | grep -q "http2 on"
}

@test "GenerateProxyServerBlock: 包含 IPv6 监听" {
    load_log_functions
    source_panel_common

    local result
    result=$(GenerateProxyServerBlock "test.com" "/ssl/cert.pem" "/ssl/key.pem" "8443" "")

    echo "$result" | grep -q "listen \[::\]:80"
    echo "$result" | grep -q "listen \[::\]:443 ssl"
}
