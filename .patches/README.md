# .patches/

一次性补丁脚本目录. 由 `nodeAgent.sh` 的 `RunPatches` 调度执行.

## 约定

- **运行一次**: 每个 Patch 在节点上首次执行后写标记文件 (`~/nodeAgent.<name>.patch.done`),
  再次执行直接跳过, 保证全节点只跑一次.
- **按需下发**: 节点本地不持有仓库, 补丁脚本由 `nodeAgent.sh` 从
  `${NODEHUB_URL}/.patches/<脚本名>` 下载到临时文件后用对应解释器执行
  (与现有 patch 下载 `proxyInstall.sh` 的模式一致).
- **调度入口**: 新增补丁只需在 `nodeAgent.sh :: RunPatches` 追加一行日期触发,
  无需改动 `Main`. 过时补丁直接注释整行.
- **命名**: 脚本名用下划线分词 (不含空格), 便于 URL 直引与 shell 引用.

## 现存补丁

| 脚本 | 触发窗口 | 作用 |
| --- | --- | --- |
| `fix_traffic_reset_day_and_traffic_used.py` | 2026-08-08 前, 一次 | 读 `~/.env` 的 `NODE_TRAFFIC_RESETDAY`, 用 vnstat 汇总当前周期 tx 流量, 经 `POST /api/node/edit` 上报 `traffic_reset_day` + `traffic_used` (GiB) |
