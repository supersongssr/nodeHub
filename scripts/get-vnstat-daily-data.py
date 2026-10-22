#!/usr/bin/env python3
"""
get-vnstat-daily-data.py

通过 vnstat 的全部历史流量, 结合 /root/.env 中的 NODE_COST(月价格),
计算: 平均每 $ 每天消耗的流量 (GiB/$ /天)

公式:
    总流量(rx + tx, GiB) / 统计天数 = 平均每日流量
    平均每日流量 / NODE_COST = 平均每 $ 每天消耗的流量
"""

import calendar
import json
import os
import re
import subprocess
import sys

ENV_FILE = "/root/.env"
GIB = 1024 ** 3  # 1 GiB


def load_node_cost(path=ENV_FILE):
    """从 /root/.env 读取 NODE_COST(月价格)

    .env 加载原理是后赋值覆盖先赋值,
    若存在多行 NODE_COST, 以最后一行为准。
    """
    if not os.path.isfile(path):
        sys.exit(f"错误: 找不到 {path}")
    cost = None
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^\s*(?:export\s+)?NODE_COST\s*=\s*['\"]?([0-9.]+)", line)
            if m:
                cost = float(m.group(1))
    if cost is None:
        sys.exit(f"错误: {path} 中未找到有效的 NODE_COST=")
    return cost


def get_vnstat_months():
    """调用 vnstat --json m 获取全部历史月度流量"""
    try:
        out = subprocess.run(
            ["vnstat", "--json", "m"],
            capture_output=True, text=True, check=True, timeout=30,
        ).stdout
    except FileNotFoundError:
        sys.exit("错误: 未安装 vnstat 或不在 PATH 中")
    except subprocess.CalledProcessError as e:
        sys.exit(f"错误: vnstat 执行失败: {e.stderr.strip()}")
    return json.loads(out)


def month_tracked_days(entry, created, updated):
    """计算某个月份实际被统计的天数(处理首月/当前月的不完整月份)"""
    y, m = entry["date"]["year"], entry["date"]["month"]
    days_in_month = calendar.monthrange(y, m)[1]

    first_day, last_day = 1, days_in_month
    if created and (created["year"], created["month"]) == (y, m):
        first_day = created["day"]
    if updated and (updated["year"], updated["month"]) == (y, m):
        last_day = updated["day"]

    return max(0, last_day - first_day + 1)


def main():
    node_cost = load_node_cost()
    data = get_vnstat_months()

    total_bytes = 0
    total_days = 0
    for iface in data.get("interfaces", []):
        traffic = iface.get("traffic", {})
        created = iface.get("created", {}).get("date")
        updated = iface.get("updated", {}).get("date")

        for entry in traffic.get("month", []):
            total_bytes += entry["rx"] + entry["tx"]
            total_days += month_tracked_days(entry, created, updated)

    if total_days == 0:
        sys.exit("错误: vnstat 中没有任何历史统计数据")

    total_gib = total_bytes / GIB
    rx_gib = sum(e["rx"] for i in data["interfaces"]
                 for e in i["traffic"]["month"]) / GIB
    tx_gib = sum(e["tx"] for i in data["interfaces"]
                 for e in i["traffic"]["month"]) / GIB

    avg_daily_gib = total_gib / total_days
    gib_per_dollar_per_day = avg_daily_gib / node_cost

    print(f"接口          : {', '.join(i['name'] for i in data['interfaces'])}")
    print(f"总流量        : {total_gib:.2f} GiB (rx: {rx_gib:.2f} GiB + tx: {tx_gib:.2f} GiB)")
    print(f"统计天数      : {total_days} 天")
    print(f"平均每日流量  : {avg_daily_gib:.2f} GiB/天")
    print(f"NODE_COST     : ${node_cost:.2f}/月")
    print(f"———————————————")
    print(f"平均每$每天流量: {gib_per_dollar_per_day:.4f} GiB/$/天")


if __name__ == "__main__":
    main()
