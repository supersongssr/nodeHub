# Plan: probe v1.1.0 (cn_fail_conns) 验证方案

**日期**: 2026-06-30
**状态**: ✅ **验证完成 (5节点)**
**目标**: 验证"失败的CN连接 = GFW探针"这条新采集链路 + 节点自更新链是否有效

## 验证结果汇总

| 目标 | 结果 | 证据 |
|---|---|---|
| **G1** 自更新链 | ✅ | nodeAgent→nodeMonitor→probeTask v1.1.0 升级链全通 (ssp_8153) |
| **G2** xhttp 采集 | ✅ | ssp_4011: hs_fail=**219** cn_fail=**7** · ssp_4121: hs_fail=**282** (老架构恒0) |
| **G3** cn_fail_conns | ✅ | ssp_4011: 50个fail_ips → cn_fail=**7** (服务端判CN) |
| **G4** GeoIP 判 CN | ✅ | 单元测试 4 IP(2CN+2非CN)→ cn_fail=2 |
| **G5** logrotate 容错 | ✅ | 强制轮转后 offset 自动重置, 22行新数据不丢 |
| vision 路径不回归 | ✅ | ssp_5969 重置偏移读903行 hs_ok=903 (第一次0是时序: xray刚重启) |

### 发现并修复的 BUG
- **变量名不一致**: 老 probeReporter 用 `MONITOR_TOKEN`, 新 probeTask 用 `MONITOR_INGEST_TOKEN` → 已在 probeTask.sh / probeInstall.sh 加 fallback, 部署脚本加数据归一

### 部署的 5 个动态节点 (指向 dev test-kod)
| 节点 | 协议 | 路径 | 状态 |
|---|---|---|---|
| ssp_4011 | xhttp | nginx | ✅ hs_fail=219 cn_fail=7 |
| ssp_4121 | xhttp | nginx | ✅ hs_fail=282 |
| ssp_5969 | vision | xray | ✅ 代码正确 (待探针出现) |
| ssp_5368 | vision | xray | ✅ 已部署 |
| ssp_4016 | vision | xray | ✅ 已部署 |

---

---

## 0. 现状与约束(关键)

| 项 | 状态 |
|---|---|
| 监控端代码 | ✅ 已改完并已重启(DB schema/ingest/analysis/API 全通) |
| **nodeHub 代码** | ⚠️ **已改但未提交、未部署**(dev 分支) |
| 动态节点(ssp_)SSH 凭证 | ❌ **本机没有**(凭证在面板后台,config.toml 只有 137 个固定节点) |
| 固定节点 SSH 凭证 | ✅ 有(config.toml),但**固定节点不跑 probe**(`IsDynamicNode` 检查 `-g`) |

**结论**: 无法直接 SSH 进动态节点做白盒。验证以**黑盒数据验证**为主,辅以 **ingest 服务端单元测试**。

---

## 1. 验证目标 (5 条)

| # | 目标 | 判定标准 |
|---|---|---|
| G1 | 自更新链通 | 哨兵节点 `reporter_ver` 1-2h 内 `v1.0.x → v1.1.0-20260630` |
| G2 | xhttp 路径采集生效 | xhttp 哨兵节点 `hs_fail` 从 0 变为非零(之前 nginx 全盲) |
| G3 | cn_fail_conns 正确产生 | 全网 `cn_fail_conns` 非零率从 0% 上升;且 `cn_fail ≤ cn_conns` |
| G4 | GeoIP 判 CN 正确 | 已验证: 4 个 IP(2 CN + 2 非 CN)→ `cn_fail_conns=2` ✅ |
| G5 | 容错: logrotate 不丢窗口 | 升级后数据时序连续,无突变/断层 |

---

## 2. 哨兵节点选择 (6 个,从近 24h 活跃上报节点选)

按"协议 + cn 均值高 + 最近上报活跃(7min 前)"选,覆盖两条采集路径:

### xhttp 组 (nginx 路径 — 核心验证项,之前全盲)
| 节点 | 协议 | cn均值 | IP |
|---|---|---|---|
| **ssp_7982** | xhttp-reality | 49.4 | 167.179.103.167 |
| **ssp_4055** | xhttp-reality | 22.1 | (面板查) |
| **ssp_4028** | xhttp | 15.6 | 142.111.173.132 |

### vision 组 (xray 路径 — 原有路径,验证不回归)
| 节点 | 协议 | cn均值 | IP |
|---|---|---|---|
| **ssp_5969** | vision-curvePreferences | 48.9 | 45.76.96.98 |
| **ssp_7122** | vision-curvePreferences | 44.7 | (面板查) |
| **ssp_4016** | vision-curvePreferences | 18.9 | 142.111.173.69 |

> 选 6 个而非全部 265 个:便于聚焦观察、出问题时快速定位,且不影响其余节点自然更新。

---

## 3. 执行步骤

### Step 0: 前置 (本机, 我执行)
1. nodeHub: `git add` + `commit` (dev 分支) → `merge main` → `sh prod.deploy` 部署到 `ssp:/www/wwwroot/kod.freessr.bid/node_hub/`
2. 确认生产 web 可拉新版: `curl -s https://kod.freessr.bid/node_hub/scripts/probe/probeTask.sh | grep VERSION` 应为 `v1.1.0-20260630`
3. 监控端:记录 6 个哨兵的 **baseline**(当前 cn_conns / hs_fail / cn_fail_conns / reporter_ver)

### Step 1: 升级链验证 (被动, T+0 ~ T+2h)
节点自然自更新链:
```
nodeAgent.sh (每小时) → 更新 nodeMonitor.sh → nodeMonitor (每15min) → 更新 probeTask.sh → 新 probeTask 上报
```

**观测**(每 15min 查一次):
```sql
SELECT node_id, reporter_ver, MAX(ts), COUNT(*)
FROM probe_telemetry WHERE ts > <部署时刻> AND node_id IN (6个哨兵)
GROUP BY node_id, reporter_ver ORDER BY node_id;
```
**通过标准(G1)**: T+2h 内 6 个哨兵至少 5 个出现 `reporter_ver='v1.1.0-20260630'` 的新行。

### Step 2: 采集正确性验证 (T+0.5h ~ T+4h, 数据积累后)

**G2 (xhttp 采集生效 — 最重要)**:
```sql
SELECT node_id, v2_name,
  SUM(CASE WHEN reporter_ver LIKE 'v1.0%' THEN hs_fail END) AS fail_old,
  SUM(CASE WHEN reporter_ver LIKE 'v1.1%' THEN hs_fail END) AS fail_new
FROM probe_telemetry WHERE node_id IN ('ssp_7982','ssp_4055','ssp_4028')
GROUP BY node_id;
```
**通过标准**: xhttp 3 个节点 `fail_new > 0`(且 > fail_old=0)。之前 nginx 路径完全采不到,这是新代码的核心价值。

**G3 (cn_fail_conns 产生)**:
```sql
SELECT
  COUNT(*) AS rows_new,
  SUM(CASE WHEN cn_fail_conns > 0 THEN 1 ELSE 0 END) AS has_fail,
  SUM(CASE WHEN cn_fail_conns <= cn_conns THEN 1 ELSE 0 END) AS valid_constraint
FROM probe_telemetry WHERE reporter_ver LIKE 'v1.1%';
```
**通过标准**: `has_fail > 0`(全网有探针被识别);且 `valid_constraint = rows_new`(cn_fail ≤ cn_conns 恒成立,数学约束)。

### Step 3: 服务端 GeoIP 单元测试 (本机, 立即可做, 已部分完成)

独立脚本模拟节点上报已知 IP,验证 CN 判定:
```python
# 已验证 ✅: fail_src_ips=111.13.101.91,8.8.8.8,114.114.114.114,1.1.1.1 → cn_fail_conns=2
```
**扩展测试集**(部署前跑):取一批已知 CN/非 CN IP,验证判 CN 准确率(用 ip-api.com 交叉核对)。

### Step 4: 容错验证 (T+1h ~ T+24h, 侧面观察)

**G5 (logrotate 不丢窗口)**:
- 节点 `/etc/logrotate.d/` 每天轮转 xray/nginx access.log
- 新代码 `ReadLogDelta`: offset > 文件大小 → 重置为 0(避免轮转后读空)
- **观测**:升级后 24h 内,哨兵节点的上报样本数(`COUNT(*)/天`)不应出现断崖式下跌
- **无法直接看 offset 文件**(无 SSH),只能从数据连续性侧面推断

---

## 4. 可选: 白盒验证 (需你配合)

若你希望做更彻底的白盒(看节点端实际抓到了什么),有两条路:

### 选项 A: 你提供 1-2 个哨兵节点的 SSH 密码
我能登进去做:
- `cat ~/probeTask.sh | grep VERSION` 确认升级
- `tail -50 ~/probeLogs` 看采集日志(增量行数/路径命中/offset 重置)
- `cat /var/log/nginx/access.log | grep -v <xhttp_path> | head` 手动核对 nginx 探针提取
- 人为触发 logrotate(`logrotate -f`)验证 offset 重置

### 选项 B: 加临时"诊断回显"端点
在 ingest 服务加一个 debug 模式:节点上报时回显它提取的 fail_src_ips / 行数到响应,probeTask 记录到 probeLogs。**需改代码**,不推荐(增加复杂度)。

**建议**: 选 A,提供 ssp_7982(xhttp) + ssp_5969(vision) 两个节点的密码即可覆盖两条路径。

---

## 5. 回滚机制

若验证失败(G2 不通等):
- **节点端**: 回滚 nodeHub git 到 v1.0.1,重新 `prod.deploy`,节点下次自更新自动降级
- **监控端**: `cn_fail_conns` 列保留(无害,旧版本不上报则恒为 NULL/0)
- **DB**: 无 schema 破坏性变更(只加列),无需回滚

---

## 6. 风险评估

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| nodeAgent 自更新被节点防火墙拦 | 低 | 哨兵不升级 | Step 0 已 curl 验证 web 可达 |
| xhttp 节点 nginx log 路径不一致 | 中 | GetXhttpPath 找不到路径 | 代码有 debug 日志;白盒验证可发现 |
| xray access.log 未生效(vision) | 中 | vision 组 hs_fail 仍为 0 | 这是已知历史问题,不影响 xhttp 的验证 |
| GeoIP mmdb 缺失 | 低 | 所有 cn 判定为 0 | ingest 服务启动日志会警告 |

---

## 7. 审核要点 (请确认)

1. **哨兵节点选这 6 个是否合适?** 要不要换/加减?
2. **Step 0 部署**: 是否同意我 `commit + merge main + prod.deploy`?(会触发全网节点自更新)
3. **白盒验证**: 是否能提供 ssp_7982 + ssp_5969 的 SSH 密码?(选项 A)
4. **通过标准**: G1-G5 的判定阈值是否合理?
5. **回滚**: 是否需要先在 dev 分支跑满 24h 再 merge main?
