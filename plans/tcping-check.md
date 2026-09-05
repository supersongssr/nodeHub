# tcping 被墙检测方案 (tcpingCheck.py + /ingest/tcping + 并集判定)

> 实施: 2026-09-05 · 关联: plans/stat-ip-identity.md (stat_user 契约) ·
> ServerStatus-Rust-Moniter: monitor/core/checks/tcping_client.py (同源同步) ·
> 取代: plans/port-block-auto-swap.md 的 proxyDiagnose 下载执行路径 (节点端换端口自愈随之移除 — 处置移交远程面板统一下发; 检测引擎换为 tcpingCheck.py)

## 1. 需求与动机 (why)

- stat_client 的三网丢包由探测点对节点做 **ICMP ping, 双栈节点优先走 IPv6**,
  而用户实际连接的是 `IPv4:node_port` —— v6 通不代表 v4 业务端口可达,
  用丢包率判"被墙"系统性偏差.
- 需要**与用户链路同构**的测试: 对 `<node_ip:node_port>` 直接做大陆方向
  TCP 握手 (借 tcp.ping.pe 大陆探测点: 电信/联通/移动/厂商 IDC + 海外对照).

## 2. 架构 (what)

```
┌─ 节点 (nodeAgent.sh, 每小时 cron) ────────────────────────────┐
│ 0. 主流程: 采集/上报面板 → 自更新 → SSL 同步 → 补丁             │
│    └ 检测后台异步 (TcpingPortCheckBg + pid 锁, 不阻断主流程,   │
│       must) — 一轮 1-3 分钟, 主流程立即返回                    │
│ 1. wget -N ${NODEHUB_URL}/tcpingCheck.py   (复用单一模块, must) │
│ 2. python3 tcpingCheck.py --xcheck auto                        │
│      ├ 主测: <node_ip:node_port> 三网+厂商+海外对照 tcping      │
│      ├ 判定: blocked(大陆组全断+海外正常)/partial/unreachable/  │
│      │        ok/not_listening(纯UDP不判)                      │
│      └ 交叉验证(blocked时): 本机随机开临时端口再测一轮          │
│           → block_level = port(端口级,IP未墙)★ / ip(IP级) /     │
│                         unknown(无定论,绝不误判)   (must)      │
│ 3. 推送 POST /ingest/tcping (token 内置默认开箱即推, 失败重试 │
│    1 次; must: 运行完上报是默认行为)                          │
│ 4. 处置: 节点端不自愈 — 换端口重装等由远程面板基于推送数据      │
│    统一下发 (must: 决策集中在远程, 防单组误判触发破坏性重装)    │
│ 5. TG 通知仅在状态迁移时发一次 (非blocked→blocked各级别 /       │
│    blocked→ok 恢复); 流程日志 info/debug 级不走 TG             │
└────────────────────────┬───────────────────────────────────────┘
                         ▼
┌─ ServerStatus-Rust-Moniter ────────────────────────────────────┐
│ POST /ingest/tcping  接收+校验+入库 tcping_report 表            │
│   匹配: stat_user(=md5(IP), nodes_meta.name) > ip(ip_to_name)   │
│ 判定 (must: tcping 为主, stats.json 丢包为辅, 并集取被墙):      │
│   被墙 = tcping.status==blocked ∪ 三网丢包全部>70%              │
│   → block_notify.py 统一告警 (两条证据同列)                     │
│ 页面 cnport.html: 中央轮(每日) + 节点推送(每小时) 双源展示      │
└─────────────────────────────────────────────────────────────────┘
```

## 3. 判定口径 (与中央侧 cn_port_check.py 一致, 宁可漏报不可误报)

| status | 条件 |
|---|---|
| `blocked` | 有探测点的大陆组 (ct/cu/cm/vendor) 中存在全断的组, 且海外 ≥1 成功 (对照证明端口活着) |
| `unreachable` | 海外也全失败 (端口没开/安全组, 非大陆方向问题, 不告警) |
| `partial` | 有组部分失败, 无组全断 |
| `not_listening` | 本机 node_port 无 TCP 监听 (纯 UDP: Hysteria2 直听) — TCP/UDP 独立命名空间, 不判被墙 |
| `ok` | 全部正常 |

### block_level (交叉验证, 只有节点端能做 — must)

主测 blocked 时本机随机开临时 TCP 端口 (20000-60000, 标准库 socket) 再测一轮:

| level | 条件 | 处置 |
|---|---|---|
| `port` | 新端口大陆任一组可达 → 端口级封锁, IP 未被墙 | ★换端口可救 — 重装由远程面板下发 (节点端不自愈) |
| `ip` | 新端口大陆全断 且 新端口海外正常 → IP 级封锁 | 只通知 (换端口无效, 建议 CDN/中转/换IP) |
| `unknown` | 新端口全球不可达 (安全组拦临时端口) / 探测服务异常 | 只通知, 下周期自动复验, 绝不误判 IP 被墙 |

## 4. 复用契约 (must: 避免代码混乱)

同一条 tcp.ping.pe 接口流程 (antiflood cookie → browsercheck → taskStart →
轮询拼接 → 按组统计) 在两处 Python 实现保持同步:

- **节点端正典**: `nodeHub/tcpingCheck.py` (单文件, Python3 原生库,
  含 CLI + xcheck + stat_user 派生, 经 `${NODEHUB_URL}` 分发到节点)
- **中央端正典**: `ServerStatus-Rust-Moniter/monitor/core/checks/tcping_client.py`
  (mypy strict 全注解, `cn_port_check.py` 每日中央轮/页面/告警复用)

`proxyDiagnose.sh` NW10 保留 sh 实现 (人工诊断用, 保持零 python3 依赖);
自动化路径 (nodeAgent 每小时 / 中央每日轮) 全部走上述 Python 模块.
**改动接口流程或判定口径时, 两份 Python 实现必须同步修改.**

## 5. 推送 API 契约

`POST /ingest/tcping` (ServerStatus-Rust-Moniter, token 鉴权, 不走 JWT):

```json
{"token": "...", "node_id": "42",
 "report": {"ts": 1690000000, "ip": "1.2.3.4", "port": 443,
            "stat_user": "<md5(ip) 32hex 或固定 STAT_USER>",
            "status": "blocked", "block_level": "port",
            "blocked_isps": ["ct","cu","cm","vendor"],
            "groups": {"ct": {"ok":0,"total":2}, "...": {}, "os": {"ok":149,"total":150}},
            "agent": "tcpingCheck.py 1.0 (nodeHub)"}}}
```

- **匹配** (must: STAT_USER 或 IP): ① `stat_user` → `nodes_meta.name` 精确
  (动态节点 stats.json name = stat_user); ② `ip` → `build_ip_to_name_map()`
  (nodes_meta.ip + admin ip_info.query).
- **鉴权**: `token` = `[probe_ingest].token` (静态) 或 api_tokens
  (scope=ingest/tcping); 节点侧经 `~/.env` 的 `TCPING_API_TOKEN` 配置.
- **防滥用**: 同 stat_user 60s 内重复上报去重; nginx limit_req (probe 域名)
  复用 ingest 限流; 字段白名单校验 (ip/port/枚举/非负整数).
- **落库**: `tcping_report` 表 (PK stat_user+ts), 保留 30 天;
  `monitor_name` 匹配结果快照入库.

## 6. ServerStatus 被墙判定 (must: 并集)

`block_notify.py` (每日轮):

```
被墙(非CDN在线节点) = [tcping 推送 ≤26h 且 status==blocked]   ← 主
                   ∪ [最新一次三网丢包全部 > 70%]              ← 辅 (stats.json)
```

- 并集 = 最大化检出 (tcping 测握手, 丢包测链路质量, 互补);
  通知正文同时列两条证据 + block_level (port/ip) + 数据新鲜度.
- CDN 节点口径不变 (origin 被墙对用户无意义, 只判解封).
- tcping 数据 >26h 视为 stale (节点失联/出站断), 自动回退纯丢包判定.

## 7. 与旧方案 (plans/port-block-auto-swap.md) 的差异

| | 旧 (DailyPortBlockCheck) | 新 (TcpingPortCheck) |
|---|---|---|
| 频率 | 每日 05 点窗口, 当日 ≤3 次 | 每周期 (小时); 服务异常当日 ≥3 次止损 |
| 执行方式 | 同步阻塞 (拖慢整个 cron 周期) | **后台 subshell + pid 锁, 不阻断主流程 (must)** |
| 引擎 | 下载 proxyDiagnose.sh 跑 `--target net` | 下载 tcpingCheck.py (单模块, 快 1-3 分钟) |
| 端口/IP 区分 | 解析 proxyDiagnose 结果码 | report.block_level (port/ip/unknown) |
| 推送 | 无 | POST /ingest/tcping (判定主数据源) |
| 通知 | 每次检测命中即发 | 状态迁移时发一次 (ok↔blocked / 级别变化 / 恢复); 流程日志 info 级不走 TG, portcheck 桶节流兜底 |
| 换端口处置 | 节点端自动 (冷却 20h + 历史端口拉黑 + port-hop 区间/已监听规避) | 移交远程面板统一下发, 节点端不自愈 (must: 防单组误判触发破坏性重装) |

## 8. 开关 (~/.env)

| 变量 | 默认 | 说明 |
|---|---|---|
| `NODE_TCPING_CHECK` | 1 | 0 关闭整个检测 (旧名 `NODE_PORT_BLOCK_CHECK=0` 兼容) |
| `NODE_TCPING_XCHECK` | 1 | 0 关闭交叉验证 (block_level 恒 unknown → 面板无分级依据) |
| `TCPING_API_URL` | https://probe.freessr.bid | 推送地址 (追加 /ingest/tcping) |
| `TCPING_PUSH` | 1 | 0 关闭结果推送 (默认开 — 运行完上报是默认行为) |
| `TCPING_API_TOKEN` | (内置默认) | 推送 token (内置 [probe_ingest] 同款, 开箱即推; 仅换发 token 时覆盖) |

## 9. 部署 / 灰度步骤

1. **ServerStatus-Rust-Moniter** (监控侧): 拉取本变更 → `./run restart`
   (新表 tcping_report 由 init_db 自动建; `POST /ingest/tcping` 即刻可用;
   block_notify 并集判定随 cron 生效). token 复用既有 `[probe_ingest].token`
   或 `./run token-create --scopes tcping` 另发.
2. **nodeHub → NODEHUB_URL 主机**: 上传 `nodeAgent.sh` + `tcpingCheck.py`
   (节点 SelfUpdate 自动拉新 nodeAgent; tcpingCheck.py 每周期 wget -N).
3. **节点 ~/.env 无需必改**: 推送 token 内置默认 (与 ServerStatus
   [probe_ingest].token 同款), 上传脚本后即开即推; 仅 ServerStatus 侧换发
   token 时才需在 ~/.env 覆盖 TCPING_API_TOKEN (或 TCPING_PUSH=0 关闭推送).
4. 灰度验证: 首个节点跑 `sh ~/nodeAgent.sh` 后看 `~/nodeAgent.tcping.log` +
   监控侧 `GET /api/v1/cn-port-block` 的 `node_reports` + 页面 /cnport.html
   第二张表; `./run tcping <ip:port>` 可从监控侧独立复核.

## 10. 已知边界

- 测的是节点真实 IP:PORT (非 CDN/中转入口); CDN 节点 origin 判定无意义
  (中央轮跳过; 节点推送照收, 判定侧按 v2_name 口径过滤).
- 单探测点抖动可能造成单组误判 (电信仅 1-2 点) — 告警文案注明人工复核;
  节点端已不自动换端口, 单组误判最多产生一次迁移通知, 不会触发破坏性重装
  (处置决策集中在远程面板, 可结合丢包/连接数等多源证据后再下发).
- tcp.ping.pe 为免费第三方, 接口变更 (interface_changed) 时节点端自动跳过
  并止损 (当日 ≥3 次), 恢复后自动续跑.
