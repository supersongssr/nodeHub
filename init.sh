#!/bin/sh
#
#
set -e

NODEHUB_PWD=$(cd "$(dirname "$0")" && pwd)

# 检查是否在脚本所在目录,不是的话, 就退出运行
if [ "$(pwd)" != "$NODEHUB_PWD" ]; then
    echo "请在脚本所在目录运行此脚本"
    echo 0011 $(NODEHUB_PWD)
    exit 1
fi



DownloadXray(){
    cd $NODEHUB_PWD/xray

    wget -N https://github.com/supersongssr/xray-plugin-srp/releases/download/v0.0.9/xray-plugin-srp-v0.0.9

    wget -N https://github.com/supersongssr/xray-plugin-ssp/releases/download/v0.0.9/xray-plugin-ssp-v0.0.9

}
# 下载 xray/xray-plugin-ssp-v1.8.4-ip-flow.zip 到 xray 目录


DownloadSsl(){
    echo download ssl to ssl path
    bash $NODEHUB_PWD/ssl/ssl-auto-check.sh
}

DownloadGeo(){
    echo download geosite and geoip
    bash $NODEHUB_PWD/geodat/autoupdate.sh
}

AddCrontab(){
    echo add auto run crontab

    echo add ssl auto download
    sed -i -e "/ssl-auto-check.sh/d" /etc/crontab
	echo "17 5 * * root /bin/bash $NODEHUB_PWD/ssl/ssl-auto-check.sh" >> /etc/crontab

	echo add geosite geoip auto download
	sed -i -e "#geodat/autoupdate.sh#d" /etc/crontab
	echo "17 9 * * root /bin/bash $NODEHUB_PWD/geodat/autoupdate.sh" >> /etc/crontab
}



main(){
    DownloadXray
    DownloadSsl
    DownloadGeo
    AddCrontab

}

main
