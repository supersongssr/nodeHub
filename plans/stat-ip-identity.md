# stat 数据按 IP 检索方案 (stat_user)

> 实施: proxyInstall.sh v2.9.0 (2026-08-17) · 关联: plans/node-name-identity.md
> 演进: v2.6 HMAC+STAT_PEPPER → v2.7 sha256("stat:"+ip)[:12] → **v2.9 md5(ip)** (最终: 方便优先)

## 1. 需求与威胁模型

- 动态节点的身份实际绑定**服务器** (以 IP 标识, IPv4 优先)。
- 外部项目消费公开的 ServerStatus 数据时, **只知 IP** 就要找到自己节点那一行。
- stat 数据公开, IP 不能以明文出现 (username 是 md5 值, 非明文 IP)。
- 威胁模型定位: 节点 IP 本就是对外提供代理的公开地址; 挡"直接读出"即可,
  不追求抗蓄意彩虹表反查 (已知取舍, 见 §2)。

## 2. 核心公式 (唯一契约)

```
stat_user = md5( ip )        # 全量 32 位小写 hex, 无前缀无域
```

- **零密钥**: 节点与消费方无需分发任何共享秘密 — 双方各一行代码, 无配置、无轮换。
- **纯 md5**: 消费方 `hashlib.md5(ip)` 直接即得, 任何语言的最简实现。
- **确定性**: 纯 IP 的函数 — 重装 / 面板重置 / NODE_ID 复用 / 改名 / 换组均不变;
  公开数据 `username` 字段匹配即命中本节点那一行。
- **非粘性**: 每次安装按**当前 IP** 重算, 换 IP 自动换新身份,
  服务端旧条目转 offline 待清理。
- **已知取舍**: md5(IPv4) 可被现成彩虹表反查 — 代理 IP 本就是公开地址,
  以此换取"最简、零配置"的检索体验; 如未来需真保密, 见 §7。

## 3. stat 行的字段分工 (仅动态节点; 固定节点人工设 STAT_USER 命名, 不适用本契约)

★节点类别由 `STAT_USER` 是否显式指定决定 (与 proxyInstall 写入的 `node_class` 联动):
设了 = 固定节点 (user 模式无 -g, probeTask 跳过采集); 未设 = 动态节点 (下表)。

| 字段 | 值 | 受众 |
|---|---|---|
| `-u` (username, **检索主键**) | `stat_user` = `6465ec74397c9126916786bbcd6d7601` | ★外部项目 (按 IP 算 md5) |
| `--alias` (展示名) | `node_name` = `node_id` (如 `42`, 面板节点 ID) | 人 |
| `-g` (分组) | `${API_PANEL}` 默认, 可 `STAT_GID` 覆盖 | 动态节点标记 (probeTask 依赖 `-g`) |

## 4. IP 归一化 (节点与消费端必须一致)

1. 选择: 注册上报的 **IPv4 优先** (`node_ip`), 无 IPv4 用 `node_ipv6`;
   消费端只知道 v6 时对 v6 做同样计算 (先试 v4 再试 v6)。
2. 归一化: 去首尾空白/换行 → **转小写** → 去 `%zone` 后缀。
3. 输入串: **裸 IP**, 无任何前缀 (末尾无换行)。

## 5. 消费端实现 (各一行)

**Python**
```python
import hashlib, requests

def stat_user(ip: str) -> str:
    return hashlib.md5(ip.strip().lower().split("%")[0].encode()).hexdigest()

row = next(r for r in requests.get(f"{STAT_URL}/json/stats.json").json()
           if r["username"] == stat_user(my_ip))
```

**Node.js**
```js
const crypto = require("crypto");
const statUser = (ip) =>
  crypto.createHash("md5").update(ip.trim().toLowerCase().split("%")[0]).digest("hex");
```

**Shell**
```sh
stat_user=$(printf '%s' "1.2.3.4" | md5sum | awk '{print $1}')
# 节点本地已持久化: grep stat_user ~/node.env | cat ~/node.stat_user | jq -r .stat_user ~/node.json
```

## 6. 节点侧行为 (proxyInstall.sh v2.9)

- `DeriveStatIdentity()` (Step1_Register 后): IPv4 优先选 IP → 归一化 → md5 →
  写入 `-u`; 失败 (IP 空 / md5sum 缺失) 回退 USER=node_name 并告警, 不中断安装。
- 持久化 (仅为可读, 每次重算覆盖): `~/node.env` (`stat_user=`)、`~/node.stat_user`、
  `~/node.json` (`.stat_user`)。
- 幂等: unit 中 `-u` 或 `--alias` 任一变化 → 自动重写 systemd 配置并重启。
- node_name = node_id (v2.9 归位): alias 展示面板节点 ID, 与面板侧对齐;
  检索职能完全由 stat_user (md5(IP)) 承担, 职责单一。

## 7. 演进路径 (如未来需要真保密)

- 需要抗蓄意枚举时: 升版 `md5` → `HMAC(密钥, ip)` 或前缀 `ip2-`, 双方同步升级,
  新旧并存迁移 (见 v2.6 历史实现, git 可查)。
- 终态: 密钥收敛到面板, register 响应直接下发 `stat_user`, 消费方走带鉴权的
  `GET /api/stat/identity?ip=...` 查询 — 节点与消费项目均零密钥、零公式耦合。

## 8. 迁移 (存量节点)

1. 重跑 proxyInstall: 新 stat_user (md5) 与新 alias (node_id) 自动生效
   (幂等检测发现 `-u`/`--alias` 变化 → 重写 unit);
   ServerStatus 服务端旧条目转 offline, 手动清理一次。
2. 全新节点无任何迁移成本。
