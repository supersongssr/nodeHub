#!/bin/sh
# ============================================================
# panel-common.sh — 面板 Nginx 代理配置的共享函数库
# 被 panel-1panel.sh / panel-btpanel.sh source 引入
# ============================================================

# 全局标记: 是否已 source (防止重复引入)
[ -n "${_PANEL_COMMON_LOADED:-}" ] && return 0
_PANEL_COMMON_LOADED=1

# ============================================================
# 从面板下载的 proxy.conf 中提取关键配置
# 输入: $1 = proxy.conf 文件路径
# 输出变量: _extracted_upstream (xray 后端端口)
#           _extracted_server_names
#           _extracted_xhttp_path (xhttp 分流路径)
# ============================================================
ParsePanelProxyConf() {
    _conf_file="$1"
    if [ ! -f "$_conf_file" ]; then
        log error "ParsePanelProxyConf: 文件不存在 ${_conf_file}"
        return 1
    fi

    # 提取 upstream 中的 xray 后端端口
    _extracted_upstream=$(grep -oP 'server\s+127\.0\.0\.1:\K[0-9]+' "$_conf_file" 2>/dev/null | head -1 || true)
    [ -z "$_extracted_upstream" ] && _extracted_upstream=$(grep -oP 'proxy_pass\s+http://127\.0\.0\.1:\K[0-9]+' "$_conf_file" 2>/dev/null | head -1 || true)
    [ -z "$_extracted_upstream" ] && _extracted_upstream="8443"

    # 提取 server_name
    _extracted_server_names=$(grep -oP 'server_name\s+\K[^;]+' "$_conf_file" 2>/dev/null | head -1 || true)

    # 提取 xhttp 相关路径 (如 /xtp-xxxx )
    _extracted_xhttp_path=$(grep -oP 'location\s+(/\S+)' "$_conf_file" 2>/dev/null | awk '{print $2}' | head -1 || true)

    log info "proxy.conf 解析: upstream_port=${_extracted_upstream} server_names=${_extracted_server_names} xhttp_path=${_extracted_xhttp_path:-无}"
}

# ============================================================
# 检测传输模式: xhttp / vision / 其他
# 从 ~/node.json 的 v2_name 判断:
#   v2_name 含 "xhttp" → xhttp 模式
#   否则 → vision / other
# 输出: _TRANSPORT_MODE = "xhttp" | "vision" | "other"
# ============================================================
DetectTransportMode() {
    _TRANSPORT_MODE="other"

    if [ -f ~/node.json ]; then
        _v2_name=$(jq -r '.v2_name // empty' ~/node.json 2>/dev/null || true)
        case "$_v2_name" in
            *xhttp*)
                _TRANSPORT_MODE="xhttp"
                ;;
            *)
                # 非 xhttp 类协议, 按实际名称细分
                case "$_v2_name" in
                    *vision*|*reality*)
                        _TRANSPORT_MODE="vision"
                        ;;
                esac
                ;;
        esac
        log info "传输模式检测: ${_TRANSPORT_MODE} (v2_name=${_v2_name:-空})"
    else
        log warn "DetectTransportMode: ~/node.json 不存在，默认 other"
    fi
}

# ============================================================
# 检测 443 端口是否被占用
# 输出: _PORT443_OWNER = 占用者名称 (如 "nginx", "xray", "") 
# ============================================================
Detect443Usage() {
    _PORT443_OWNER=""
    _443_listener=$(ss -tlnp 2>/dev/null | grep ':443 ' | head -1 || true)
    if [ -n "$_443_listener" ]; then
        _PORT443_OWNER=$(echo "$_443_listener" | grep -oP 'users:\(\("\K[^"]+' || true)
        [ -z "$_PORT443_OWNER" ] && _PORT443_OWNER="unknown"
        log info "443 端口被占用: ${_PORT443_OWNER}"
    else
        log info "443 端口空闲"
    fi
}

# ============================================================
# 为面板生成 proxy.{domain} 通配符网站的 nginx 配置
# 参数: $1=root_domain, $2=ssl_cert_path, $3=ssl_key_path
#       $4=xray_upstream_port, $5=panel_proxy_conf (从面板API下发的配置)
# 输出: stdout = 生成的 nginx server 配置
#
# xhttp 模式下, 从面板下发的 proxy.conf 中提取所有 location 块
# 附加到生成的 server block 中, 其余路径走默认 proxy_pass
# ============================================================
GenerateProxyServerBlock() {
    _domain="$1"
    _cert="$2"
    _key="$3"
    _xray_port="$4"
    _panel_conf="$5"

    # 提取面板下发 proxy.conf 中的所有 location 块
    _location_blocks=""
    if [ -f "$_panel_conf" ] && [ -s "$_panel_conf" ]; then
        # 提取所有 location { ... } 块 (包括嵌套花括号)
        # 使用 awk 而非 sed, 更可靠地匹配多行 location 块
        # 跳过 location / 和 location = / 因为我们会生成自己的默认回退
        # 将 proxy_pass http://upstream_name 替换为 127.0.0.1:port
        _location_blocks=$(awk -v xp="${_xray_port}" '
            /^[[:space:]]*location[[:space:]]*\/[[:space:]*{]/ { skip=1 }
            /^[[:space:]]*location[[:space:]]*=[[:space:]]*\/[[:space:]*{]/ { skip=1 }
            /^[[:space:]]*location[[:space:]]/ && !skip { capturing=1; depth=0 }
            capturing {
                gsub(/proxy_pass[[:space:]]+http:\/\/[^;]+;/, "proxy_pass http://127.0.0.1:" xp ";")
                print
                n_open = gsub(/\{/, "{")
                n_close = gsub(/\}/, "}")
                depth += n_open - n_close
                if (depth <= 0) { capturing=0 }
            }
            skip && /^[[:space:]]*}/ { skip=0 }
        ' "$_panel_conf" 2>/dev/null | sed 's/^/    /' || true)
    fi

    # 生成统一的 proxy.{domain} 通配符 server block
    # 接收所有 *.{domain} 和 proxy.{domain} 的请求
    cat << SERVERBLOCK_EOF
# ============================================================
# NodeHub Proxy — 自动生成 (面板模式)
# 域名: proxy.${_domain} + *.${_domain}
# 后端: xray 127.0.0.1:${_xray_port}
# 由 proxyInstall.sh 面板集成脚本维护，勿手动修改
# ============================================================

# HTTP → HTTPS 跳转
server {
    listen 80;
    listen [::]:80;
    server_name proxy.${_domain} *.${_domain};
    return 301 https://\$host\$request_uri;
}

# HTTPS 反向代理 → xray
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name proxy.${_domain} *.${_domain};

    ssl_certificate ${_cert};
    ssl_certificate_key ${_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # --- xhttp 分流路径 (从面板下发的配置中提取) ---
${_location_blocks}
    # --- 默认回退: 转发到 xray ---
    location / {
        proxy_pass http://127.0.0.1:${_xray_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # xhttp (WebSocket/SSE) 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
SERVERBLOCK_EOF
}
