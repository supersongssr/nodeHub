# 方案: nodeHub 新增 Go API 数据中枢 + 静态资源目录化

**日期**: 2026-08-03
**状态**: ⏳ 待审核 (方案阶段，未动手)
**作者**: 分析稿 (待 song 审查)

---

## 0. TL;DR (一句话结论)

**方案合理、可行，强烈推荐落地。** 这套「Go + SQLite + Bearer Token + nginx 前置」的架构在本机已有成熟先例（`ssr-monitor-api`），技术栈选型正确、规模匹配。
但有 **3 个必须先拍板的决策点**（见 §6），其中最关键的是：先把「对外暴露整个仓库根目录」这个安全隐患改成「独立静态目录」，再叠加 API，**而不是在根目录直接堆代码 / DB**。

---

## 1. 需求理解 (what)

根据口述，需求拆解为两件事：

1. **静态资源目录化**
   把当前散落在仓库根目录、对外提供静态下载的内容，收纳进一个独立目录（如 `static/` 或 `public/`），与脚本源码、配置、敏感文件物理隔离。

2. **Go 数据中枢 API (Data Hub)**
   用 Go 写一个轻量 HTTP API + SQLite，作为「中心枢纽」：
   - 各个项目可以**写入**数据 (push)
   - 各个项目可以**读取**数据 (pull)
   - 鉴权用 HTTP Header `Authorization: Bearer <token>`
   - 形态：一个独立服务，单二进制 + 单 DB 文件

---

## 2. 现状分析 (现状即事实)

### 2.1 当前静态服务是怎么对外提供的

nginx 配置 `/etc/nginx/conf.d/test-kod.freessr.bid.conf`:

```nginx
server {
    listen 8443 ssl http2;
    server_name test-kod.freessr.bid;
    ...
    location /node_hub {
        auth_basic "Restricted - node_hub";
        auth_basic_user_file /etc/nginx/htpasswd_nodehub;
        alias /opt/git/nodeHub;          # ← 直接 alias 到整个仓库根
    }
}
```

- 对外入口：`https://test-kod.freessr.bid:8443/node_hub/...`
- 节点端脚本通过环境变量 `NODEHUB_URL` 拼 URL，用 `wget` 下载资源，例如：
  - `${NODEHUB_URL}/scripts/probe/probeTask.sh`
  - `${NODEHUB_URL}/ssl/<domain>.pem`
  - `${NODEHUB_URL}/ssl/<domain>.key`
- 鉴权只有一层 nginx HTTP basic auth (htpasswd)。

### 2.2 ⚠️ 现状的安全隐患 (做这件事的额外收益)

`alias /opt/git/nodeHub` 把**整个仓库根目录**对外暴露（虽有 basic auth）。一旦落地新内容，会一并暴露：
- `.env`（含 TG token / 域名 / 远端主机）→ **泄密高危**
- 未来的 Go 源码、`go.mod`、SQLite `.db` 文件
- `logs/`、`.git/`、`.tmp/`、`.scripts/`

> 即便有 basic auth，把 DB 文件和 .env 放在 web 可达路径是典型的「纵深防御缺失」。
> **结论：目录化重构本身就是一次必要的安全整改，不只是为了好看。**

### 2.3 已有同类先例 (本机已有跑通的范本)

`/opt/git/ServerStatus-Rust-Moniter` 里的 `ssr-monitor-api` (FastAPI, :8903) 已经完整实现了你要的这套模式：

| 维度 | 现有 Python 版做法 | 你要做的 Go 版 |
|---|---|---|
| 鉴权 | Bearer Token，DB 存 **sha256(token)**，明文仅创建时返回一次 | ✅ 直接照抄此模型 |
| 权限 | scope 模型：`read / write / ingest / admin` | ✅ 建议照抄 |
| DB | SQLite 单文件 `.data/monitor.db` | ✅ 一致 |
| 部署 | systemd，绑 `127.0.0.1:8903`，nginx 前置 TLS | ✅ 一致 |
| 限流 | nginx `limit_req zone=ingest rate=30r/m` | ✅ 一致 |
| 写入 | `/ingest/*` (节点上报) | ✅ 一致 |
| 读取 | `/api/v1/*` | ✅ 一致 |

> 这说明：**你要的架构在本环境已被验证可行、可运维**。Go 版只是把同样的模式用到 nodeHub 上，换语言、换数据语义。

### 2.4 nodeHub 仓库现状

- 全是 shell 脚本 + 配置 + 文档，**没有任何 Go 代码**（无 `go.mod`）。
- Go 工具链已装：`go1.26.0 linux/amd64`，磁盘 `/` 余 46G，资源充足。

---

## 3. 可行性评估 (is it reasonable?)

### 3.1 结论：✅ 合理、可行、推荐

| 评估项 | 判断 | 理由 |
|---|---|---|
| 语言选型 (Go) | ✅ 优秀 | 单二进制零依赖部署、`net/http` 标准库够用、并发模型适合 IO 密集的 API、交叉编译方便分发到节点 |
| 存储 (SQLite) | ✅ 匹配规模 | 「中枢」≠ 高并发写入场景；单机、读写中等、关系简单 → SQLite 是甜点区。避免上 MySQL/PG 的运维负担 |
| 鉴权 (Bearer) | ✅ 标准做法 | 机器对机器 (M2M) 场景的事实标准；比 basic auth 更安全（可吊销、可分 scope） |
| 与现有 Python API 共存 | ✅ 可共存 | 二者定位不同（见 §7），端口/域名/DB 互不冲突 |

### 3.2 什么情况下这个方案「不合适」(诚实风险)

- ❌ 如果单机写入 QPS 持续 > 几百/秒 → SQLite 写锁会成为瓶颈，应上 PostgreSQL/MySQL。
- ❌ 如果「中枢」要做多节点数据汇聚 / 实时订阅推送 → 纯 SQLite + 轮询不如上 Redis/NATS。**但你描述的需求是「写进去 + 读出来」，属于 KV 语义，SQLite 完全胜任。**
- ⚠️ 如果将来 Go API 和 Python monitor API 职责重叠 → 会出现「两个中心」的治理混乱（见 §7 决策点）。

---

## 4. 推荐架构设计 (how)

### 4.1 目录结构 (重构后)

```
/opt/git/nodeHub/
├── static/                     # ← 新增: 唯一对 web 暴露的静态资源根
│   ├── scripts/                #   原 scripts/ 里需要被节点下载的子集
│   │   └── probe/              #   (probeTask.sh 等)
│   ├── ssl/                    #   原 ssl/ (证书, 软链或同步过来)
│   ├── geodat/                 #   原 geodat/
│   └── panels/                 #   如需对外提供面板脚本
│
├── api/                        # ← 新增: Go API 服务源码 (不对 web 暴露)
│   ├── go.mod
│   ├── go.sum
│   ├── cmd/
│   │   └── nodehub-api/
│   │       └── main.go
│   └── internal/
│       ├── config/             # 配置加载 (env / flag)
│       ├── auth/               # Bearer token + scope
│       ├── store/              # SQLite 访问层
│       ├── handler/            # HTTP handler
│       └── model/              # 数据结构
│
├── data/                       # ← 新增: 运行时数据 (不对 web 暴露, 入 .gitignore)
│   └── nodehub.db              #   SQLite 单文件
│
├── deploy/
│   └── nodehub-api.service     # systemd unit
│
├── scripts/                    # 原 shell 脚本 (开发/运维用, 不直接对外)
├── panels/  configs/  xray/  manage.sh  ...   # 其余维持现状
└── .env                        # (新增 API 配置段, 不对外)
```

**关键原则**：
- nginx 的 `alias` **只指向 `static/`**，从根上消除 `.env`/`data/`/`api/` 被暴露的风险。
- `data/`、`api/`、`.env` 永远不在 web 可达路径。

### 4.2 nginx 改造 (静态 + API 两段)

把原来一个 `location /node_hub` 拆成「静态资源」+「API 反代」两段：

```nginx
server {
    listen 8443 ssl http2;
    server_name test-kod.freessr.bid;

    ssl_certificate     /etc/ssl/freessr.bid.pem;
    ssl_certificate_key /etc/ssl/freessr.bid.key;
    ...

    # ── (1) 静态资源: 只指向 static/ ──
    location /node_hub/ {
        auth_basic "Restricted";
        auth_basic_user_file /etc/nginx/htpasswd_nodehub;
        alias /opt/git/nodeHub/static/;        # ← 收窄到 static/
        autoindex on;                          # 视需要, 列目录
    }

    # ── (2) API: 反代到本地 Go 服务, 应用层 Bearer 鉴权 ──
    location /api/ {
        limit_req zone=api burst=20 nodelay;   # 防刷 (需在 nginx.conf 加 zone=api)
        proxy_pass http://127.0.0.1:8904;       # ← Go 服务绑 localhost:8904
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        client_max_body_size 2m;
    }

    location = /api/health {                    # 健康检查, 可选免鉴权
        proxy_pass http://127.0.0.1:8904/health;
    }
}
```

> Go 服务**只绑 `127.0.0.1:8904`**，绝不直接 `0.0.0.0`。所有外网流量必经 nginx 的 TLS + 限流。这与现有 `probe-ingest.conf` 的套路完全一致。

### 4.3 数据模型 (推荐: 通用命名空间 KV/文档存储)

「中心枢纽」最忌讳**每来一个新需求就加一张表**。推荐**通用 KV/文档模型**，任何项目都能存任意数据，靠 `namespace` 隔离：

```sql
-- ═══ 数据条目 (核心表) ═══
CREATE TABLE data_items (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    namespace     TEXT    NOT NULL,   -- 命名空间, 如 "probe" / "billing" / "node-h12"
    key           TEXT    NOT NULL,   -- 逻辑键, 如 "last_report" / "config/v1"
    value         TEXT    NOT NULL,   -- 任意 JSON / 文本
    content_type  TEXT,               -- 可选: "application/json" 等
    created_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at    INTEGER,            -- 可选 TTL, 到点可被清理
    written_by    TEXT,               -- 写入方 token 的 name/前缀, 审计用
    UNIQUE(namespace, key)
);
CREATE INDEX idx_data_expires ON data_items(expires_at) WHERE expires_at IS NOT NULL;
CREATE INDEX idx_data_ns ON data_items(namespace);

-- ═══ API Token (鉴权) ═══
CREATE TABLE api_tokens (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT    NOT NULL UNIQUE,    -- 人类可读名, 如 "probe-reporter"
    token_hash   TEXT    NOT NULL UNIQUE,    -- sha256(明文) hex, 不存明文
    token_prefix TEXT    NOT NULL,           -- 明文前 8~12 字符, 供 UI 识别
    scopes       TEXT    NOT NULL,           -- 逗号分隔: "read,write" / "read" / "admin"
    namespaces   TEXT,                       -- 可选: 允许的 namespace 白名单, "*"=全部
    created_at   INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at   INTEGER,                    -- 可选
    last_used_at INTEGER,
    last_used_ip TEXT,
    enabled      INTEGER NOT NULL DEFAULT 1
);

-- ═══ 审计日志 (可选但推荐) ═══
CREATE TABLE audit_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ts         INTEGER NOT NULL DEFAULT (unixepoch()),
    token_name TEXT,
    action     TEXT,    -- "token_auth" / "write" / "read" / "denied"
    namespace  TEXT,
    key        TEXT,
    ip         TEXT,
    detail     TEXT     -- JSON
);
```

**对应的 REST 端点**：

| 方法 | 路径 | 作用 | 需要 scope |
|---|---|---|---|
| `PUT`  | `/api/v1/data/{namespace}/{key}` | 写入/更新 (upsert) | `write` |
| `GET`  | `/api/v1/data/{namespace}/{key}` | 读取单条 | `read` |
| `GET`  | `/api/v1/data/{namespace}?prefix=cfg/` | 列举/前缀查询 | `read` |
| `DELETE` | `/api/v1/data/{namespace}/{key}` | 删除 | `write` |
| `GET`  | `/health` | 探活 | 无 |
| (CLI) | `nodehub-api token create --scopes write --ns probe` | 管理端建 token | 本地命令行 |

> 这种「namespace + key + 任意 value」的模型，让"中枢"真正成为通用交换层：A 项目 push、B 项目 pull，互不耦合 schema。

### 4.4 鉴权设计 (Bearer Token + scope)

完全照搬现有 Python 版的成熟做法：

1. **明文格式**：`nh_<32 字节 base62>`，前缀 `nh_` 便于识别。
2. **DB 只存 `sha256(明文)`**，明文仅 `token create` 时返回**一次**。
3. **scope 模型**：`read` / `write` / `admin`（比 Python 版精简，去掉用不到的 `ingest`，因为本 API 统一用 `write`）。
4. **namespace 白名单**（可选增强）：token 可限定只能写某些 namespace，防止越权写其他项目数据。
5. **请求头**：`Authorization: Bearer nh_xxxxxxxx...`
6. **失败响应**：`401`（缺/错 token）+ `WWW-Authenticate: Bearer realm="nodehub"`；`403`（scope 不足）。

### 4.5 SQLite 使用要点 (Go 侧)

- **驱动选型**（二选一，见 §6 决策点 2）：
  - `modernc.org/sqlite`：纯 Go，**无 CGO**，`go build` 即出单二进制，部署最省心。性能略低但本场景足够。**推荐**。
  - `github.com/mattn/go-sqlite3`：CGO，性能更高，但编译需 gcc，跨机分发略麻烦。
- **必开 PRAGMA**（并发安全）：
  ```sql
  PRAGMA journal_mode=WAL;       -- 读写并发不互斥
  PRAGMA busy_timeout=5000;      -- 写冲突时等 5s 而非立即报错
  PRAGMA synchronous=NORMAL;     -- WAL 下安全且快
  PRAGMA foreign_keys=ON;
  ```
- **单连接 + 连接池设 `SetMaxOpenConns(1)`** 或用 `sqlx` + 串行化写，避免 SQLite「database is locked」。读可并发。

### 4.6 部署形态

```ini
# /etc/systemd/system/nodehub-api.service
[Unit]
Description=nodeHub Data Hub API (Go :8904)
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/git/nodeHub
ExecStart=/opt/git/nodeHub/api/bin/nodehub-api \
    -listen 127.0.0.1:8904 \
    -db /opt/git/nodeHub/data/nodehub.db
EnvironmentFile=/opt/git/nodeHub/.env
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

## 5. 实施步骤 (建议分 3 阶段，可独立验收)

### 阶段 A：静态资源目录化 (安全整改，先做)
1. 建 `static/`，把需要对外下载的 `scripts/`(子集)、`ssl/`、`geodat/` 整理/软链进去。
2. 改 nginx `alias` 指向 `static/`，`nginx -t && reload`。
3. **回归测试**：在一台节点上确认 `${NODEHUB_URL}/scripts/probe/probeTask.sh`、`/ssl/<domain>.pem` 仍能下载。
4. 确认 `.env` / `logs/` / `.git/` 已**不可**通过 web 访问。

### 阶段 B：Go API 骨架 (鉴权 + 读写闭环)
5. `api/` 下 `go mod init`，搭 `cmd/nodehub-api/main.go` + config + store + handler。
6. 实现 SQLite 建表迁移 + `api_tokens` / `data_items` 表。
7. 实现 Bearer 鉴权中间件 + scope 校验。
8. 实现 `PUT/GET/DELETE /api/v1/data/{ns}/{key}` 四个端点。
9. 实现 CLI 子命令 `token create/list/revoke`。
10. 写 systemd unit，`systemctl enable --now`，绑 `127.0.0.1:8904`。

### 阶段 C：nginx 接入 + 联调
11. nginx 加 `location /api/` 反代 + `limit_req zone=api`。
12. 用真实节点脚本做一次端到端 write→read 冒烟。
13. 补 `.gitignore`（`data/`、`api/bin/`）。

---

## 6. ⚠️ 需要你拍板的决策点 (阻塞实施)

### 决策 1：Go API 与现有 Python `ssr-monitor-api` 的边界？(最重要)
本机已有 Python 版在做「token + SQLite + 读写 API」。新 Go 版上线后会出现「两个中心」。三选一：
- **(a) 各管各的**：Go 版做**通用数据中枢**（任意项目存任意 KV），Python 版继续只管**监控领域数据**。→ 推荐。职责清晰，互不迁移。
- **(b) Go 版逐步取代 Python 版**：把 monitor 的 ingest/read 也迁到 Go。→ 工作量大，且 Python 版带大量分析脚本，短期不建议。
- **(c) 合并成一个**：扩展现有 Python 版做通用 KV，不另起 Go。→ 违背你「用 Go 写」的初衷，不推荐。

> 我的建议：**(a)**。Go 版定位为「跨项目通用数据总线」，Python 版是「监控垂直域」。两者 DB、端口、域名都独立。

### 决策 2：SQLite 驱动 — 纯 Go 还是 CGO？
- 追求**部署简单 / 单二进制 / 不依赖 gcc** → `modernc.org/sqlite`（推荐）。
- 追求**极致写性能** → `mattn/go-sqlite3`（CGO）。
> 本场景写入量不大，推荐纯 Go。

### 决策 3：对外域名 / 端口
- 复用 `test-kod.freessr.bid:8443/api/`（和静态同站）？
- 还是新开一个域，如 `hub.freessr.bid`（独立 conf，便于单独限流/日志）？
> 推荐复用 `/api/` 路径前缀，省一张证书、省一个 conf；若日后流量大再拆域。

### 决策 4：「中枢」的数据语义到底是不是通用 KV？
- 我**默认按「通用 namespace+key KV」设计**（最灵活、最 hub）。
- 如果你心里其实是某个**具体**的数据交换场景（比如只交换节点状态/配置），那应该走**专用 schema**，模型会更窄但更稳。
> 请确认是否「通用 KV」。

---

## 7. 与现有系统的关系 (避免重复造轮子)

| 组件 | 定位 | 是否受影响 |
|---|---|---|
| `ssr-monitor-api` (Python :8903) | 监控垂直域：探针/握手/JA3/流量上报与分析 | 不变，Go 版不碰它的 DB/端口 |
| nodeHub 静态下载 (`/node_hub`) | 节点拉取脚本/证书 | **改造**：alias 收窄到 `static/` |
| 新 Go API (`:8904`) | 跨项目通用数据总线 (本次新增) | 新增 |

> 一句话：**静态下载收窄、新增一个通用数据总线、不动现有监控服务。**

---

## 8. 风险与注意事项

| 风险 | 影响 | 缓解 |
|---|---|---|
| 静态目录化后，老路径 `${NODEHUB_URL}/scripts/...` 失效 | 节点脚本下载失败 | 阶段 A 必须保留原相对路径结构 (`static/scripts/...`) 或在 nginx 做 301 兼容 |
| SQLite 并发写锁 (`database is locked`) | 高并发写时 5xx | WAL + busy_timeout + 写串行化；本场景基本碰不到 |
| Token 明文丢失 | 无法找回，只能重建 | 明文仅返回一次；DB 只存 hash，与 Python 版一致 |
| `data/nodehub.db` 被误纳入 git | 仓库膨胀 / 数据泄露 | `.gitignore` 加 `data/` 和 `api/bin/` |
| DB 无备份 | 单文件损坏即丢全部数据 | 加 cron 定时 `cp` 到异地 / `.db-wal` 一起备份 |
| Go 二进制与节点架构不匹配 | 分发失败 | 服务端固定 linux/amd64 即可；如需发到节点用 `GOOS/GOARCH` 交叉编译 |
| 两个「中心」治理混乱 (决策 1 未定) | 数据散落两处 | 先定边界再动手 |

---

## 9. 待你确认后我可以做的下一步

- [ ] 拍板 §6 的 4 个决策点
- [ ] 确认后，我可以直接产出：阶段 A 的 `static/` 整理脚本 + nginx diff；阶段 B 的 Go 工程骨架（含建表迁移、鉴权中间件、四个端点、token CLI）。

---

## 附: 技术选型一览

| 项 | 选型 | 备注 |
|---|---|---|
| 语言 | Go 1.26 (本机已装) | 单二进制 |
| HTTP | `net/http` 标准库 | 无需 web 框架；如要路由优雅可上 `chi` |
| SQLite 驱动 | `modernc.org/sqlite` (纯 Go) | 待决策 2 确认 |
| 鉴权 | Bearer Token + sha256 + scope | 照搬 Python 版 |
| 反代/限流/TLS | nginx (已有) | 复用 `test-kod.freessr.bid:8443` |
| 进程管理 | systemd | 与现有服务一致 |
| 端口 | `127.0.0.1:8904` | 仅本地，nginx 前置 |
| 数据模型 | 通用 namespace+key KV (SQLite) | 待决策 4 确认 |
