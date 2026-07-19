nodeAgent.sh 脚本是否有自动更新 ssl 的功能? 

新增自动更新 ssl的功能.
方法是:
从 node.json 获取 root_domain
每天定时从 wget -N ${NODEHUB_URL}/ssl/{root_domain}.key .pem   下载到 /etc/ssl 中去
wget -N 会自动判断证书是否有更新.

1. 证书是: .pem .key ; 
2. 验证证书有更新,就重启 nginx 和 xray 
3. 调用频率为每天一次.