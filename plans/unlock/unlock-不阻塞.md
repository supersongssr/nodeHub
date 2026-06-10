# 方案：unlockCheck 独立脚本 + 独立 API，从 register 中彻底移除

> 状态：待实施
> 创建：2026-06-10
> 更新：2026-06-10 v4 — SPanel/NPanel 一致性分析 + 命名统一为 unlockCheck

---

## 1. 现状分析

### 当前流程

```
proxyInstall.sh Main()
  └─ Step1_Register()
       ├─ ProbeHardware / ProbeGeo
       ├─ RunMediaUnlockCheck()   ← 同步执行 4 个检测脚本，耗时 1-3 分钟
       ├─ GetMediaUnlockInfo()    ← 解析结果到 unlock_* 变量
       └─ POST /api/node/register (携带 unlock_* 参数)
```

### 检测内容不止 media

| 类别 | 服务 |
|---|---|
| 流媒体 | Netflix、Disney+、Bahamut、MeWatch |
| AI 服务 | ChatGPT、Claude、Gemini、NotebookLM |
| 社交/平台 | TikTok、Bilibili、iQIYI |
| 搜索/学术 | Google Scholar、Bing |

本质是 **检测该 IP 能解锁哪些服务**，因此命名为 `unlockCheck`（而非 mediaUnlock）。

### 涉及文件

| 文件 | unlock 相关代码 |
|---|---|
| `proxyInstall.sh` | `RunMediaUnlockCheck()` + `GetMediaUnlockInfo()` 两个函数 + `Step1_Register` 中调用 + unlock_* 参数拼接 |
| SPanel `V2ApiController.php` | 路由注册 |
| SPanel `NodeApiService.php` L301-328 | `registerNode()` 中 `unlock_*` → `node_unlock` 映射写入 |
| NPanel `NodeApiController.php` L245-267 | `register()` 中 `unlock_*` → `node_unlock` 写入 |
| NPanel `routes/api.php` L27-32 | 路由注册 |

### 瓶颈

`RunMediaUnlockCheck()` 同步执行 4 个外部脚本（check.unlock.media、yeahwu/check、Google Scholar、NotebookLM），阻塞安装主进程 1-3 分钟。

---

## 2. 方案：独立脚本 + 独立 API + 从 register 剥离

### 架构

```
proxyInstall.sh (安装脚本)        unlockCheck.sh (独立脚本)
    │                                 (存放在 nodeHub 仓库)
    ├─ Step1_Register()               
    │   ├─ 不再执行 unlock check      
    │   ├─ 不再上传 unlock_* 参数     
    │   └─ POST /register (无 unlock)
    │
    ├─ ... 其他安装步骤 ...
    │
    ├─ Step4.5: 下载 unlockCheck.sh
    │   wget $NODEHUB_URL/unlockCheck.sh
    │   nohup sh ~/unlockCheck.sh &    ← 后台执行，不阻塞
    │
    └─ 安装完成 ✅                      ┌─ 执行 4 个检测脚本
                                        ├─ 解析结果
                                        ├─ POST /api/node/unlock_check
                                        └─ 退出
```

### API 对比

| | 旧 | 新 |
|---|---|---|
| **register** | 携带 unlock_* 参数 | 不再携带，完全移除 |
| **unlock_check** | 不存在 | 新增 `POST /api/node/unlock_check` |

---

## 3. 需要改动的文件（7 处）

| # | 文件 | 改动 |
|---|---|---|
| 1 | **新增** `unlockCheck.sh` | 独立脚本：检测 + 解析 + `POST /api/node/unlock_check` |
| 2 | `proxyInstall.sh` | 删除 `RunMediaUnlockCheck()` / `GetMediaUnlockInfo()` 函数；Step1 中删除 unlock 调用和参数拼接；Main 中新增 `Step4_5_LaunchUnlockCheck()` |
| 3 | SPanel `V2ApiController.php` | 新增 `unlockCheck()` 方法 |
| 4 | SPanel `NodeApiService.php` | `registerNode()` 中删除 unlock 处理块(L301-328)；新增 `updateUnlock()` 方法 |
| 5 | SPanel `config/routes.php` | 新增 `POST /api/node/unlock_check` 路由 |
| 6 | NPanel `NodeApiController.php` | `register()` 中删除 unlock 处理块(L245-267)；新增 `unlockCheck()` 方法 |
| 7 | NPanel `routes/api.php` | 新增 `POST /node/unlock_check` 路由 |

---

## 4. 具体改动

### 4.1 新增 `unlockCheck.sh`

文件：`/root/git/nodeHub/unlockCheck.sh`

```sh
#!/bin/sh
# ============================================================
# unlockCheck.sh — 独立 IP 服务解锁检测脚本
# 职责: 检测 IP 对各服务的解锁状态 → 解析结果 → POST /api/node/unlock_check
# 检测范围: 流媒体(Netflix/Disney+/Bahamut/MeWatch)、AI(ChatGPT/Claude/Gemini/NotebookLM)、
#           社交平台(TikTok/Bilibili/iQIYI)、搜索(Google Scholar/Bing)
# 用法:
#   直接运行:  sh ~/unlockCheck.sh
#   后台运行:  nohup sh ~/unlockCheck.sh >> ~/nodeLogs 2>&1 &
# ============================================================

set -eu

SCRIPT_VERSION="v1.0.0-$(date '+%Y%m%d')"

# ============================================================
# 日志
# ============================================================
log() {
    _level="$1"; shift
    _message="$*"
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    _color="" _emoji=""
    case "$_level" in
        error) _color="\033[31m"; _emoji="❌" ;;
        warn)  _color="\033[33m"; _emoji="⚠️" ;;
        info)  _color="\033[32m"; _emoji="ℹ️" ;;
        debug) _color="\033[36m"; _emoji="🐛" ;;
        *)     _color="\033[0m";  _emoji="📝" ;;
    esac
    _msg="${_ts} [${_level}] ${_emoji} ${_message}"
    printf '%b%s%b\n' "$_color" "$_msg" "\033[0m" >&2
    echo "$_msg" >> ~/nodeLogs 2>/dev/null || true
}

# ============================================================
# 环境加载
# ============================================================
LoadEnv() {
    [ -f ~/.env ] && . ~/.env || { log error "加载 ~/.env 失败"; exit 1; }
    [ -f ~/node.env ] && . ~/node.env || true

    case "${API_URL:-}" in http*) ;; *) API_URL="https://${API_URL}" ;; esac
    case "${NODEHUB_URL:-}" in http*) ;; *) NODEHUB_URL="https://${NODEHUB_URL}" ;; esac

    NODE_ID="${node_id:-${NODE_ID:-}}"
    [ -z "${NODE_ID}" ] && log error "node_id 为空，退出" && exit 1
    [ -z "${API_TOKEN:-}" ] && log error "API_TOKEN 为空，退出" && exit 1

    log info "unlockCheck.sh ${SCRIPT_VERSION} 启动 — NODE_ID=${NODE_ID}"
}

# ============================================================
# 防重入锁
# ============================================================
AcquireLock() {
    _lock="/tmp/.unlock_check_running_${NODE_ID}"
    if [ -f "$_lock" ]; then
        _old_pid=$(cat "$_lock" 2>/dev/null || true)
        if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
            log warn "已有 unlockCheck 进程运行中 (PID=${_old_pid})，退出"
            exit 0
        fi
    fi
    echo $$ > "$_lock"
    trap 'rm -f /tmp/.unlock_check_running_${NODE_ID}' EXIT
}

# ============================================================
# 执行检测脚本
# ============================================================
RunUnlockCheck() {
    log info "开始服务解锁检测"
    cd /tmp || return

    # Script 1: check.unlock.media — Netflix/Disney/ChatGPT/Claude/Gemini 等
    if [ ! -f /tmp/media_unlock_clean.txt ]; then
        log info "执行 check.unlock.media..."
        curl -L -s check.unlock.media > /tmp/_media_unlock_script.sh 2>/dev/null || true
        if [ -f /tmp/_media_unlock_script.sh ]; then
            echo 66 | bash /tmp/_media_unlock_script.sh > /tmp/media_unlock.txt 2>/dev/null || true
        fi
        sed -r 's/\x1b\[[0-9;]*m//g' /tmp/media_unlock.txt > /tmp/media_unlock_clean.txt 2>/dev/null || true
    else
        log debug "check.unlock.media 结果已缓存，跳过"
    fi

    # Script 2: yeahwu/check — TikTok/Bilibili/iQIYI
    if [ ! -f /tmp/media_check_clean.txt ]; then
        log info "执行 yeahwu/check..."
        wget -qO /tmp/_media_check_script.sh https://github.com/yeahwu/check/raw/main/check.sh 2>/dev/null || true
        if [ -f /tmp/_media_check_script.sh ]; then
            bash /tmp/_media_check_script.sh > /tmp/media_check.txt 2>/dev/null || true
        fi
        sed -r 's/\x1b\[[0-9;]*m//g' /tmp/media_check.txt > /tmp/media_check_clean.txt 2>/dev/null || true
    else
        log debug "yeahwu/check 结果已缓存，跳过"
    fi

    # Script 3: Google Scholar
    if [ ! -f /tmp/check_google_scholar_unlock.json ]; then
        log info "执行 Google Scholar 检测..."
        wget -N --timeout=60 --tries=3 -P /tmp "${NODEHUB_URL}/scripts/check_google_scholar_standalone.py" 2>/dev/null || true
        [ -f /tmp/check_google_scholar_standalone.py ] && python3 /tmp/check_google_scholar_standalone.py 2>/dev/null || true
    else
        log debug "Google Scholar 结果已缓存，跳过"
    fi

    # Script 4: NotebookLM
    if [ ! -f /tmp/notebooklm_check_result.json ]; then
        log info "执行 NotebookLM 检测..."
        wget -N --timeout=60 --tries=3 -P /tmp "${NODEHUB_URL}/scripts/notebooklm_unlock_checker.py" 2>/dev/null || true
        [ -f /tmp/notebooklm_unlock_checker.py ] && python3 /tmp/notebooklm_unlock_checker.py 2>/dev/null || true
    else
        log debug "NotebookLM 结果已缓存，跳过"
    fi

    log info "检测脚本执行完成"
}

# ============================================================
# 解析解锁结果
# ============================================================
ParseUnlockInfo() {
    log info "解析解锁信息"

    unlock_netflix=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Netflix:/ { s/.*Netflix://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_chatgpt=$(sed -n '/^============\[ Multination \]====/,/^====/ { /ChatGPT:/ { s/.*ChatGPT://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_disney=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Disney+:/ { s/.*Disney+://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_bing=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Bing Region:/ { s/.*Bing Region://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_claude=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Claude:/ { s/.*Claude://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_gemini=$(sed -n '/^============\[ Multination \]====/,/^====/ { /Google Gemini:/ { s/.*Google Gemini://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_bahamut=$(sed -n '/^==============\[ Taiwan \]====/,/^====/ { /Bahamut Anime:/ { s/.*Bahamut Anime://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_mewatch=$(sed -n '/==========\[ SouthEastAsia \]====/,/^====/ { /MeWatch:/ { s/.*MeWatch://p;q } }' /tmp/media_unlock_clean.txt 2>/dev/null | xargs | tr -d ' ')
    unlock_tiktok=$(grep '^ TikTok' /tmp/media_check_clean.txt 2>/dev/null | cut -d':' -f2- | xargs | tr -d ' ')
    unlock_bilibili=$(grep '^ BiliBili China' /tmp/media_check_clean.txt 2>/dev/null | cut -d':' -f2- | xargs | tr -d ' ')
    unlock_iqiyi=$(grep '^ iQIYI International' /tmp/media_check_clean.txt 2>/dev/null | cut -d':' -f2- | xargs | tr -d ' ')

    unlock_google_scholar=""
    if [ -f /tmp/check_google_scholar_unlock.json ]; then
        _s=$(jq -r '.access_status.overall_status' /tmp/check_google_scholar_unlock.json 2>/dev/null || echo "unknown")
        case "$_s" in accessible|captcha) unlock_google_scholar="Yes(${_s})" ;; *) unlock_google_scholar="No(${_s})" ;; esac
    fi

    unlock_notebooklm=""
    if [ -f /tmp/notebooklm_check_result.json ]; then
        _n=$(jq -r '.ipv4.access_status' /tmp/notebooklm_check_result.json 2>/dev/null || echo "")
        case "$_n" in *yes*) unlock_notebooklm="Yes" ;; *) unlock_notebooklm="No" ;; esac
    fi

    log info "解锁结果: netflix=${unlock_netflix:-空} chatgpt=${unlock_chatgpt:-空} claude=${unlock_claude:-空} gemini=${unlock_gemini:-空}"
    log info "解锁结果: disney=${unlock_disney:-空} bing=${unlock_bing:-空} tiktok=${unlock_tiktok:-空} bilibili=${unlock_bilibili:-空}"
    log info "解锁结果: bahamut=${unlock_bahamut:-空} mewatch=${unlock_mewatch:-空} iqiyi=${unlock_iqiyi:-空} scholar=${unlock_google_scholar:-空} notebooklm=${unlock_notebooklm:-空}"
}

# ============================================================
# 上报结果到 Panel
# ============================================================
SubmitUnlockCheck() {
    log info "上报解锁结果到 Panel"

    _data="node_id=${NODE_ID}"
    [ -n "${unlock_netflix:-}" ]        && _data="${_data}&unlock_netflix=${unlock_netflix}"
    [ -n "${unlock_chatgpt:-}" ]        && _data="${_data}&unlock_chatgpt=${unlock_chatgpt}"
    [ -n "${unlock_disney:-}" ]         && _data="${_data}&unlock_disney=${unlock_disney}"
    [ -n "${unlock_bing:-}" ]           && _data="${_data}&unlock_bing=${unlock_bing}"
    [ -n "${unlock_claude:-}" ]         && _data="${_data}&unlock_claude=${unlock_claude}"
    [ -n "${unlock_gemini:-}" ]         && _data="${_data}&unlock_gemini=${unlock_gemini}"
    [ -n "${unlock_tiktok:-}" ]         && _data="${_data}&unlock_tiktok=${unlock_tiktok}"
    [ -n "${unlock_bilibili:-}" ]       && _data="${_data}&unlock_bilibili=${unlock_bilibili}"
    [ -n "${unlock_iqiyi:-}" ]          && _data="${_data}&unlock_iqiyi=${unlock_iqiyi}"
    [ -n "${unlock_bahamut:-}" ]        && _data="${_data}&unlock_bahamut=${unlock_bahamut}"
    [ -n "${unlock_mewatch:-}" ]        && _data="${_data}&unlock_mewatch=${unlock_mewatch}"
    [ -n "${unlock_google_scholar:-}" ] && _data="${_data}&unlock_google_scholar=${unlock_google_scholar}"
    [ -n "${unlock_notebooklm:-}" ]     && _data="${_data}&unlock_notebooklm=${unlock_notebooklm}"

    log debug "POST /api/node/unlock_check — ${_data}"

    _response=$(curl -sS --connect-timeout 15 --max-time 30 \
        --retry 3 --retry-delay 5 --retry-all-errors \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -X POST \
        -d "$_data" \
        "${API_URL}/api/node/unlock_check" 2>&1) || true

    log info "上报结果: ${_response}"
}

# ============================================================
# 主流程
# ============================================================
Main() {
    LoadEnv
    AcquireLock
    RunUnlockCheck
    ParseUnlockInfo
    SubmitUnlockCheck
    log info "===== unlockCheck.sh 完成 ====="
}

Main "$@"
```

---

### 4.2 proxyInstall.sh 改动

#### 4.2.1 删除函数

删除以下两个函数（约 120 行）：

- `RunMediaUnlockCheck()` — 整个函数删除
- `GetMediaUnlockInfo()` — 整个函数删除

#### 4.2.2 Step1_Register() 中删除 unlock 相关代码

```sh
# ---- 删除以下代码块 ----

# 媒体解锁检测
if [ "${SKIP_MEDIA_UNLOCK:-0}" = "1" ]; then
    log info "媒体解锁检测已跳过 (SKIP_MEDIA_UNLOCK=1)"
else
    RunMediaUnlockCheck
    GetMediaUnlockInfo
fi

# 以及 Step1_Register 中所有 unlock_* 参数拼接（13 行）：
[ -n "${unlock_netflix:-}" ]       && _reg_data="${_reg_data}&unlock_netflix=${unlock_netflix}"
[ -n "${unlock_chatgpt:-}" ]       && _reg_data="${_reg_data}&unlock_chatgpt=${unlock_chatgpt}"
[ -n "${unlock_disney:-}" ]        && _reg_data="${_reg_data}&unlock_disney=${unlock_disney}"
[ -n "${unlock_bing:-}" ]          && _reg_data="${_reg_data}&unlock_bing=${unlock_bing}"
[ -n "${unlock_claude:-}" ]        && _reg_data="${_reg_data}&unlock_claude=${unlock_claude}"
[ -n "${unlock_gemini:-}" ]        && _reg_data="${_reg_data}&unlock_gemini=${unlock_gemini}"
[ -n "${unlock_tiktok:-}" ]        && _reg_data="${_reg_data}&unlock_tiktok=${unlock_tiktok}"
[ -n "${unlock_bilibili:-}" ]      && _reg_data="${_reg_data}&unlock_bilibili=${unlock_bilibili}"
[ -n "${unlock_iqiyi:-}" ]         && _reg_data="${_reg_data}&unlock_iqiyi=${unlock_iqiyi}"
[ -n "${unlock_bahamut:-}" ]       && _reg_data="${_reg_data}&unlock_bahamut=${unlock_bahamut}"
[ -n "${unlock_mewatch:-}" ]       && _reg_data="${_reg_data}&unlock_mewatch=${unlock_mewatch}"
[ -n "${unlock_google_scholar:-}" ] && _reg_data="${_reg_data}&unlock_google_scholar=${unlock_google_scholar}"
[ -n "${unlock_notebooklm:-}" ]    && _reg_data="${_reg_data}&unlock_notebooklm=${unlock_notebooklm}"
```

#### 4.2.3 LoadEnv() 中删除 SKIP_MEDIA_UNLOCK 日志

```sh
# 删除:
log info "SKIP_MEDIA_UNLOCK=${SKIP_MEDIA_UNLOCK:-0} (1=跳过媒体解锁检测)"
```

#### 4.2.4 新增 Step4_5_LaunchUnlockCheck()

在 `Step4_DeployCrontab()` 之后新增：

```sh
# ============================================================
# Step 4.5: 下载并后台启动 unlockCheck.sh
# ============================================================
Step4_5_LaunchUnlockCheck() {
    log info "Step 4.5: 下载并后台启动 unlockCheck.sh"

    wget -N --timeout=60 --tries=3 -P ~ "${NODEHUB_URL}/unlockCheck.sh" \
        || { log error "unlockCheck.sh 下载失败"; return 1; }
    chmod +x ~/unlockCheck.sh
    log info "unlockCheck.sh 已下载到 ~/"

    nohup sh ~/unlockCheck.sh >> ~/nodeLogs 2>&1 &
    _pid=$!
    log info "unlockCheck.sh 已后台启动 (PID=${_pid})，不阻塞安装"
}
```

#### 4.2.5 Main() 更新

```sh
Main() {
    LoadEnv
    InitSystem
    Step0_ApplyId
    Step0_5_InstallServerStatus
    Step1_Register              # 不再包含 unlock check
    Step1_5_DownloadSSL
    Step3_InstallNginx
    Step3_InstallXray
    Step3_5_SetupHy2PortHop
    ConfigureFirewall
    Step2_ResolveDns
    Step4_DeployCrontab
    Step4_5_LaunchUnlockCheck   # ← 新增：后台启动

    log info "===== 安装完成 ====="
    ...
}
```

---

### 4.3 SPanel 改动

#### 4.3.1 V2ApiController.php — 新增 unlockCheck()

```php
/**
 * POST /api/node/unlock_check
 * 节点独立上报 IP 服务解锁检测结果（由 unlockCheck.sh 调用）
 */
public function unlockCheck($request, $response, $args)
{
    if (!$this->validateToken($request)) {
        return $this->errorResponse($response, 'invalid_token');
    }

    $nodeId = $request->getParam('node_id');
    if (empty($nodeId)) {
        return $this->errorResponse($response, 'missing_node_id');
    }

    $params = $request->getParams();

    try {
        $service = new NodeApiService();
        $result = $service->updateUnlock((int)$nodeId, $params);
        return $this->echoJson($response, $result);
    } catch (\Throwable $e) {
        error_log('[V2API] unlockCheck failed for node_id=' . $nodeId . ': ' . $e->getMessage());
        return $this->errorResponse($response, 'internal_error');
    }
}
```

#### 4.3.2 NodeApiService.php — 删除 register 中的 unlock 块 + 新增 updateUnlock()

**删除** `registerNode()` 中 L301-328 的 unlock 处理块：

```php
// ---- 删除整个块 ----
// node_unlock — collect 13 independent unlock_xxx fields into query string
// Only store keys that have a corresponding xray unlock template
$unlockParamToStorageKey = [
    "unlock_netflix" => "Netflix",
    ...
];
$unlockParts = [];
foreach ($unlockParamToStorageKey as $param => $storageKey) {
    if (isset($params[$param]) && $params[$param] !== "") {
        $unlockParts[] = $storageKey . "=" . $params[$param];
    }
}
if (!empty($unlockParts)) {
    $node->node_unlock = implode("&", $unlockParts);
}
```

**新增** `updateUnlock()` 方法：

```php
/**
 * 更新节点 IP 服务解锁信息（独立于 register）
 * @param int $nodeId
 * @param array $params 包含 unlock_netflix, unlock_chatgpt 等参数
 * @return array
 */
public function updateUnlock(int $nodeId, array $params): array
{
    $node = Node::find($nodeId);
    if (!$node) {
        return ['status' => 'error', 'message' => 'node_not_found'];
    }

    $unlockParamToStorageKey = [
        "unlock_netflix"        => "Netflix",
        "unlock_chatgpt"        => "OpenAI",
        "unlock_disney"         => "Disney",
        "unlock_bing"           => "Bing",
        "unlock_claude"         => "Claude",
        "unlock_gemini"         => "Gemini",
        "unlock_bahamut"        => "Bahamut",
        "unlock_mewatch"        => "MeWatch",
        "unlock_tiktok"         => "TikTok",
        "unlock_bilibili"       => "Bilibili",
        "unlock_iqiyi"          => "iQIYI",
        "unlock_google_scholar" => "Google_Scholar",
        "unlock_notebooklm"     => "NotebookLM",
    ];

    $unlockParts = [];
    foreach ($unlockParamToStorageKey as $param => $storageKey) {
        if (isset($params[$param]) && $params[$param] !== "") {
            $unlockParts[] = $storageKey . "=" . $params[$param];
        }
    }

    if (empty($unlockParts)) {
        return ['status' => 'success', 'message' => 'no_data'];
    }

    $node->node_unlock = implode("&", $unlockParts);
    $node->save();

    $updatedParams = array_keys(array_filter(
        $unlockParamToStorageKey,
        function ($param) use ($params) {
            return isset($params[$param]) && $params[$param] !== "";
        },
        ARRAY_FILTER_USE_KEY
    ));

    return [
        'status'  => 'success',
        'updated' => $updatedParams,
    ];
}
```

#### 4.3.3 config/routes.php — 新增路由

在现有 `/api/node/` 路由组（L407 `nginx_config` 之后）添加：

```php
$this->post('/node/unlock_check', 'App\Controllers\V2ApiController:unlockCheck');
```

---

### 4.4 NPanel 改动

#### 4.4.1 NodeApiController.php — 删除 register 中的 unlock 块 + 新增 unlockCheck()

**删除** `register()` 中 L245-267 的 unlock 处理块：

```php
// ---- 删除整个块 ----
// --- Collect individual unlock_ parameters ---
$unlockServices = [
    "netflix", "disney", "chatgpt", "claude", "tiktok",
    ...
];
$unlockData = [];
foreach ($unlockServices as $service) {
    $val = $request->input("unlock_" . $service);
    if ($val !== null && $val !== "") {
        $unlockData[$service] = $val;
    }
}
$node->node_unlock = urldecode(http_build_query($unlockData));
```

**新增** `unlockCheck()` 方法：

```php
/**
 * POST /api/node/unlock_check
 * 节点独立上报 IP 服务解锁检测结果（由 unlockCheck.sh 调用）
 */
public function unlockCheck(Request $request)
{
    // Token 验证
    $token = null;
    $header = $request->header('Authorization', '');
    if (stripos($header, 'Bearer ') === 0) {
        $token = substr($header, 7);
    }
    if (!$token) {
        $token = $request->get('token');
    }
    if (!$token || $token !== env('API_TOKEN')) {
        return response()->json([
            'status'  => 'error',
            'message' => 'Unauthorized',
        ], 401);
    }

    $nodeId = $request->input('node_id');
    if (empty($nodeId)) {
        return response()->json([
            'status'  => 'error',
            'message' => 'missing_node_id',
        ], 400);
    }

    $node = SsNode::find($nodeId);
    if (!$node) {
        return response()->json([
            'status'  => 'error',
            'message' => 'Node not found',
        ], 404);
    }

    $unlockServices = [
        'netflix', 'disney', 'chatgpt', 'claude', 'tiktok',
        'bilibili', 'iqiyi', 'bahamut', 'mewatch', 'bing',
        'google_scholar', 'notebooklm',
    ];
    $unlockData = [];
    foreach ($unlockServices as $service) {
        $val = $request->input('unlock_' . $service);
        if ($val !== null && $val !== '') {
            $unlockData[$service] = $val;
        }
    }

    if (empty($unlockData)) {
        return response()->json([
            'status'  => 'success',
            'message' => 'no_data',
        ]);
    }

    $node->node_unlock = urldecode(http_build_query($unlockData));
    $node->save();

    return response()->json([
        'status'  => 'success',
        'updated' => array_keys($unlockData),
    ]);
}
```

#### 4.4.2 routes/api.php — 新增路由

在 L32 `nginx_config` 之后添加：

```php
Route::post('unlock_check', 'NodeApiController@unlockCheck');
```

---

## 5. 命名映射总表

| 旧名 | 新名 |
|---|---|
| `mediaUnlock.sh` | `unlockCheck.sh` |
| `POST /api/node/media_unlock` | `POST /api/node/unlock_check` |
| `RunMediaUnlockCheck()` | `RunUnlockCheck()` |
| `GetMediaUnlockInfo()` | `ParseUnlockInfo()` |
| `Step4_5_LaunchMediaUnlock()` | `Step4_5_LaunchUnlockCheck()` |
| `V2ApiController::mediaUnlock()` | `V2ApiController::unlockCheck()` |
| `NodeApiService::updateMediaUnlock()` | `NodeApiService::updateUnlock()` |
| `NodeApiController::mediaUnlock()` | `NodeApiController::unlockCheck()` |
| `/tmp/.media_unlock_running_${NODE_ID}` | `/tmp/.unlock_check_running_${NODE_ID}` |
| DB 字段 `node_unlock` | **不变** |
| POST 参数 `unlock_netflix` 等 | **不变** |

---

## 6. 优点

| 项 | 说明 |
|---|---|
| **零阻塞** | 安装主进程完全不执行 unlock check，节省 1-3 分钟 |
| **职责清晰** | 安装脚本只管安装，unlock check 是独立关注点 |
| **独立可测** | `unlockCheck.sh` 可随时手动运行 `sh ~/unlockCheck.sh` |
| **独立可更新** | 通过 `wget -N $NODEHUB_URL/unlockCheck.sh` 热更新，无需改安装脚本 |
| **API 干净** | register 不再混杂 13 个 unlock 参数，职责单一 |
| **防重入** | `/tmp/.unlock_check_running_${NODE_ID}` 锁文件防止并发执行 |
| **命名准确** | `unlockCheck` 精确描述行为——检测各服务 unlock 状态，不局限于 media |

---

## 7. 风险与注意

| 项 | 说明 | 应对 |
|---|---|---|
| 安装完成后 unlock 数据延迟 | 安装完成时 panel 还没有 unlock 数据 | panel 前端可在无 unlock 数据时显示"检测中"或隐藏 |
| 后台脚本失败 | curl/网络问题导致上报失败 | unlockCheck.sh 带重试(3次)；也可手动重新执行 |
| register 中不再写 node_unlock | 旧节点重装时 node_unlock 会被 resetNodeToDefaults 清空 | 正常：重装后由 unlockCheck.sh 补报新值 |
| SPanel NodeApiService 联动 | registerNode 中 unlock 代码需同步删除 | 见 4.3.2 |

---

## 8. SPanel / NPanel API 一致性分析

### 结论：API 入参格式完全一致，两个 Panel 可共用同一个 `unlockCheck.sh`

`unlockCheck.sh` 发出的 POST 请求格式：

```
POST /api/node/unlock_check
node_id=5&unlock_netflix=Yes&unlock_chatgpt=Yes&unlock_disney=No&unlock_claude=Yes&unlock_gemini=No&unlock_bing=US&unlock_tiktok=Yes&unlock_bilibili=No&unlock_iqiyi=No&unlock_bahamut=No&unlock_mewatch=No&unlock_google_scholar=Yes(accessible)&unlock_notebooklm=No
```

两个 Panel 接收的**入参完全相同**（相同的 13 个 `unlock_xxx` 参数），各自内部转换为不同的 DB 存储格式。

### 存储格式差异（内部实现不同，对脚本透明）

| 对比项 | SPanel | NPanel |
|---|---|---|
| **存储 key** | `Netflix=Yes` / `OpenAI=Yes` (自定义名称) | `netflix=Yes` / `chatgpt=Yes` (小写原始名) |
| **ChatGPT 映射** | `unlock_chatgpt` → `OpenAI` | `unlock_chatgpt` → `chatgpt` |
| **Google Scholar** | `unlock_google_scholar` → `Google_Scholar` | `unlock_google_scholar` → `google_scholar` |
| **消费端** | `parse_str()` → `strtolower(key) === 'openai'` | `parse_str()` → `str_replace("unlock","")` + special case |
| **判断有解锁** | `strtolower($status) !== 'no'` | `preg_match("/^(0|no|false|off)/", $valLower)` → 无解锁 |

### 差异不影响方案的原因

1. **`unlockCheck.sh` 不需要知道存储格式** — 它只负责发送 `unlock_xxx=值`，Panel 各自做映射
2. **新增的 `unlock_check` API 在两个 Panel 中各自实现** — SPanel 用 `NodeApiService::updateUnlock()` 做映射，NPanel 在 `unlockCheck()` 中直接 `http_build_query`
3. **从 register 中删除 unlock 块也是各自实现** — SPanel 删 `NodeApiService.php` L301-328，NPanel 删 `NodeApiController.php` L245-267

### 统一的 API 契约

```
POST /api/node/unlock_check
Header: Authorization: Bearer <token>
Content-Type: application/x-www-form-urlencoded

Body:
  node_id              = <int>    (必需)
  unlock_netflix       = <string> (可选)
  unlock_chatgpt       = <string> (可选)
  unlock_disney        = <string> (可选)
  unlock_bing          = <string> (可选)
  unlock_claude        = <string> (可选)
  unlock_gemini        = <string> (可选)
  unlock_tiktok        = <string> (可选)
  unlock_bilibili      = <string> (可选)
  unlock_iqiyi         = <string> (可选)
  unlock_bahamut       = <string> (可选)
  unlock_mewatch       = <string> (可选)
  unlock_google_scholar = <string> (可选)
  unlock_notebooklm    = <string> (可选)

Response (成功):
  { "status": "success", "updated": ["netflix", "chatgpt", ...] }

Response (无数据):
  { "status": "success", "message": "no_data" }

Response (未授权):
  { "status": "error", "message": "invalid_token" }  (SPanel)
  { "status": "error", "message": "Unauthorized" }   (NPanel)

Response (节点不存在):
  { "status": "error", "message": "node_not_found" } (SPanel)
  { "status": "error", "message": "Node not found" }  (NPanel)
```

> 两个 Panel 的 **入参格式、成功响应格式完全一致**，`unlockCheck.sh` 无需区分 Panel 类型。
