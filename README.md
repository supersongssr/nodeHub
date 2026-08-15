# nodeHub

node proxy scripts hub — V2「瘦节点、胖面板」架构的代理节点脚本与配置仓库。
节点仅做环境初始化、API 生命周期与配置拉取；流量计算与下发由面板侧完成。

## 主要脚本

| 脚本 | 作用 |
| --- | --- |
| `proxyInstall.sh` | 节点安装：环境初始化 → 注册 → nginx → xray → 解析 DNS → status 循环；含代理节点内核网络调优（conntrack / swap，`TuneKernelForProxy`）。 |
| `nodeAgent.sh` | 节点状态上报（cron 每小时）：采集网卡 rx/tx + uptime + vnstat 近 7 日流量上报面板；每日 03:00 同步 SSL 证书（`SyncSSL`）；按日期窗口调度一次性补丁（`RunPatches`）。 |
| `nodeMonitor.sh` | 每分钟流量采样（Mbps）+ 定时任务调度器（独立 crontab `* * * * *`）。 |
| `proxyDiagnose.sh` | 代理故障一键诊断（xray / nginx / 安装环境 / 网络 / 证书 / 出站连通性），支持 `--target`、`--json`、`--host` 远程诊断；默认只读，不改系统。 |
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
