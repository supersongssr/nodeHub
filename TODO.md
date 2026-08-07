# TODO

## ✅ nodeAgent.sh 自动更新 SSL 证书 — 已完成

实现位置: `nodeAgent.sh :: SyncSSL`,每日 03:00 执行(nodeAgent 由 cron 每小时触发,SyncSSL 内部以 `date +%H` 限定仅 03 点生效)。

需求(均已实现):
- 从 `~/node.json` 读取 `root_domain`
- 每天定时 `wget -N ${NODEHUB_URL}/ssl/{root_domain}.key` 与 `.pem` 下载到 `/etc/ssl`(`wget -N` 仅在远端更新时真正拉取)
- `wget -N` 会自动判断证书是否有更新

实现要点(与当前代码一致):
1. 证书为 `.pem` + `.key`,落盘后 `chmod 600 key / 644 pem` 并做 `BEGIN CERTIFICATE` / `PRIVATE KEY` 格式校验。
2. 是否"真有更新"以**证书内容 sha256** 为准(非 mtime,避免远端仅重写时间戳而误触发)。
3. 检测到更新 → **reload nginx + restart xray**:
   - nginx: `nginx -t` 校验后 `nginx -s reload`(graceful,不断连);
   - xray: **不支持 SIGHUP 热重载**(收到 SIGHUP 会直接退出,reload 等同杀进程),改用 `systemctl restart` 并做 `is-active` 健康校验,失败由 `log error` 上报 Telegram(见 `RestartXrayWithHealthCheck`)。
4. 调用频率为每天一次(仅 03 点)。
