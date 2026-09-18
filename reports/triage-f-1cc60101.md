# 分诊复核备注 — f-1cc60101 [high] 共享推送 token 硬编码 / /ingest/tcping 可伪造

- **送审 HEAD** `e6f4828`: 裁决 still-present (token 原样在 nodeAgent.sh:681, 旧垫片回退完整可达)
- **维护方处置** (2026-09-18 复核): **owner 接受风险 / 判定非 bug, 属灰度迁移期的允许设计**
  - 理由 1: 现实攻击者极少, 威胁模型不成立 (owner 评估)
  - 理由 2: 新 Bearer 密钥 (MONITOR_URL/MONITOR_KEY) 已逐节点配置完成, 旧路径实际无流量
- **仓库现状** (HEAD `33ab409`, 提交 `9f7688c`): 旧 /ingest/tcping 共享 token 垫片已删除,
  未配两键时跳过推送不回退, 监控侧 token 已轮换作废, token 值全仓库零残留 → **fixed**
- **最终裁决**: fixed (以灰度收尾提交 `9f7688c` 为准; owner 备注留档如上)
