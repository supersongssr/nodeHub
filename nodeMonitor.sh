#!/bin/sh
# ============================================================
# nodeMonitor.sh — 每分钟流量采样 + 定时任务调度器
#
# crontab: * * * * * /bin/sh ~/nodeMonitor.sh >> /tmp/nodeMonitor.log 2>&1
#
# 两部分职责:
#   A. 每分钟: 采样网卡流量 → 计算 Mbps → 更新 ~/node.env  (同步, <10ms, 永不阻塞)
#   B. 调度器: 按相位周期调用各定时任务 (后台 + flock 防重叠, 不阻塞下一分钟采样)
#      - probe (probeTask.sh): 每 15 分钟, 仅当 ~/probeTask.sh 存在 + MONITOR_* 配齐
#      ※ 以后新增的定时任务都在 RunScheduledTasks 里加分支, 不再写新 crontab
# ============================================================

[ -f ~/.env ] && . ~/.env
[ -f ~/node.env ] && . ~/node.env

net_card="${net_card:-eth0}"
_env_file=~/node.env

# ============================================================
# Part A: 每分钟流量采样
# ============================================================
SampleTraffic() {
    set -- $(awk -v dev="${net_card}:" '$1 == dev {print $2, $10}' /proc/net/dev)
    _rx=$1
    _tx=$2

    if [ -z "$_rx" ]; then
        echo "$(date '+%F %T') [ERROR] 网卡 ${net_card} 未找到"
        return 0
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
}

# ============================================================
# Part B: 定时任务调度器
# 所有周期性任务在此注册, 不再新增 crontab 行
# ============================================================
RunScheduledTasks() {
    # 当前分钟 (0-59), 去前导 0 避免 dash 八进制
    _min=$(date +%M | sed 's/^0//'); [ -z "$_min" ] && _min=0

    # ---- probe: 每 15 分钟, 相位 (min % 15) == probe_collect_phase 时触发 ----
    # 门控: probeTask.sh 存在 + MONITOR_* 配齐 (缺任一则该节点无 probe)
    if [ -f ~/probeTask.sh ] \
       && [ -n "${MONITOR_INGEST_URL:-}" ] \
       && [ -n "${MONITOR_INGEST_TOKEN:-}" ]; then
        if [ $((_min % 15)) = "${probe_collect_phase:-}" ]; then
            # 后台 + flock 防重叠; 输出重定向到 ~/probeLogs
            ( flock -n 9 || exit 0
              sh ~/probeTask.sh
            ) 9>/tmp/probeTask.lock </dev/null >>~/probeLogs 2>&1 &
        fi
    fi

    # ---- ※ 未来新增定时任务在此追加 if 分支 ----
}

# ============================================================
# 主流程
# ============================================================
SampleTraffic
RunScheduledTasks
exit 0
