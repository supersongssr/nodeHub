# 方案: 后台 fallback / 默认网站改为本地 AriaNg 静态站

**日期**: 2026-06-14
**状态**: ⏳ 待审核 (方案阶段，未动手)
**涉及 3 个项目**:
- `/root/git/nodeHub` (proxyInstall.sh)
- `/var/www/SPanel` (nginx 模板 + 渲染逻辑)
- `/var/www/NPanel` (nginx 模板 + 渲染逻辑)

---

## 1. 背景与目标 (why)

当前节点的 nginx `location /`(伪装站/默认回落)全部反代到一个远端主机
(`node_fallback_host`: SPanel 默认 `www.apple.com`，NPanel 默认
`npanel-nav.freessr.bid`)。反代会引入 TLS 指纹差异，干扰排查。

**目标**: 把 `location /` 从「反代远端」改为「本地 AriaNg 纯静态站」，
彻底排除反代干扰。AriaNg 是纯静态 SPA，多个 conf 共用同一目录即可。

---

## 2. 现状分析 (关键结论)

### 2.1 conf 渲染链路
- SPanel: `app/Controllers/V2ApiController.php` (L286~329)
  - 读 `resources/templates/nginx/{v2_name}.conf`
  - 替换占位符 (`__httpProxyHost__` ← `Config::get('node_fallback_host') ?: 'www.apple.com'`)
- NPanel: `app/Http/Controllers/Api/NodeApiController.php` (`nginx_config` 方法, L1857~1889)
  - 读 `resources/templates/nginx/{v2_name}.conf`
  - 替换占位符 (`__httpProxyHost__` ← `Helpers::systemConfig()['node_fallback_host'] ?: 'npanel-nav.freessr.bid'`)
- 节点侧: `proxyInstall.sh` 的 `Step3_InstallNginx` (无面板) 直接把渲染结果
  落盘到 `/etc/nginx/conf.d/proxy.conf` 并 `systemctl restart nginx`。

### 2.2 ⚠️ `node_fallback_host` 不能删
`__httpProxyHost__` / `node_fallback_host` 仍被 **xray 模板** 用于 hy2 回落:
- SPanel: `resources/templates/xray/*-hy2*.json` 的 `"url": "__HYSTERIA_URL__"`
- NPanel: 同上 + `NodeApiController` L1732 `"__HYSTERIA_URL__" => "http://" . $fallbackHost . ":80"`

➡️ **PHP 渲染逻辑保持不变**，仅改 nginx conf 的 `location /` 块。
占位符 `__httpProxyHost__` 在 nginx conf 中不再出现，无害。

### 2.3 ⚠️ 仅「无面板(纯节点)模式」生效
- **无面板模式**: `Step3_InstallNginx` 直接用模板 → 本方案生效 ✅
- **面板模式**: `Step3_InstallNginx_Panel` → `panels/panel-common.sh::GenerateProxyServerBlock`
  会**跳过**模板里的 `location /` 并重新生成 `/ → xray upstream`。所以模板里的 `/`
  改成 AriaNg **对面板模式不生效**。面板模式属于另一条路径，**本次不动**
  (用户明确: 只动 `/`, 不动其它配置)。
- AriaNg 静态文件安装在节点上是无害且幂等的，两种模式都装(仅无面板模式会 serve)。

### 2.4 8 个模板 × 2 面板，`/` 块共有 2 种变体
两面板的 conf 结构一致(仅注释/空行/`X-Forwarded-For` 微小差异)。所有 `location /` 块
当前都是反代，按位置分两类:

| 文件 | `/` 所在 server | X-Real-IP 来源 |
|---|---|---|
| `vision.conf` / `vision-hy2.conf` | `127.0.0.1:8088` (vision 回落) | `$remote_addr` |
| `vision-ws-grpc.conf` / `vision-hy2-ws-grpc.conf` | `2053 ssl` (CF 白名单内) | `$remote_addr` |
| `xhttp.conf` / `xhttp-hy2.conf` | `__nginxPort__ ssl` (443) | `$http_cf_connecting_ip` |
| `xhttp-ws-grpc.conf` / `xhttp-hy2-ws-grpc.conf` | `__nginxPort__ ssl` (443) | `$http_cf_connecting_ip` |

NPanel 的 vision 类多一行 `proxy_set_header X-Forwarded-For ...`。
**这些差异在改为静态站后全部统一**(静态站不需要这些 proxy header)。

---

## 3. 设计决策

### 3.1 AriaNg 安装路径: `/var/www/ariang`
- 与 `/var/www/{SPanel,NPanel,html}` 同级，约定一致。
- 纯静态, 全部 conf 共用同一目录 ✅ (用户要求确认「可通用」—— 可以)。
- nginx worker (Debian 用 `www-data`；nginx.org 包用 `nginx`) 用户不确定,
  统一 `chmod -R a+rX` 让任意 worker 可读, 规避用户差异。

### 3.2 AriaNg 版本与下载
- 版本: `1.3.13` (用户指定)
- URL: `https://github.com/mayswind/AriaNg/releases/download/1.3.13/AriaNg-1.3.13.zip`
- 下载到 `/tmp` 用 `wget -N` (时间戳增量, 幂等), 再解压迁移到 `/var/www/ariang`。
- zip 解压后顶层即 `index.html / css / js / fonts / langs / ...`, 直接解压到目标目录。

### 3.3 新的 `location /` 规范块 (所有 conf 统一)
```nginx
    # 默认回落: 本地 AriaNg 静态站 (纯静态, 所有 conf 共用 /var/www/ariang)
    location / {
        root /var/www/ariang;
        index index.html;
    }
```
- 只动 `location /` 块内部，不动其它 location(xhttp/ws/grpc 分流)、不动 ssl/server_name/CF 白名单。
- 不用 `try_files`(AriaNg 用 hash 路由 `#/`，未知路径 404 对伪装更自然)。如需 SPA 兜底可后续加。

### 3.4 约束(必须遵守)
- ✅ 只改 `location /`(含 8088 的 `location /`) → 本地 AriaNg
- ✅ 不动 xhttp / ws / grpc 分流 location
- ✅ 不动 ssl / server_name / CF allow/deny
- ✅ 不动 PHP 渲染逻辑(`__httpProxyHost__` 计算保留, xray hy2 仍依赖)
- ✅ `wget -N` 下载到 `/tmp` 再迁移

---

## 4. 改动清单

### 4.1 `/root/git/nodeHub/proxyInstall.sh` — 新增 AriaNg 安装步骤

**(a) 新增函数 `Step2_5_InstallAriaNg()`** (定义放在 `Step1_5_DownloadSSL` 之后,
`Step2_ResolveDns` 附近; 与现有 `Step{N}_{N_5}_*` 半步命名风格一致):

```sh
# ============================================================
# Step 2.5: 安装本地 AriaNg 静态站 (用于 nginx location / 本地回落)
# 下载到 /tmp (wget -N 幂等), 解压到 /var/www/ariang
# 纯静态站点, 无面板/面板模式均安装 (仅无面板模式实际 serve)
# ============================================================
ARIANG_VERSION="1.3.13"
ARIANG_URL="https://github.com/mayswind/AriaNg/releases/download/${ARIANG_VERSION}/AriaNg-${ARIANG_VERSION}.zip"
ARIANG_DIR="/var/www/ariang"
ARIANG_ZIP="/tmp/AriaNg-${ARIANG_VERSION}.zip"

Step2_5_InstallAriaNg() {
    log info "Step 2.5: 安装本地 AriaNg 静态站 (${ARIANG_VERSION})"

    # 1. 确保 unzip 可用 (InitSystem 未预装)
    command -v unzip >/dev/null 2>&1 || AptGet install -y -qq unzip

    # 2. 下载到 /tmp (wget -N 时间戳增量, 已存在且最新则跳过)
    if ! wget -N --timeout=60 --tries=3 -O "${ARIANG_ZIP}" "${ARIANG_URL}" 2>/dev/null; then
        die "AriaNg 下载失败: ${ARIANG_URL}"
    fi
    AssertFileValid "AriaNg zip" "${ARIANG_ZIP}"

    # 3. 解压到临时目录再原子迁移, 避免半解压状态
    _ariang_stage="$(mktemp -d)"
    if ! unzip -q -o "${ARIANG_ZIP}" -d "${_ariang_stage}"; then
        rm -rf "${_ariang_stage}"
        die "AriaNg 解压失败: ${ARIANG_ZIP}"
    fi

    mkdir -p "${ARIANG_DIR}"
    rm -rf "${ARIANG_DIR:?}/"*
    cp -a "${_ariang_stage}/." "${ARIANG_DIR}/"
    rm -rf "${_ariang_stage}"

    # 4. 校验入口文件 + 权限 (任意 nginx worker 可读)
    [ -f "${ARIANG_DIR}/index.html" ] || die "AriaNg 安装异常: index.html 缺失"
    chown -R root:root "${ARIANG_DIR}"
    chmod -R a+rX "${ARIANG_DIR}"

    log info "AriaNg 已安装到 ${ARIANG_DIR} ($(ls -1 ${ARIANG_DIR} | wc -l) 项)"
}
```

**(b) 在 `Main()` 调用序列中插入** (位于 `Step1_5_DownloadSSL` 之后、`Step3_InstallNginx` 之前,
保证 nginx `-t` / restart 前静态文件已就位):

```diff
     Step1_Register
     Step1_5_DownloadSSL
+    Step2_5_InstallAriaNg
     Step3_InstallNginx
```

> 说明: `Main()` 现有执行顺序里 `Step3_InstallNginx` 已在 `Step2_ResolveDns` 之前(编号非执行序),
> 本步骤同样按「在 Step3 前调用」放置, 命名沿用半步风格。

---

### 4.2 `/var/www/SPanel/resources/templates/nginx/` — 8 个文件

把每个文件里的 `location / { proxy_pass ... }` 块整块替换为 3.3 规范块。
**每个文件只改 `location /` 一处**(vision/vision-hy2 的 8088 块也是 `location /`)。

| 文件 | 改动位置 |
|---|---|
| `vision.conf` | 8088 server 内的 `location /` |
| `vision-hy2.conf` | 8088 server 内的 `location /` |
| `vision-ws-grpc.conf` | 2053 ssl server 末尾的 `location /` |
| `vision-hy2-ws-grpc.conf` | 2053 ssl server 末尾的 `location /` |
| `xhttp.conf` | `__nginxPort__` ssl server 末尾的 `location /` |
| `xhttp-hy2.conf` | `__nginxPort__` ssl server 末尾的 `location /` |
| `xhttp-ws-grpc.conf` | `__nginxPort__` ssl server 末尾的 `location /` |
| `xhttp-hy2-ws-grpc.conf` | `__nginxPort__` ssl server 末尾的 `location /` |

替换示例 (xhttp 类, 替换前):
```nginx
    # 默认回落: 伪装站
    location / {
        proxy_redirect off;
        proxy_pass http://__httpProxyHost__;
        proxy_set_header Host __httpProxyHost__;
        proxy_set_header X-Real-IP $http_cf_connecting_ip;
    }
```
替换后:
```nginx
    # 默认回落: 本地 AriaNg 静态站 (纯静态, 所有 conf 共用 /var/www/ariang)
    location / {
        root /var/www/ariang;
        index index.html;
    }
```
vision 类(8088 及 ws-grpc 的 2053)同理, 把对应 `location /` 整块换成规范块。

---

### 4.3 `/var/www/NPanel/resources/templates/nginx/` — 同样 8 个文件

改动与 4.2 完全一致(每个文件仅 `location /` 一处)。NPanel vision 类多出的
`proxy_set_header X-Forwarded-For ...` 行随整个 `location /` 块一起被替换掉(静态站不需要)。

---

### 4.4 不改动的文件 (明确)
- SPanel `V2ApiController.php` / NPanel `NodeApiController.php` —— 渲染逻辑保持
- `resources/templates/xray/*.json` —— hy2 仍用 `__HYSTERIA_URL__`
- `panels/panel-common.sh` / `panel-1panel.sh` / `panel-btpanel.sh` —— 面板模式路径, 本次不动
- 所有 conf 内非 `/` 的 location(xhttp/ws/grpc 分流)、ssl、server_name、CF 白名单

---

## 5. 验证方案

### 5.1 静态站可用性
```sh
ls -la /var/www/ariang/index.html   # 入口存在
curl -sI http://127.0.0.1/           # 期望 200 + text/html (经 443 站)
# 或直测 8088 (vision 回落)
curl -sI http://127.0.0.1:8088/      # 期望 200 + text/html
```

### 5.2 nginx 语法
```sh
nginx -t && systemctl reload nginx
```

### 5.3 渲染产物检查 (面板侧)
触发 `GET /api/node/nginx_config?node_id=X`, 确认返回的 conf 里:
- `location /` 是 `root /var/www/ariang;` 而非 `proxy_pass`
- xhttp/ws/grpc 分流 location 未变
- 不再含 `__httpProxyHost__` 残留

### 5.4 分流回归 (不能破坏)
- xhttp: `curl https://<domain>/<xhttpPath>` 仍到 xray
- ws/grpc: 业务流量正常
- 仅 `/` 及未匹配路径落到 AriaNg

### 5.5 幂等性
重跑 `proxyInstall.sh`: `wget -N` 不重复下载; `/var/www/ariang` 内容稳定。

---

## 6. 风险与开放问题 (请审核确认)

1. **面板模式不生效**: 本次改动只覆盖无面板(纯节点)模式。
   若需要面板模式(1Panel/宝塔)的 `proxy.{domain}` 站点 `/` 也用 AriaNg,
   需另改 `panels/panel-common.sh::GenerateProxyServerBlock`(把其 `location /`
   从 `proxy_pass → xray` 改为本地 AriaNg)。**默认不做**, 等你确认。

2. **AriaNg 作为 hy2/xhttp 伪装站的「真实感」**: AriaNg 是公开下载器 UI,
   作为伪装站特征明显。本方案目的是「排除反代干扰」便于排查, 不是增强伪装。
   若要更强伪装应保留远端反代——但这与本次目标相反, 按你的要求改为本地 AriaNg。

3. **GitHub 下载可达性**: 节点若无法直连 github.com, `wget` 会失败。
   可选: 增加 GitHub 镜像兜底(如 ghproxy)。**默认不加**, 等你确认是否需要。

4. **`index` 指令作用域**: `index` 放在 `location /` 内对该 location 生效, 足够。
   若希望全 server 生效可上移到 server 块, 但那会触碰「只动 `/`」约束, 不做。

---

## 7. 执行顺序 (审核通过后)

1. `nodeHub`: 改 `proxyInstall.sh`(新增 `Step2_5_InstallAriaNg` + `Main()` 调用)
2. `SPanel`: 改 8 个 nginx conf 的 `location /`
3. `NPanel`: 改 8 个 nginx conf 的 `location /`
4. 自测: 选一台无面板节点跑 `proxyInstall.sh`, 验证 §5
5. 三项目分别 git commit (联动修改, 建议同一批提交)
