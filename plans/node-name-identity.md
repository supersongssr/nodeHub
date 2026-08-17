# 节点统一命名方案 (node_name)

> 实施: proxyInstall.sh v2.4.1 + scripts/serverstatus_client_install.sh v1.1.0 (2026-08-17)
> v2.4.1: ① node_name 粘性持久化 (重装不换名) ② 恢复默认 group 模式 (修复 probe 判定回归)
>         ③ node_class=dynamic 显式化动态/固定判定 (probeTask.sh 优先读取)

## 1. 目标

每个动态注册的节点拥有一个**稳定、可读、唯一**的 `node_name`。
之后所有调用——ServerStatus 面板查询、面板 API、人工运维——**只需 name 即可定位节点**,无需再记 node_id / IP / 分组等。

## 2. name 生成规则 (优先级从高到低)

| 优先级 | 来源 | 示例 |
|---|---|---|
| 1 | 环境变量 `NODE_NAME`(人工改名唯一入口) | `NODE_NAME=my-custom-node` |
| 2 | `~/.env` 中的 `NODE_NAME` | 同上 |
| 3 | `STAT_NAME` | 兼容旧变量 |
| 4 | **粘性复用**: `~/node.env` 已持久化的 `node_name` ★重装不换名 | — |
| 5 | 面板注册回传的 `v2_name`(仅首次) | `sgp-hy2-01` |
| 6 | 自动生成 `${API_PANEL}_${NODE_ID}` | `ssp_42` |

★ 粘性设计 (v2.4.1): 首次生成后持久化, 之后重装/重跑一律复用旧值; 
面板 v2_name 改名**不会**自动同步 (需 NODE_NAME 环境变量显式改名)。
目的: 保证 name 永久固定, ServerStatus 不产生孤儿条目。

**清洗规则** (`SanitizeName`): 转小写 → 空格/斜杠/点转 `-` → 仅保留 `[a-z0-9_-]` → 压缩连续分隔符 → 去首尾分隔符。
极端清洗后为空时兜底 `node_${NODE_ID}`。

## 3. name 三处持久化 (随处可读)

| 位置 | 形式 | 读取方式 |
|---|---|---|
| `~/node.env` | `node_name="sgp-hy2-01"` | `source ~/node.env` 后直接用 `$node_name` (nodeAgent/nodeMonitor/manage.sh 均可) |
| `~/node.name` | 单行纯文本 | `cat ~/node.name` (给 systemd/监控探针/人工) |
| `~/node.json` | `"node_name": "sgp-hy2-01"` | `jq -r '.node_name' ~/node.json` |

## 4. ServerStatus 接入 (name 即索引)

- `stat_client --alias ${node_name}` — ServerStatus 面板上**直接搜 name** 即可查到节点数据
- `-u USER` 默认 = `node_name`(v2_name 面板侧唯一;重装时面板回传同名 → USER 稳定,不产生孤儿条目)
- `STAT_USER` 显式指定时仍优先
- systemd unit:
  - `Description=ServerStatus-Rust Client (sgp-hy2-01)` — `systemctl status stat_client` 一眼可见节点名
  - `Environment=NODE_NAME=sgp-hy2-01` — 服务进程内可直接读
  - 参数快照落盘 `/opt/ServerStatus/client/stat_client.args`

## 5. 关键时序调整

```
原: Step0 → Step0.5(ServerStatus, alias=NODE_ID) → Step1(register, 回传 v2_name)
新: Step0 → Step1(register, 回传 v2_name) → ResolveNodeName → PersistNodeName → Step0.5(ServerStatus, alias=node_name)
```

原因: name 的主来源 `v2_name` 在 Step1 注册回传后才最终确定。
附带收益: Step1 失败(节点未注册成功)时不再安装监控,语义更合理。

## 6. 幂等 / 重装行为

- node_name 粘性复用 → 重装后 alias 不变 → stat_client 跳过重写
- 仅当 `NODE_NAME` 环境变量显式指定新名时才重写 unit (人工改名入口)
- 子脚本检测二进制已存在时跳过重复下载
- 旧节点升级注意: 首次重装后 USER 从 `${API_PANEL}_${NODE_ID}` 变为 `node_name`,
  ServerStatus 服务端旧条目会残留为 offline, 可按旧 USER 清理一次
  (全新节点无此问题; v2_name 未变的重装节点 USER 也不变)

## 6.5 动态/固定节点判定 (v2.4.1 显式化)

| | 动态节点 | 固定节点 |
|---|---|---|
| 安装方式 | proxyInstall.sh 批量自动装 | 人工 (server_status/status.sh 等) |
| stat_client 模式 | group (`-g`, 默认) | user (无 `-g`) |
| node_id | apply_id 自动分配 | 无此流程 |
| 生命周期 | 被墙自动回收 | 长期存活, SSH 凭证在 probe config.toml |
| probe 探针采集 | ✅ | ❌ (IsDynamicNode 直接退出) |
| ~/node.env node_class | `dynamic` (v2.4.1+ 写入) | 无此文件/字段 |

判定链 (probeTask.sh IsDynamicNode): `node_class=dynamic` 显式声明 → 兕底 `grep ' -g '` stat_client.service。
⚠ 不要用"是否有 node_name"判定节点类型 — 两类节点都可拥有 name。
⚠ Step0_5 默认模式必须保持 group: 改成 user 会把新装动态节点误判为固定 → probe 静默停止。

## 7. 面板侧约定 (后续配合)

- 面板已有 `v2_name`(register 时上报),按 name 查询节点的 API 可直接以 `v2_name` 为索引键
- 建议面板 API 支持 `node_name=` 参数查询(向后兼容 `node_id=`)
