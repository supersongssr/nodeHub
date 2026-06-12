# proxyInstall.sh Bug Fix 总结

**日期**: 2026-06-12  
**目标服务器**: 198.12.124.74 (1Panel 面板节点)  
**状态**: ✅ 已修复并验证通过

---

## 问题分析

### 错误现象
```
proxyInstall.sh: 1176: DetectTransportMode: not found
2026-06-12 20-51-11 [FATAL] 💥 命令失败 — 退出码=127
```

### 根本原因

**三级故障链**：

1. **`panels/` 目录未部署到 NODEHUB_URL 服务器**
   - `proxyInstall.sh` 的面板模式依赖 `panels/panel-common.sh`、`panels/panel-1panel.sh`、`panels/panel-btpanel.sh` 三个外部脚本
   - 脚本通过 `DetectPanel()` → source 的方式加载这些函数
   - 搜索路径：`脚本同目录/panels` → `~/panels` → 从 `NODEHUB_URL/panels/` 下载
   - 当脚本被上传到 `/tmp` 执行时，`/tmp/panels/` 和 `~/panels/` 均不存在
   - `NODEHUB_URL/panels/` (kod.freessr.bid/node_hub/panels/) 也返回 404 — 因为从未部署过

2. **搜索路径缺少 `/tmp/panels`**
   - 脚本上传到 `/tmp` 并同时上传 `panels/` 到 `/tmp/panels/`，但搜索路径中不包含 `/tmp/panels`

3. **即使 panels 找到后仍有兼容性问题**（后续发现）：
   - `panel-common.sh` 的 `GenerateProxyServerBlock()` 使用 `http2 on;` (nginx >= 1.25.1 新语法)
   - 1Panel 使用 OpenResty 1.21.4.3 (nginx 1.21.4)，仅支持旧语法 `listen 443 ssl http2;`
   - SSL 证书路径 `/etc/ssl/` 未映射到 Docker 容器内，导致容器内 nginx 找不到证书

---

## 修复内容

### 1. `proxyInstall.sh` — 添加 `/tmp/panels` 搜索路径

**位置**: `DetectPanel()` 函数 (约 L561)

```diff
- # 查找路径: 1) 脚本同目录/panels  2) ~/panels  3) 从 NODEHUB_URL 下载
+ # 查找路径: 1) 脚本同目录/panels  2) /tmp/panels  3) ~/panels  4) 从 NODEHUB_URL 下载
  for _d in "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/panels" \
+   "/tmp/panels" \
    "$HOME/panels"; do
```

### 2. `proxyInstall.sh` — `Step3_InstallNginx_Panel()` 增加健壮性

**位置**: `Step3_InstallNginx_Panel()` 函数入口 (约 L1172)

- 增加 `DetectTransportMode` 函数存在性检查
- 如果未定义，尝试重新搜索并 source `panel-common.sh`
- 如果仍找不到，使用**内联兜底实现**检测传输模式 (xhttp/vision/other)
- 对 `Detect443Usage`、`ParsePanelProxyConf` 同样增加兜底处理

### 3. `panels/panel-common.sh` — 修复 nginx http2 语法兼容性

**位置**: `GenerateProxyServerBlock()` (约 L143)

```diff
  server {
-     listen 443 ssl;
-     listen [::]:443 ssl;
-     http2 on;
+     listen 443 ssl http2;
+     listen [::]:443 ssl http2;
```

**原因**: `http2 on;` 仅 nginx >= 1.25.1 支持；旧版 OpenResty/nginx 使用 `listen 443 ssl http2;`

### 4. `panels/panel-1panel.sh` — Docker 容器 SSL 证书路径映射

**位置**: `Panel1Panel_ConfigureSite()` (约 L75)

Docker 模式下，将宿主机 `/etc/ssl/xxx.pem` 复制到容器可访问路径：
- 宿主机: `/opt/1panel/apps/openresty/openresty/www/ssl/`
- 容器内: `/www/ssl/` (通过 Docker volume 映射)

### 5. 部署 `panels/` 到 NODEHUB_URL 服务器

将 `panels/` 目录部署到 `kod.freessr.bid:/www/wwwroot/kod.freessr.bid/node_hub/panels/`，确保远程下载路径可用。

---

## 修改文件清单

| 文件 | 修改类型 | 说明 |
|------|----------|------|
| `proxyInstall.sh` | 增强 | 添加 `/tmp/panels` 搜索路径；`Step3_InstallNginx_Panel()` 添加函数缺失检测与兜底逻辑 |
| `panels/panel-common.sh` | 修复 | `http2 on;` → `listen 443 ssl http2;` (兼容旧版 nginx/OpenResty) |
| `panels/panel-1panel.sh` | 修复 | Docker 模式下 SSL 证书路径映射 (宿主机 → 容器内) |
| `NODEHUB_URL 服务器` | 部署 | `panels/` 目录上传到 `kod.freessr.bid/node_hub/panels/` |

---

## 验证结果

在 198.12.124.74 上的安装日志关键输出：

```
✅ 已加载 panel-common.sh
✅ 已加载 panel-1panel.sh
✅ 面板传输模式: xhttp (由 v2_name 判定)
✅ 1Panel Docker: SSL 证书已复制到 /www/ssl/
✅ nginx: configuration file test is successful
✅ 1Panel: nginx 已重载
✅ Xray 服务已启动
✅ ===== 安装完成 =====
   服务状态: xray=active nginx=inactive (面板管理) stat_client=active
```

所有步骤均成功完成，无报错。
