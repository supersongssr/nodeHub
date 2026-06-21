# Singbox 配置审计报告 v2（修订版）

> **修订说明**：本版修正 v1 的 4 处错误（见 §1），执行了"移除 insecure 参数"的改动（见 §2），并用**真实订阅输出**做了 NPanel vs SPanel singbox 全量对比（见 §3）与**联通专项封锁分析**（见 §5）。
> **审计时间**：2026-06-17
> **关键方法**：直接 curl 两个面板的真实订阅接口，对返回的 singbox JSON 做字段级比对（非纯代码推断）。

---

## 1. v1 报告的错误修正（致谢复核）

| v1 结论 | 修正后 |
|---|---|
| ❌ `fp=random` 是 sing-box 非法值，会导致整份订阅加载失败（P0） | ✅ **错误**。sing-box 官方 TLS 文档把 `random`/`randomized` 列为合法 uTLS fingerprint。`fp=random` **不会**让订阅加载失败。降级为"兼容性/规避策略考量"，非故障源。 |
| ❌ SPanel hy2 "三者都不下发端口跳跃" | ✅ **不准确**。SPanel **URI 订阅会下发** `mport`（`NodeParser.php:103` 写死 `hy2Mport='30000-32000'`，`UriRenderer.php` 输出）。真正缺失的是 **SPanel 的 SingBoxRenderer 和 ClashRenderer** 不下发 `hop_ports`/`hop-ports`。 |
| ❌ sing-box 1.12+ 两边都失效（笼统） | ✅ **边界不准**。精确：`inet4_address` **1.12 移除**（SPanel）；tun 内 `sniff`/`sniff_override_destination` **1.13 移除**（NPanel）；legacy DNS server 字符串格式 **1.14 移除**（两边）。见 §4。 |
| ❌ "93 个 hy2 / 533 个 random / 0 个 insecure"等 DB 统计 | ✅ **标注为环境快照**。当前机器无独立 mysql 客户端、SPanel `.env` 无 DB 连接信息；这些数字来自通过本机 docker `mysql` 容器查 `test-spanel` 库的一次快照，**不可仅凭仓库文件复现**。本报告所有关键结论改用**真实订阅输出**佐证（§3 附复现命令）。 |

---

## 2. 已执行：从所有配置中移除 `insecure` 参数

### 2.1 改动清单（已完成，6 个文件全部通过 `php -l` 语法校验）

| 文件 | 位置 | 改动 |
|---|---|---|
| `NPanel/.../SubscribeController.php` | URI hy2 | 删除 `&insecure=1&allowInsecure=1` |
| `NPanel/.../SubscribeController.php` | singbox hy2 `tls` | 删除 `"insecure" => true` |
| `NPanel/.../SubscribeController.php` | Clash hy2 | 删除 `skip-cert-verify: true` |
| `NPanel/.../SubscribeController.php` | Loon/Surfboard vmess/vless/trojan（6 处） | 删除 `$skip_cert=', skip-cert-verify=true'` 并清理 `{$skip_cert}` 插值 |
| `NPanel/.../UserController.php` | hy2 `hy2://...?insecure=1` + 文本 `insecure: true` + 3 处 `allowInsecure：true` | 全部删除 |
| `SPanel/.../SingBoxRenderer.php` | hy2 `tls.insecure` | 删除 `'insecure' => !empty($n->hy2Insecure)` |
| `SPanel/.../UriRenderer.php` | hy2 `&insecure=1` 块 | 删除 |
| `SPanel/.../ClashRenderer.php` | hy2 `skip-cert-verify` 设置 + 输出块 | 删除 |
| `SPanel/.../URL.php` | legacy vmess `&allowInsecure=1`（2 处） | 删除 |

校验结果：
```text
grep insecure/skip-cert-verify=true/insecure=1/allowInsecure → 订阅与代码路径中 0 命中
剩余：SPanel SingBoxRenderer vmess/vless/trojan 'insecure' => false（显式校验，正确，保留）
剩余：SPanel Tools.php relay_insecure_mode（中继功能，与 TLS 无关，保留）
全部 6 文件 php -l：No syntax errors detected
```

### 2.2 ⚠️ 移除 insecure 是否安全？—— 安全（实证推翻了 v1 的 P0 判断）

v1 曾担心：SNI 被加前缀 `u{id}u` 后变成二级子域，`*.ssmail.win` 通配证书不匹配 → 移除 insecure 会导致 TLS 失败。

**实证推翻了这个担心。** 抓取 NPanel 真实订阅输出，vision 节点的 `server_name`：
```
server_name = u92un9938.ssmail.win
```
前缀 `u92u` 与原域名 `n9938.ssmail.win` **是直接字符串拼接（无点）**，结果是 `u92un9938.ssmail.win`——仍然是**单标签**子域（`u92un9938` + `ssmail.win`）。证书 `ssmail.win.pem` 的 SAN 为 `*.ssmail.win, ssmail.win`，**单标签子域完全匹配 `*.ssmail.win`**。

**结论**：
- 拼接式前缀不增加域名层级 → 证书始终匹配 → TLS 校验**本来就通过**。
- 所以 v1 的"SPanel hy2 insecure=false 是 P0 故障"判断**根本不成立**（SPanel hy2 即使 insecure=false 也能正常握手）。
- 移除 insecure 是**纯策略/卫生改动**（不再跳过证书校验），**不会引发故障**。
- `insecure` 只影响客户端是否校验证书，**不改变链路上的 TLS 指纹**，因此**与 GFW 封锁无关**（既不会加重也不会减轻封锁）。

> 旁证：vision 节点本就没有 insecure（一直校验证书），且用户确认 vision 稳定 → 反证证书匹配无问题。

---

## 3. NPanel vs SPanel singbox 订阅：全量字段对比

**方法**：curl 真实订阅接口 → 解析返回 JSON → 逐字段比对。
- NPanel：`curl 'https://test-npanel.freessr.bid/s/<code>?app=singbox'`
- SPanel：`curl 'https://test-spanel.freessr.bid/link/<token>?mu=singbox'`

### 3.1 节点 outbound 层（决定能否连上、是否被识别）

| 字段 | NPanel 实测 | SPanel 实测 | 影响 |
|---|---|---|---|
| vision flow | `xtls-rprx-vision` | `xtls-rprx-vision`（NodeParser 归一） | ✅ 一致 |
| xhttp transport | `httpupgrade` | `httpupgrade` | ✅ 一致 |
| SNI 前缀 | `u{id}u` 拼接（非 grpc/ws） | `u{id}u` 拼接（非 cdn/grpc） | ✅ 一致 |
| **utls fingerprint** | **`ios`（硬编码）** | **`random`/`ios`（透传 DB `fp=`）** | ⚠️ 见 §5.2 |
| hy2 `insecure` | （已移除） | （已移除） | ✅ 现已一致 |
| **hy2 `hop_ports`/`hop_interval`** | **DB 有 `v2_hop_ports` 时下发** | **永不下发（渲染器无此逻辑）** | 🔴 **见 §5.1** |
| hy2 `up_mbps`/`down_mbps` | 硬编码 100/100 | 从字段取，常为空→省略 | 次要 |
| hy2 obfs | 不处理 | 从字段处理 | 次要 |

### 3.2 DNS 层（实测）

| | NPanel 实测 | SPanel 实测 |
|---|---|---|
| 远程 DNS | `https://1.1.1.1/dns-query` detour=Proxy | `https://8.8.8.8/dns-query` detour=🚀节点选择 |
| 直连 DNS | `223.5.5.5` detour=direct | `223.5.5.5` detour=DIRECT |
| 规则 | `outbound:any → dns-direct` | `domain_suffix[.cn,节点域] → dns-local` |
| final | 无（靠 route 兜底） | `dns-remote` |
| 格式 | legacy `address` 字符串 | legacy `address` 字符串（+`address_resolver`） |

### 3.3 TUN / route 层（实测）—— 版本绑死不同

| | NPanel 实测 | SPanel 实测 |
|---|---|---|
| tun 地址字段 | `address: ['172.19.0.1/30']`（**1.11+ 新**） | `inet4_address: '172.19.0.1/30'`（**1.10 旧**） |
| tun `sniff`/`sniff_override_destination` | **有**（legacy inbound 字段） | 无 |
| route DNS 劫持 | `protocol:dns → outbound:dns-out`（**legacy**） | `action: hijack-dns`（**1.11+ 新**） |
| route 嗅探 | 无（靠旧 inbound sniff） | `action: sniff`（新） |
| route final | 无（最后一条 catch-all `outbound:Proxy`） | `final: 🚀节点选择` |
| selector 标签 | `Proxy` | `🚀 节点选择`（带 emoji + default） |
| cache_file | `store_fakeip:true`（**但无 fakeip DNS server，无效配置**） | 仅 `enabled`+`path` |

---

## 4. sing-box 客户端版本兼容性（精确边界）

依据 sing-box 官方 deprecated 文档（用户指正）：

| sing-box 版本 | NPanel | SPanel |
|---|---|---|
| **1.11**（当前多数客户端） | ✅ 可用 | ✅ 可用 |
| **1.12** | ✅ 仍可用 | ❌ **`inet4_address` 被移除 → 订阅加载失败** |
| **1.13** | ❌ tun `sniff`/`sniff_override_destination` 被移除 → 失败 | ❌ 同 1.12 |
| **1.14** | ❌ legacy DNS `address` 字符串格式被移除 → 失败 | ❌ 同 |

**关键判断**：这是**客户端兼容性**问题，**不是 ISP 封锁**。若用户 sing-box 自动升级到 1.12+，SPanel 订阅会整体加载失败（看起来像"节点全没了"），但这会**三网同时发生**，与"仅联通被墙"不符。故排除其作为联通封锁主因，但仍建议尽快统一到 1.12+ 规范（§6）。

---

## 5. 联通被墙 / 移动电信稳定 —— singbox 视角专项分析

> 现象：节点（尤其 `xhttp-hy2` / `vision-hy2` 组里的 hy2 子节点）在**联通**频繁被封，**移动/电信稳定**。

### 5.1 🔴 主因候选：SPanel singbox/Clash 不下发 hy2 端口跳跃

**事实链**：
1. 服务端：`proxyInstall.sh::Step3_5_SetupHy2PortHop` 用 nftables/iptables 把 `30000-32000/UDP` 全部重定向到 `node_port`——**ssp/srp 两边节点都执行**，即服务端跳跃端口是开的。
2. 客户端：
   - **NPanel singbox**：当 DB `v2_hop_ports` 有值时下发 `hop_ports` + `hop_interval=30s`（实测代码 `SubscribeController.php` hy2 分支）。
   - **SPanel singbox**：`SingBoxRenderer` **完全没有** hop 逻辑 → 客户端永远只连单一 UDP 端口。
   - SPanel URI 订阅会下发 `mport`（但 singbox/Clash 用户不走 URI）。
3. **联通的 GFW 段对持续高带宽单端口 UDP（hy2/QUIC）有最激进的 QoS/限速/封端口**；移动/电信对 UDP 宽容得多。这正是"联通被墙、移动电信稳定"的经典特征。
4. 端口跳跃让 UDP 流量在 30000-32000 间轮换，打散 `per-(src_ip,dst_ip,dst_port)` 的 QoS 计数，**既能规避客户端限速，也让服务端 IP 在联通侧更难被流量画像识别 → 服务端 IP 存活更久**。

**结论**：**SPanel singbox/Clash 用户在联通上把 hy2 流量砸在单一 UDP 端口 → 触发联通 UDP QoS/封端口 → 表现为"hy2 节点在联通被墙"。NPanel 用户有跳跃 → 规避。** 这是 singbox 配置差异中**最可能对应"联通被墙"的一项**，且可解释三网差异。

**可立即验证**：手动给 SPanel singbox 订阅里的某个 hy2 outbound 加上：
```json
"hop_ports": "30000-32000",
"hop_interval": "30s"
```
联通用户测试是否恢复。若恢复 → 实锤。

> 注：v1 误称"NPanel 全量下发"也不准。NPanel 只在 DB `v2_hop_ports` 有值时下发；实测库中部分 hy2 节点该字段为 NULL。需在 DB 层确认生产 hy2 节点是否普遍写了 `v2_hop_ports=30000-32000`。

### 5.2 ⚠️ 次因候选：utls 指纹 `ios`（NPanel）vs `random`（SPanel）

- NPanel：所有 TLS 节点 singbox 硬编码 `utls.fingerprint=ios` → 每次连接都是稳定的 Apple 设备 ClientHello。
- SPanel：透传 DB `fp=`，实测 xhttp 组多为 `fp=random` → 每次连接指纹随机变化。
- `random` 是 sing-box **合法值**（非故障），但部分 DPI 启发式会标记"同一来源 TLS 指纹不一致"。对**TCP 类**（vision/xhttp）的联通 DPI 可能是**弱**辅助因素。
- 建议统一改 `ios`（稳定可预测），与 NPanel 对齐。**但这不是主因**——若仅指纹问题不会造成"频繁被墙"量级的差异。

### 5.3 不构成封锁因素（澄清）

| 项 | 为何与封锁无关 |
|---|---|
| `insecure`（已移除） | 仅客户端证书校验开关，**不改链路 TLS 指纹**。三网影响一致，无 ISP 差异。 |
| DNS 1.1.1.1 vs 8.8.8.8 | 解析路径差异，不影响节点链路特征。 |
| tun 字段版本 | 客户端兼容问题，三网同时发生，与 ISP 无关。 |
| selector 标签名 | 纯展示。 |

### 5.4 服务端侧（非 singbox，但相关）

- **vision 服务端 fallback 差异属实**：SPanel `vision.json`/`vision-hy2.json` 的 vless fallback 只有 `{dest:127.0.0.1:8088}` 一段；NPanel 多一段 `{alpn:h2,dest:127.0.0.1:8088}`。缺少 `alpn:h2` 显式回落 → 抗主动探针（active probing）能力弱于 NPanel。联通 DPI 主动探针较积极 → SPanel vision 服务端更易被识别 → IP 更易被标记。**这是服务端模板问题，建议补齐**（§6）。
- 若 **TCP 类（vision/xhttp）也在联通被封**，主因更可能在服务端（IP 信誉、流量画像、探针响应），而非 singbox 客户端配置。

### 5.5 结论

| 问题 | 判定 |
|---|---|
| singbox 配置差异是否导致联通被墙？ | **部分是**——SPanel singbox/Clash 不下发 hy2 端口跳跃，是最可能对应"联通 hy2 被墙"的 singbox 因素（§5.1）。 |
| 是否 singbox 单一原因导致整体频繁被墙？ | **不是**。"频繁被墙/服务端 IP 被封"通常以服务端流量画像+主动探针为主因；singbox 客户端配置（除 hy2 端口跳跃外）影响有限。 |
| 移动/电信稳定 | 与"联通对 UDP/hy2 单端口最激进 QoS"完全吻合，反证主因在 UDP 侧（§5.1）。 |

---

## 6. 建议改动清单（按对"联通被墙"的相关性排序）

### 🔴 P0 —— 直接针对联通 hy2 被墙
**SPanel singbox + Clash 补 hy2 端口跳跃**（与 NPanel 对齐）：
- `SPanel/.../SingBoxRenderer.php` hy2 分支补：
  ```php
  if (!empty($n->hy2Mport)) {
      $outbound['hop_ports'] = $n->hy2Mport;
      $outbound['hop_interval'] = $n->hy2HopInterval ?: '30s';
  }
  ```
  （`hy2Mport`/`hy2HopInterval` 在 `NodeParser.php:103` 已写死 `30000-32000`/`30s`，直接可用。）
- `SPanel/.../ClashRenderer.php` hy2 分支补 `hop-ports`（NPanel 已有，照抄）。
- DB 层：确保生产 hy2 节点的 `v2_hop_ports` 普遍写入 `30000-32000`（NPanel 侧部分节点为 NULL，需排查）。

### 🟠 P1 —— 服务端抗探针
- SPanel `resources/templates/xray/{vision,vision-hy2}.json` 补第二段 fallback `{alpn:h2,dest:127.0.0.1:8088}`，与 NPanel 对齐。

### 🟠 P1 —— 指纹一致性
- SPanel 数据源（注册/写 server 字段处）把 `fp=random` 改 `fp=ios`；或在 `NodeParser::resolveFingerprint` 增加白名单兜底（保留 chrome→ios）：
  ```php
  $valid = ['chrome','firefox','safari','ios','android','edge','qq','wechat','360','realtek'];
  if (empty($fp) || !in_array($fp, $valid, true)) return 'ios';
  ```

### 🟡 P2 —— sing-box 版本兼容（与封锁无关，但影响新客户端）
统一到 **1.12+ 规范**，至少保证两面板输出同一版本：
- tun 用 `address`（数组），删 `inet4_address`（SPanel）；
- 删 tun 内 `sniff`/`sniff_override_destination`（NPanel），改用 route `action:sniff`；
- DNS server 改 `type`+`server`/`domain_resolver` 新格式，删 legacy `address` 字符串；
- NPanel 删无效的 `store_fakeip`（无 fakeip DNS server）或补 fakeip server。

---

## 附录：复现命令（供独立验证）

```bash
# NPanel 真实 singbox（替换 <code>）
curl -sk 'https://test-npanel.freessr.bid/s/<code>?app=singbox' | python3 -m json.tool | less

# SPanel 真实 singbox（替换 <token>）
curl -sk 'https://test-spanel.freessr.bid/link/<token>?mu=singbox' | python3 -m json.tool | less

# 抓 hy2 outbound 的关键字段
curl -sk 'https://test-npanel.freessr.bid/s/<code>?app=singbox' \
 | python3 -c "import json,sys;d=json.load(sys.stdin);[print(o.get('type'),o.get('tls',{}).get('server_name'),'insecure=',o.get('tls',{}).get('insecure','(unset)'),'hop=',o.get('hop_ports'),'utls=',(o.get('tls',{}).get('utls') or {}).get('fingerprint')) for o in d['outbounds'] if o.get('type') in ('hysteria2','vless')]"

# 确认 insecure 已从所有订阅路径消失
grep -rn "insecure=1\|allowInsecure\|'insecure' => true\|skip-cert-verify: true\|skip-cert-verify=true" \
  /var/www/SPanel/app/ /var/www/NPanel/app/
# 期望：0 命中（仅余 SPanel SingBoxRenderer 的 'insecure' => false 显式校验 + Tools.php relay_insecure_mode）
```

## 附录：核心结论一句话

> 移除 `insecure` 已完成且**安全**（拼接式 SNI 前缀不破坏 `*.ssmail.win` 证书匹配，v1 的 P0 判断被实证推翻）。
> 关于**联通被墙**：singbox 配置差异里**唯一高度相关的是 SPanel singbox/Clash 不下发 hy2 端口跳跃**（联通对单端口高带宽 UDP QoS 最激进，移动/电信宽容 → 完美解释三网差异）；TCP 类（vision/xhttp）若也被封，主因更可能在**服务端**（vision fallback 抗探针弱、IP 画像），而非 singbox 客户端。
