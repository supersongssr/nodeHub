# 节点统一命名方案 (node_name / stat_user)

> 实施: proxyInstall.sh v2.9.0 (2026-08-17) · 关联: plans/stat-ip-identity.md

## 1. 当前规则 (v2.9, 最终形态)

两个身份各司其职:

```
node_name = node_id                       # 面板分配的节点 ID, 稳定不变
stat_user = md5(IP)                       # 全量 32 位小写 hex, IPv4 优先, 零密钥
```

ServerStatus 客户端参数:

```
stat_client -u <stat_user> --alias <node_name> [-g <group>]
             └─ username, 行主键          └─ 展示名 (面板上显示节点 ID)
```

### 字段分工

| stat_client 参数 | 字段 | 值 | 受众 |
|---|---|---|---|
| `-u` (username, **行主键**) | `stat_user` | `md5(IP)` | ★外部项目: 只知 IP → 算 md5 → 匹配 username 字段即命中 |
| `--alias` (展示名) | `node_name` | `node_id` | 人 (面板显示节点 ID, 与面板侧对齐) |
| `-g` (分组) | group | `${API_PANEL}` 默认, 可 `STAT_GID` 覆盖 | 动态节点标记 (probeTask 依赖 `-g`) |

### 关键性质

| 性质 | 说明 |
|---|---|
| **node_name 稳定** | = 面板分配的 node_id, 重装不变; alias 无唯一性约束 (主键是 -u) |
| **stat_user 纯函数** | 只看 IP — 重装 / 面板重置 / NODE_ID 复用 / 换组 / 改名均不变 |
| **零密钥** | 外部项目 `hashlib.md5(IP)` 一行代码即得, 无 pepper/NODE_ID/面板信息 |
| **非粘性 (stat_user)** | 每次安装按当前 IP 重算; 换 IP → 换新身份, 旧条目转 offline 待清理 |
| **IP 不以明文出现** | 公开数据中 username 是 md5 值, 非明文 IP; 已知取舍: md5(IPv4) 可被彩虹表反查 (代理 IP 本就是公开地址) |
| **显式覆盖入口** | `NODE_NAME`/`STAT_NAME` 覆盖 alias; `STAT_USER` 覆盖 username (覆盖后按 IP 检索契约失效) |

### IP 归一化 (节点与消费端必须一致)

选择: 公网 IPv4 (`node_ip`) 优先 → IPv6 (`node_ipv6`);
归一化: 去空白/换行 → 小写 → 去 `%zone` 后缀。
例: `md5("1.2.3.4") = 6465ec74397c9126916786bbcd6d7601`

## 2. 持久化 (随处可读)

| 位置 | node_name | stat_user |
|---|---|---|
| `~/node.env` | `node_name="42"` | `stat_user="6465ec74..."` |
| `~/node.name` / `~/node.stat_user` | 单行纯文本 | 单行纯文本 |
| `~/node.json` | `.node_name` | `.stat_user` |

systemd unit: `Description=ServerStatus-Rust Client (42)` + `Environment=NODE_NAME=42`;
参数快照: `/opt/ServerStatus/client/stat_client.args`

## 3. 消费端示例

**Python**
```python
import hashlib
stat_user = hashlib.md5(ip.strip().lower().split("%")[0].encode()).hexdigest()
row = next(r for r in stats_json if r["username"] == stat_user)
```

**Shell**
```sh
printf '%s' "1.2.3.4" | md5sum | awk '{print $1}'
```

## 4. 时序与幂等

```
Step0(node_id) → Step1_Register(采集 node_ip) → ResolveNodeName(=node_id)
  → PersistNodeName → DeriveStatIdentity(=md5(IP)) → Step0_5(ServerStatus)
```

- 重装同 IP: stat_user/alias 均不变 → Step0_5 幂等跳过
- 换 IP / 改 NODE_NAME: unit 中 `-u` 或 `--alias` 变化 → 自动重写并重启
- stat_user 派生失败 (IP 空 / md5sum 缺失): USER 回退 node_name + 告警, 不中断安装

## 5. 演进记录

| 版本 | node_name (alias) | stat_user (-u) |
|---|---|---|
| v2.4 | `${API_PANEL}_${NODE_ID}` | 无 (user=alias) |
| v2.5 | `+md5(IP)[:6]` 后缀 | 无 |
| v2.6 | 后缀 HMAC(pepper) | 无 |
| v2.7 | `+sha256("name:"+IP)[:6]` + 粘性 | 无 |
| v2.8 | `md5(IP)` (角色错位: alias 承担检索) | sha256("stat:"+IP)[:12] |
| **v2.9 (当前)** | **`node_id`** (稳定展示名) | **`md5(IP)`** (检索主键, 角色归位) |
