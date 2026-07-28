#!/bin/sh
# ============================================================
# nodeMonitor.sh — 每分钟流量采样 + 定时任务调度器
#
# crontab: * * * * * /bin/sh ~/nodeMonitor.sh >> /tmp/nodeMonitor.log 2>&1
#
# 两部分职责:
#   A. 每分钟: 采样网卡流量 → 计算 Mbps → 更新 ~/nodeMonitor.json  (同步, 永不阻塞)
#   B. 调度器: 按相位周期调用各定时任务 (后台 + flock 防重叠, 不阻塞下一分钟采样)
#      ※ 以后新增的定时任务都在 RunScheduledTasks 里加分支, 不再写新 crontab
#
# 数据持久化: ~/nodeMonitor.json (JSON, 原子写入)
#   {"net_card":"eth0","last_total":N,"last_time":N,"max_mbps":N,"mbps":N,"ts":"YYYY-MM-DD HH:MM:SS"}
# nodeAgent.sh / manage.sh 通过此文件读取流量统计, 不再依赖 ~/node.env 的 monitor_* 字段
# ============================================================

[ -f ~/.env ] && . ~/.env
[ -f ~/node.env ] && . ~/node.env

net_card="${net_card:-eth0}"
_json_file=~/nodeMonitor.json
_env_file=~/node.env   # 仅用于一次性清理旧 monitor_* 残留

# ============================================================
# 从 nodeMonitor.json 读取上一次采样状态 (整数解析, 无需 jq)
# 失败/缺失时全部回退为 0, 永不影响采样主流程
# ============================================================
LoadMonitorState() {
    monitor_last_total=0
    monitor_last_time=0
    monitor_max_mbps=0

    [ -f "$_json_file" ] || return 0

    monitor_last_total=$(sed -n 's/.*"last_total":\([0-9][0-9]*\).*/\1/p' "$_json_file" | head -1)
    monitor_last_time=$(sed -n 's/.*"last_time":\([0-9][0-9]*\).*/\1/p' "$_json_file" | head -1)
    monitor_max_mbps=$(sed -n 's/.*"max_mbps":\([0-9][0-9]*\).*/\1/p' "$_json_file" | head -1)

    [ -z "$monitor_last_total" ] && monitor_last_total=0
    [ -z "$monitor_last_time" ]  && monitor_last_time=0
    [ -z "$monitor_max_mbps" ]   && monitor_max_mbps=0
}

# ============================================================
# 一次性迁移: 旧版节点把 monitor_* 写在 ~/node.env, 升级后首次运行时
# 用 node.env 里的 max_mbps 种子 nodeMonitor.json; 之后 monitor_* 只存在于 nodeMonitor.json
#
# ※ 安全约束: 这里只“读取/种子”, 绝不删除 node.env。
#   删除动作推迟到 SampleTraffic 成功写出 nodeMonitor.json 之后 (见主流程),
#   否则一旦写失败 (网卡缺失/磁盘满/权限), 峰值会随 node.env 被清空而永久丢失。
# ============================================================
MigrateFromNodeEnv() {
    _migrated=0
    # nodeMonitor.json 已存在 → 不需要迁移
    [ -f "$_json_file" ] && return 0
    # node.env 不存在 → 无旧数据可迁移
    [ -f "$_env_file" ] || return 0

    # 旧格式: monitor_max_mbps="250"
    _old_max=$(sed -n 's/^monitor_max_mbps="\([0-9][0-9]*\)".*/\1/p' "$_env_file" | head -1)
    if [ -n "$_old_max" ] && [ "$_old_max" -gt 0 ] 2>/dev/null; then
        monitor_max_mbps=$_old_max
        _migrated=1
        echo "$(date '+%F %T') [INFO] 迁移: 从 ~/node.env 继承 monitor_max_mbps=${_old_max} (新 JSON 写入成功后再清旧字段)"
    fi
}

# ============================================================
# Part A: 每分钟流量采样
# ============================================================
SampleTraffic() {
    set -- $(awk -v dev="${net_card}:" '$1 == dev {print $2, $10}' /proc/net/dev)
    _rx=$1
    _tx=$2

    if [ -z "$_rx" ]; then
        echo "$(date '+%F %T') [ERROR] 网卡 ${net_card} 未找到 — 跳过本次写入"
        return 1
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

    _ts=$(date '+%F %T')

    # 持久化到 nodeMonitor.json (原子写入: 先写临时文件再 mv, 避免读到半截 JSON)
    # 写入必须成功才返回 0 — 迁移收尾依赖此返回码决定是否清除 node.env 旧字段
    _tmp="${_json_file}.$$"
    if ! printf '{"net_card":"%s","last_total":%s,"last_time":%s,"max_mbps":%s,"mbps":%s,"ts":"%s"}\n' \
            "$net_card" "$_total" "$_now" "$_max" "$_mbps" "$_ts" > "$_tmp" 2>/dev/null; then
        rm -f "$_tmp" 2>/dev/null || true
        echo "${_ts} [ERROR] 临时文件写入失败: $_tmp"
        return 1
    fi
    if ! { mv -f "$_tmp" "$_json_file" 2>/dev/null || cat "$_tmp" > "$_json_file" 2>/dev/null; }; then
        rm -f "$_tmp" 2>/dev/null || true
        echo "${_ts} [ERROR] nodeMonitor.json 写入失败: $_json_file"
        return 1
    fi
    rm -f "$_tmp" 2>/dev/null || true

    echo "${_ts} [INFO] ${net_card}: ${_mbps} Mbps (峰值: ${_max} Mbps)$([ "$_is_new" -eq 1 ] && echo ' ★NEW')"
    return 0
}

# ============================================================
# Part B: 定时任务调度器
# 所有周期性任务在此注册, 不再新增 crontab 行
# ============================================================
RunScheduledTasks() {
    # 当前分钟 (0-59), 去前导 0 避免 dash 八进制
    _min=$(date +%M | sed 's/^0//'); [ -z "$_min" ] && _min=0

    # ---- ※ 未来新增定时任务在此追加 if 分支 ----
}

# ============================================================
# 主流程
# ============================================================
LoadMonitorState
MigrateFromNodeEnv
# 写入 nodeMonitor.json — 失败时 (网卡缺失/磁盘满/权限) 不清除 node.env, 下分钟重试
if SampleTraffic; then
    # 迁移收尾: 新 JSON 已含迁移的峰值 → 现在才安全清除 node.env 中旧 monitor_* 字段
    if [ "${_migrated:-0}" = "1" ]; then
        sed -i '/^monitor_.*=/d' "$_env_file" 2>/dev/null || true
        echo "$(date '+%F %T') [INFO] 迁移完成: 已清除 ~/node.env 中的旧 monitor_* 字段"
    fi
fi
RunScheduledTasks
exit 0
