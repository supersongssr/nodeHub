#!/bin/sh
# nodeMonitor.sh — 每分钟采样网卡流量, 计算 Mbps
# crontab: * * * * * /bin/sh ~/nodeMonitor.sh >> /tmp/nodeMonitor.log 2>&1

[ -f ~/.env ] && . ~/.env
[ -f ~/node.env ] && . ~/node.env

net_card="${net_card:-eth0}"
_env_file=~/node.env

# 读取网卡流量
set -- $(awk -v dev="${net_card}:" '$1 == dev {print $2, $10}' /proc/net/dev)
_rx=$1
_tx=$2

if [ -z "$_rx" ]; then
	echo "$(date '+%F %T') [ERROR] 网卡 ${net_card} 未找到"
	exit 1
fi

_now=$(date +%s)
_total=$(( _rx + _tx ))

# 计算速率 (Mbps)
_mbps=0
if [ "${monitor_last_time:-0}" -gt 0 ]; then
	_interval=$(( _now - monitor_last_time ))
	if [ "$_interval" -gt 59 ]; then
		_diff=$(( _total - monitor_last_total ))
		[ "$_diff" -lt 0 ] && _diff=0
		_mbps=$(( _diff * 8 / _interval / 1024 / 1024 ))
	fi
fi

# 更新峰值
_max="${monitor_max_mbps:-0}"
_is_new=0
if [ "$_mbps" -gt "$_max" ]; then
	_max="$_mbps"
	_is_new=1
fi

# 持久化到 node.env
for _kv in "monitor_last_total=${_total}" "monitor_last_time=${_now}" "monitor_max_mbps=${_max}"; do
	_k="${_kv%%=*}"
	sed -i "/^${_k}=/d" "$_env_file" 2>/dev/null || true
	echo "${_k}=\"${_kv#*=}\"" >> "$_env_file"
done

echo "$(date '+%F %T') [INFO] ${net_card}: ${_mbps} Mbps (峰值: ${_max} Mbps)$([ "$_is_new" -eq 1 ] && echo ' ★NEW')"
