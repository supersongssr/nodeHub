# nodeHub

node proxy scripts hub — V2「瘦节点、胖面板」架构的代理节点脚本与配置仓库。
节点仅做环境初始化、API 生命周期与配置拉取；流量计算与下发由面板侧完成。

## 主要脚本

| 脚本 | 作用 |
| --- | --- |
| `proxyInstall.sh` | 节点安装：环境初始化 → 注册（回传 v2_name）→ 身份解析与持久化（`node_name` = `node_id`，作 ServerStatus `--alias` 展示名；`stat_user` = `md5(IP)`，作 `-u` 检索主键，外部项目只知 IP 即可在公开 stat 数据中定位本节点；stat 模式由 `STAT_GID`/`STAT_USER` 互斥二选一：设 `STAT_GID` 为动态节点（group 模式，`-g`=`STAT_GID`），设 `STAT_USER` 为固定节点（user 模式，无 `-g`），均未设则跳过 ServerStatus 安装（不装监控），两者同设视为配置冲突（告警并跳过安装）；读 `~/node.env` / `~/node.name` / `~/node.stat_user` / `~/node.json`，方案见 [`plans/node-name-identity.md`](plans/node-name-identity.md) 与 [`plans/stat-ip-identity.md`](plans/stat-ip-identity.md)）→ ServerStatus 客户端（设置了 `STAT_GID` 或 `STAT_USER` 时安装：`-u` = `stat_user`，`--alias` = `node_name`）→ nginx → xray → 解析 DNS → status 循环；含代理节点内核网络调优（conntrack / swap，`TuneKernelForProxy`）；安装成功后脚本自删除以避免安装方式泄漏（`KEEP_INSTALLER=1` 可保留调试）。 |
| `nodeAgent.sh` | 节点状态上报（cron 每小时）：采集网卡 rx/tx + uptime + vnstat 近 7 日流量上报面板；每日 03:00 同步 SSL 证书（`SyncSSL`）；按日期窗口调度一次性补丁（`RunPatches`）。 |
| `nodeMonitor.sh` | 每分钟流量采样（Mbps）+ 定时任务调度器（独立 crontab `* * * * *`）。 |
| `proxyDiagnose.sh` | 代理故障一键诊断（xray / nginx / 安装环境 / 网络 / 证书 / 出站连通性 / 本周期流量；含 NODE_PORT 大陆 tcping 被墙检测 —— 借 tcp.ping.pe 三网+云厂探测点与海外对照逐网判定（移动/电信/联通/云厂/海外 各自通/部分/断），检出封锁时随机开临时端口交叉验证【端口级 vs IP 级】被墙，`NODE_CN_TCPING=0` 可整体跳过、`NODE_CN_TCPING_XCHECK=0` 只关交叉验证；亦可在任意第三方服务器上 `NODE_TARGET_IP=<目标IP> NODE_PORT=<端口>` 远测别的节点是否被墙——探测由 ping.pe 代测与运行位置无关，远程目标自动跳过本机监听类检查与交叉验证，完整诊断用 `--host`），支持 `--target`、`--json`、`--host` 远程诊断；`--host` ssh 首次连接自动记录主机密钥、指纹变化即拒绝（老版 OpenSSH 可 `DIAG_SSH_STRICT=no` 回退）；`--target traffic` 用 vnstat 统计本周期 tx 出站流量（自上一个 `NODE_TRAFFIC_RESETDAY` 起，配 `NODE_TRAFFIC_LIMIT` 时含限额提醒）；默认只读，不改系统。 |
| `sync.sh` | 节点数据同步与首次初始化（GeoData + Xray 插件）；自动注册每晚 03:00 的 crontab（幂等，仅 root；非 root 排障运行时跳过注册，GeoData/Xray 更新照常）。 |
| `manage.sh` | 节点运维交互菜单（自检 / 状态 / 重启服务 / 同步 SSL / 日志 / 更新 / 重装）。 |
| `unlockCheck.sh` | IP 服务解锁检测（流媒体 / AI / 社交 / 搜索），结果上报 `/api/node/unlock_check`。 |
| `scripts/auto-renew-ssl.sh` | SSL 证书按需续期 / 部署（仅剩余 <30 天或本地缺失时同步，`--install-cron` 注册每晚 04:15 任务）。 |

## 目录

- `configs/` — 服务配置模板（如 `xray/xray.service`）
- `panels/` — 面板适配脚本（1Panel / 宝塔）
- `.patches/` — 一次性补丁脚本，由 `nodeAgent.sh::RunPatches` 经 `${NODEHUB_URL}/.patches/` 下发执行（详见 [`./.patches/README.md`](.patches/README.md)）
- `ssl/` · `geodat/` — 证书 / GeoData，供节点经 `${NODEHUB_URL}` 下载
- `plans/` · `reports/` — 设计方案与审计报告

节点经 `${NODEHUB_URL}` 拉取本仓库中的脚本与资源（脚本自身、`ssl/`、`panels/`、`geodat/`、`configs/`、`.patches/`）。
