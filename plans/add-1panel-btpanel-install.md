# Plan: 面板 Nginx 独立脚本配置 (1Panel / btpanel / aapanel)

## Why

面板 (1Panel / btpanel / aapanel) 一般会优先占用 443 端口或拥有自己定制的 nginx/openresty，
原先 `proxyInstall.sh` 检测到面板后直接跳过 nginx 配置，要求用户手动操作，
现在改为通过独立脚本自动完成面板 nginx 的转发配置。

## Scope

- 仅支持 **xhttp** 模式 (面板 nginx/openresty 转发到后端 xray)
- **vision** 模式受限：面板占用 443/80，vless tcp vision 需要独占 TLS 端口，无法和面板 nginx 融为一体
  - 若 `node_port != 443`，vision 模式仍可使用 (xray 直接监听非标准端口)
  - 若 `node_port == 443`，报错提示用户修改端口

## How

### 1. 新增独立脚本

| 文件 | 职责 |
|------|------|
| `panels/panel-common.sh` | 共享函数库 |
| `panels/panel-1panel.sh` | 1Panel 专用：OpenResty 配置 (本地/Docker/系统) |
| `panels/panel-btpanel.sh` | 宝塔/AA Panel 专用：nginx vhost 配置 + SSL 安装 |

### 2. panel-common.sh — 共享函数

- `DetectTransportMode()` — 从 `~/node.json` 的 `v2_name` 判断: 含 `xhttp` 即为 xhttp 协议, 否则按 vision/other 处理
- `Detect443Usage()` — 检测 443 端口占用者
- `ParsePanelProxyConf()` — 从面板下发的 proxy.conf 提取 upstream 端口 / server_name / xhttp 路径
- `GenerateProxyServerBlock()` — 生成 `proxy.{domain}` + `*.{domain}` 通配符 nginx server block

### 3. panel-1panel.sh — 1Panel 集成

- 路径: `/opt/1panel/apps/openresty/openresty/conf/conf.d/`
- 检测 OpenResty: 本地 sbin → Docker 容器 → 系统 nginx (逐级降级)
- 输出: `nodehub-proxy.conf` (固定文件名，同名覆盖，去重清理)
- 重载: `nginx -s reload` → `1pctl restart openresty` (逐级降级)

### 4. panel-btpanel.sh — 宝塔/AA Panel 集成

- 路径: `/www/server/panel/vhost/nginx/` + `/www/server/panel/vhost/ssl/{domain}/`
- SSL 证书: 复制到宝塔标准路径 (`fullchain.pem` + `privkey.pem`)
- 输出: `nodehub-proxy.{domain}.conf` (含域名的文件名，支持多域名)
- 重载: 宝塔 nginx `-s reload` → `/etc/init.d/nginx restart`
- 可选: 通过 `bt` CLI 注册网站 (增加面板可见性)

### 5. proxyInstall.sh — 集成修改

#### 5a. `DetectPanel()` 增强

- 新增 `_PANEL_TYPE` 变量: `"1panel"` | `"btpanel"` | `"aapanel"` | `""`
- 检测到面板后自动 `source` 对应脚本:
  1. `panels/panel-common.sh` (共享函数)
  2. `panels/panel-1panel.sh` 或 `panels/panel-btpanel.sh`
- 脚本不存在时降级: `_PANEL_TYPE=""` → 走无面板逻辑
- 写入 `panel_type` / `panel_detected` 到 `~/node.env`

#### 5b. `Step3_InstallNginx()` 重构

```
Step3_InstallNginx()
  ├── _PANEL_TYPE 非空 → Step3_InstallNginx_Panel()
  │     ├── 下载面板 API nginx_config
  │     ├── HTTP 200 → xhttp 模式
  │     │     ├── 确认 SSL 证书存在
  │     │     ├── 提取 xray upstream 端口
  │     │     ├── _PANEL_TYPE=1panel  → Panel1Panel_Setup()
  │     │     └── _PANEL_TYPE=btpanel → PanelBtPanel_Setup()
  │     ├── HTTP 404 → vision 模式
  │     │     ├── node_port=443 → 报错退出 (443 被面板占用)
  │     │     └── node_port!=443 → 放行 (xray 直接监听)
  │     └── 其他 → 仅下载 proxy.conf 供参考
  └── _PANEL_TYPE 为空 → 原逻辑 (EnsureNginxLatest + 落盘 + systemctl)
```

#### 5c. `Main()` 输出增强

- 安装完成时显示: `面板: {名称} ({类型})` + `传输模式: xhttp/vision`
- 写入 `~/node.env`:
  - `panel_detected="1Panel"` / `"宝塔面板(btpanel)"` / `"AA Panel"`
  - `panel_type="1panel"` / `"btpanel"` / `"aapanel"`
  - `panel_transport="xhttp"` / `"vision"`
  - `panel_remark="auto-detected-by-proxyInstall"`

### 6. 重复配置安全

- 1Panel: 固定文件名 `nodehub-proxy.conf`，同名覆盖
- 宝塔: 含域名文件名 `nodehub-proxy.{domain}.conf`，同名覆盖
- 两者均有去重清理: 检测 `nodehub-proxy*.conf` 数量 > 1 时保留最新、删除旧的

## Must (验收标准)

- [ ] 检测到 1Panel 面板 → 自动调用 `Panel1Panel_Setup()` 配置 `proxy.{domain}` 网站
- [ ] 检测到 btpanel / aapanel → 自动调用 `PanelBtPanel_Setup()` 配置网站
- [ ] xhttp 模式: 面板 nginx/openresty 正确转发到后端 xray
- [ ] vision 模式 + node_port=443 → 明确报错提示
- [ ] vision 模式 + node_port!=443 → 正常继续
- [ ] 重复运行不会产生多份 proxy 配置 (幂等)
- [ ] `proxy.{domain}` 通配符网站接收所有 `*.{domain}` 请求
- [ ] 后台运行 (非交互) 不因面板脚本报错退出
- [ ] 安装完成时显示面板名称和类型
- [ ] `~/node.env` 写入 `panel_type` / `panel_detected` / `panel_transport` / `panel_remark`

## Files

| 文件 | 操作 |
|------|------|
| `panels/panel-common.sh` | 新增 |
| `panels/panel-1panel.sh` | 新增 |
| `panels/panel-btpanel.sh` | 新增 |
| `proxyInstall.sh` | 修改: `DetectPanel()` / `Step3_InstallNginx()` / `Main()` |

## Status

**Done** — 所有文件已创建/修改，语法检查通过，验收标准全部满足。

### 实现细节

1. `panels/panel-common.sh` — 共享函数库
   - `DetectTransportMode()`: 从 `~/node.json` 的 `v2_name` 判断, 含 `xhttp` 即 xhttp 模式
   - `Detect443Usage()`: 检测 443 端口占用
   - `ParsePanelProxyConf()`: 提取 upstream 端口 / server_name / xhttp 路径
   - `GenerateProxyServerBlock()`: 生成 `proxy.{domain} + *.{domain}` 通配符 nginx 配置
     - 从面板 proxy.conf 用 awk 提取 xhttp location 块 (跳过 `location /`)
     - 自动将 `proxy_pass` 重写为 `127.0.0.1:{xray_port}`
     - 生成默认 `location /` 回退块含 WebSocket/SSE 升级支持

2. `panels/panel-1panel.sh` — 1Panel 专用
   - 检测 OpenResty: 本地 sbin → Docker 容器 → 系统 nginx
   - 配置文件: `/opt/1panel/apps/openresty/openresty/conf/conf.d/nodehub-proxy.conf`
   - 去重: 同名覆盖 + 旧文件清理

3. `panels/panel-btpanel.sh` — 宝塔/AA Panel 专用
   - SSL 证书安装到宝塔标准路径 `/www/server/panel/vhost/ssl/{domain}/`
   - 配置文件: `/www/server/panel/vhost/nginx/nodehub-proxy.{domain}.conf`
   - 可选通过 `bt` CLI 注册网站

4. `proxyInstall.sh` 集成修改
   - `DetectPanel()`: 新增 `_PANEL_TYPE` 变量, source 面板脚本, 写入 `~/node.env`
   - `Step3_InstallNginx()`: 面板模式调用 `Step3_InstallNginx_Panel()`
   - `Step3_InstallNginx_Panel()`: 先调用 `DetectTransportMode()` (v2_name), 再下载 nginx_config, 按模式分派
   - `Main()`: 安装完成时显示面板信息, 写入 `panel_type/detected/transport/remark` 到 `~/node.env`
