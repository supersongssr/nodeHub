# 端口被墙自动换端口自愈 (DailyPortBlockCheck)

> 实施: nodeAgent.sh · 依赖: proxyDiagnose.sh NW10 大陆 tcping 检测 · 2026-09-01

## 1. 背景与目标

检测到一类节点故障: **IP 未被墙、仅端口被墙** —— 大陆三网对 `node_port` 的 TCP
握手全部超时, 但本机监听 / 证书 / 海外访问全部正常, 用户侧却完全连不上。
此类节点**换一个端口即可快速复活**, 无需换 IP / 套 CDN / 中转。

目标: nodeAgent 每日自动检测 `node_port` 是否被墙; 在确认「IP 未被墙 + 端口三网
全屏蔽」时, 自动以随机端口重装 `proxyInstall.sh`, 并 Telegram 通知被墙情况与
处置结果。

## 2. 检测原理 (复用 proxyDiagnose.sh, 不重复造轮子)

每日从 `${NODEHUB_URL}` 下载 `proxyDiagnose.sh`, 以
`--target net --json --quiet --no-notify` 运行 (约 1-3 分钟), 解析结果码:

| 结果码 | 级别 | 语义 |
|---|---|---|
| `NODE_PORT_CN_BLOCKED` | FAIL | 端口三网+云厂全断 且 海外正常 (端口或 IP 被墙) |
| `NODE_PORT_CN_XCHECK_PORT` | PASS | 交叉验证: 随机新临时端口大陆可达 → **端口级封锁, IP 未被墙** ★ |
| `NODE_PORT_CN_IP_BLOCKED` | FAIL | 交叉验证: 新端口大陆亦全断 → IP 级被墙 |
| `NODE_PORT_CN_XCHECK_IP / MIXED` | WARN | 网级 / 混合封锁 |
| `CN_XCHECK_INCONCLUSIVE` | WARN | 无法判定 (临时端口被安全组拦等) |
| `CN_XCHECK_SELFTEST_OK` | PASS | 自检: 原端口大陆全通时, 随机新端口亦大陆可达 → 「新端口被墙测试」逻辑可信 |
| `CN_XCHECK_SELFTEST_CONFLICT` | WARN | 自检: 原端口大陆全通但随机新端口大陆断 → 结果自相矛盾 (高端口段被 IDC/中间设备拦截, 或测试代码有问题); 不参与处置 |

交叉验证由 proxyDiagnose 自动完成, 两种触发场景: ① 检出封锁时本机随机开一个临时
TCP 端口再测一轮 —— 新端口大陆通 = 端口级; 新端口大陆也断 = IP 级; ② 原端口
大陆全通 (`NODE_PORT_CN_OK`) 时也照测一轮自检 —— 随机新端口未被业务使用、
理应同样可达, 测出矛盾 (`SELFTEST_CONFLICT`) 即提示测试逻辑存疑。自检结果码
不影响本方案处置矩阵 (nodeAgent 只识别 BLOCKED / XCHECK_PORT / IP_BLOCKED)。

## 3. 处置矩阵 (must 约束)

| 检测组合 | 处置 | Telegram |
|---|---|---|
| 未检出三网全断 (OK / 单网 PARTIAL / 纯 UDP 跳过) | 无动作, 当日收工 | 不通知 |
| `BLOCKED` + `XCHECK_PORT` (IP 未被墙 + 端口三网全屏蔽) ★ | **随机端口重装** | ✅ 通知: 被墙情况 + 已重装 + 旧→新端口 + 重装结果 |
| `BLOCKED` + `IP_BLOCKED` | 不重装 (换端口无效) | 通知: IP 级被墙, 建议 CDN/中转/换 IP |
| `BLOCKED` + 无定论 (INCONCLUSIVE/MIXED/被跳过) | 不重装, 稍后重试 | 通知: 未能确认端口级, 当日最多重试 3 次 |
| `BLOCKED` + `XCHECK_PORT` 但处于换端口冷却期 | 不重装 | 通知: 冷却期内, 避免频繁重装 |

重装前提**必须同时满足** `NODE_PORT_CN_BLOCKED` 与 `NODE_PORT_CN_XCHECK_PORT`
两个结果码 —— 任何一个缺失都绝不重装。

## 4. 重装流程

1. 随机选端口: 20000-60000, 避开【历史已用端口 (nodeAgent.portswap.log 出现过的
   全部端口, must: 新端口从未被占用过)】/ 当前端口 / hy2 port-hop 区间 30000-32000 /
   已监听端口 (`ss -H -tuln` 校验), 最多尝试 30 次;
2. `cd /tmp && wget -N ${NODEHUB_URL}/proxyInstall.sh`;
3. `NODE_PORT=<随机端口> sh proxyInstall.sh` —— `NODE_PORT` 环境变量在安装脚本
   四层优先级 (环境变量 > ~/.env > node.env > node.json) 中最高, 必然覆盖旧端口;
   Step1_Register 注册时新端口上报面板, 回传后持久化到 `~/node.json` / `~/node.env`;
4. 重装后从 `~/node.json` 读回**实际**端口 (面板回传值优先), 写历史并通知。

## 5. 调度与防抖

- **每日一次**: 默认每天 `NODE_PORT_CHECK_HOUR`(=5) 点后的首个 cron 周期执行;
  错过窗口 (如宕机) 当日可补跑;
- **状态文件** `~/nodeAgent.portcheck.state` (`date/attempts/done/last_swap`):
  - `done=1` → 当日已有定论 (未墙 / 已处置), 不再跑;
  - `attempts ≥ 3` → 探测服务 (tcp.ping.pe) 异常致无定论时, 下个小时重试,
    当日最多 3 次止损;
- **冷却** `NODE_PORT_SWAP_COOLDOWN`(=72000s/20h): 距上次换端口不足冷却期时
  只通知不重装, 防止封锁追踪新端口导致每日连环重装;
- **历史** `~/nodeAgent.portswap.log`: 每次换端口一行 (时间 旧→新端口 重装结果);
  出现过的全部端口永久拉黑, 随机选新端口时绝不复用 (换下的端口大概率已被墙);

## 6. 开关 / 调参 (~/.env)

| 变量 | 默认 | 说明 |
|---|---|---|
| `NODE_PORT_BLOCK_CHECK` | 1 | 0 = 关闭整个检测 |
| `NODE_PORT_CHECK_HOUR` | 5 | 每日最早执行小时 (0-23) |
| `NODE_PORT_SWAP_COOLDOWN` | 72000 | 换端口冷却秒数 |
| `NODE_CN_TCPING` (proxyDiagnose 侧) | 1 | 0 = 关闭大陆 tcping → 本检测随之失效 |
| `NODE_CN_TCPING_XCHECK` (proxyDiagnose 侧) | 1 | 0 = 关闭交叉验证 (封锁判定 + 全通自检均不再跑, 每日检测约省 1 分钟) |

## 7. 通知示例

```
🚨 [NodeHub] nodeAgent.sh — 端口被墙检测与自动处置
节点ID: xxx
IP: 1.2.3.4
时间: ...
■ 被墙情况: NODE_PORT=443 三网+云厂全断 (大陆探测点全超时), 海外正常
■ 交叉验证: 随机新端口大陆可达 → IP 未被墙, 端口级封锁
■ 处置: 已自动重装 proxyInstall.sh, 端口 443 → 36315 (随机)
■ 重装结果: ✅ 成功 (新端口已生效并同步面板)
```

## 8. 配套改动

- `proxyDiagnose.sh` 新增 `--no-notify`: 抑制其自带 Telegram 推送 —— 供 nodeAgent
  程序化调度使用, 由调用方按自身语义统一组织通知, 避免一次事件双重告警。
- 已知限制: tcping 只能测 TCP —— `node_port` 仅承载 UDP (Hysteria2 直听) 时
  proxyDiagnose 自动跳过被墙判定, 本功能随之不生效 (UDP 封锁需用户侧实测)。
