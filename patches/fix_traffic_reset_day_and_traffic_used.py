#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
fix_traffic_reset_day_and_traffic_used — 一次性流量校准补丁
================================================================================
职责:
  读取节点 ~/.env 的 NODE_TRAFFIC_RESETDAY, 通过 vnstat 计算当前计费周期内
  (从 reset_day 到今天) 累计的 tx 流量, 经面板 /api/node/edit 接口上报:
    * traffic_used      ← vnstat 周期内 tx 总和    (GiB, 二进制 GB)
  注: traffic_reset_day 上报已注释 (reset_day 仅用于确定计费周期起点, 不再上报)

计费周期定义 (与面板 traffic_reset_day 语义一致):
  reset_day 为每月流量重置日. 以「今天」为锚点向前找最近的 reset_day:
    * 今天.day >= reset_day → 周期起点 = 本月 reset_day
    * 今天.day <  reset_day → 周期起点 = 上月 reset_day
  (reset_day 超出当月天数时, 钳到当月最后一天, 如 31 → 2 月取 28/29)

调用方:
  nodeAgent.sh RunPatches → PatchFixTrafficResetDayAndUsed
  本脚本由 nodeAgent.sh 从 ${NODEHUB_URL}/patches/ 用 wget -N 下载到 /tmp 后执行;
  亦可独立运行 (自带 Telegram 通知: 直接读 ~/.env 的 TG 配置, 不依赖 shell 转发).

参考:
  /var/www/SPanel/app/Controllers/V2ApiController.php :: edit()
    POST /api/node/edit
    JSON 信封: {"id":<id>,"params":{<字段>:<值>,...}}
    鉴权:     Authorization: Bearer <API_TOKEN>
                (edit 同时接受 X-API-Token 头或 token 参数, 这里用 Bearer)

面板侧单位约定 (须匹配):
  NodeApiService::EDITABLE_FIELDS['traffic_used'] 类型 = 'gb', 面板按
  round(value * 1024*1024*1024) 把 GiB 还原为字节. 故本脚本上报 GiB
  (二进制 GB = 字节 / 2^30). float64 下整数字节 < 9PB 时该往返无损.
  (同 admin traffic_used_calibrate 语义: 只写 traffic_used + derived 重算,
   不动 NIC 基线 traffic_raw_total, 下次 status 按真实增量继续累加.)

退出码:
  0   成功上报 traffic_used / vnstat 缺失已发 Telegram warn 并跳过
  1   致命错误 (必需配置缺失/非法, 或 HTTP 调用失败, 同时发 Telegram error)
================================================================================
"""

import calendar
import datetime
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

# 最小化/容器环境 locale 常为 C/POSIX, Python stdout 默认 latin-1 会致
# UnicodeEncodeError (中文/emoji 无法输出). 强制 stdout/stderr 用 UTF-8,
# 不依赖系统 LANG. (reconfigure 仅 Python 3.7+ 可用)
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

HOME = os.path.expanduser("~")
# ~/.env (全大写, 人工配置) + ~/node.env (全小写, 脚本生成); node.env 覆盖 .env 同名键
ENV_FILES = [os.path.join(HOME, ".env"), os.path.join(HOME, "node.env")]


# ============================================================
# 日志 — 纯文本无颜色 (输出由 nodeAgent.sh 捕获进 ~/nodeLogs)
# ============================================================
def log(level, msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H-%M-%S")
    print("%s [%s] %s" % (ts, level, msg), flush=True)


def die(msg, code=1):
    log("error", msg)
    notify_tg("error", msg)
    sys.exit(code)


# ============================================================
# Telegram 通知 — 直接读 ~/.env 配置, 不依赖 nodeAgent.sh (脚本可独立运行)
# 与 nodeAgent.sh NotifyTG 一致:
#   token 优先级 TELEGRAM_BOT_TOKEN > TG_BOT_TOKEN, chat 同理; 任一缺失则静默跳过
# ============================================================
def notify_tg(level, message):
    cfg = load_config()
    token = (cfg.get("TELEGRAM_BOT_TOKEN") or os.environ.get("TELEGRAM_BOT_TOKEN")
             or cfg.get("TG_BOT_TOKEN") or os.environ.get("TG_BOT_TOKEN"))
    chat = (cfg.get("TELEGRAM_CHAT_ID") or os.environ.get("TELEGRAM_CHAT_ID")
            or cfg.get("TG_CHAT_ID") or os.environ.get("TG_CHAT_ID"))
    if not token or not chat:
        return  # 未配置 Telegram, 静默跳过 (不影响主流程)

    emoji = {"error": "❌", "warn": "⚠️", "info": "ℹ️"}.get(level, "📝")
    text = "%s [NodeHub] fix_traffic_reset_day_and_traffic_used.py\n等级: %s\n节点: %s\n时间: %s\n%s" % (
        emoji, level,
        cfg.get("node_id") or cfg.get("NODE_ID") or os.environ.get("node_id") or "N/A",
        datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        message,
    )
    payload = json.dumps({"chat_id": chat, "text": text}).encode("utf-8")
    req = urllib.request.Request(
        "https://api.telegram.org/bot%s/sendMessage" % token,
        data=payload, method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=15).read()
    except Exception:
        pass  # best-effort: Telegram 故障不阻断主流程


# ============================================================
# .env / node.env 解析 — 仅取 KEY=VALUE, 去引号, 忽略注释/空行
# ============================================================
def parse_env_file(path):
    out = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[len("export "):].lstrip()
                if "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                if not key:
                    continue
                val = val.strip()
                if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                    val = val[1:-1]
                out[key] = val
    except (IOError, OSError) as e:
        log("warn", "读取 %s 失败: %s" % (path, e))
    return out


def load_config():
    """合并 ~/.env + ~/node.env; 进程 os.environ 再覆盖 (便于手动指定测试)."""
    cfg = {}
    for p in ENV_FILES:
        if os.path.isfile(p):
            cfg.update(parse_env_file(p))
    for k in list(cfg.keys()):
        if k in os.environ:
            cfg[k] = os.environ[k]
    return cfg


# ============================================================
# 计费周期起点 — 以今天为锚点向前找最近的 reset_day
# ============================================================
def cycle_start_date(reset_day, today):
    def reset_of(year, month):
        last_day = calendar.monthrange(year, month)[1]
        return datetime.date(year, month, min(reset_day, last_day))

    cand = reset_of(today.year, today.month)
    if cand <= today:
        return cand
    y, m = (today.year, today.month - 1) if today.month > 1 else (today.year - 1, 12)
    return reset_of(y, m)


# ============================================================
# vnstat 当前周期 tx 流量 (字节) — vnstat --json d, 汇总 day[].tx
# ============================================================
def compute_traffic_used_tx(net_card, since):
    """返回 (tx_bytes, used_interface). vnstat 缺失/解析失败 → (None, None)."""
    try:
        proc = subprocess.run(
            ["vnstat", "--json", "d"],
            capture_output=True, text=True, timeout=20,
        )
    except FileNotFoundError:
        log("warn", "vnstat 未安装, 无法计算 traffic_used")
        return None, None
    except subprocess.TimeoutExpired:
        log("warn", "vnstat --json d 超时, 跳过 traffic_used 计算")
        return None, None

    if proc.returncode != 0 or not proc.stdout.strip():
        log("warn", "vnstat --json d 返回非零或空 (rc=%s), 跳过 traffic_used" % proc.returncode)
        return None, None

    try:
        data = json.loads(proc.stdout)
    except ValueError as e:
        log("warn", "vnstat JSON 解析失败: %s" % e)
        return None, None

    interfaces = data.get("interfaces") or []
    if not interfaces:
        log("warn", "vnstat 无任何网卡数据, 跳过 traffic_used")
        return None, None

    # 选网卡: net_card 匹配优先, 否则取首张
    iface = None
    if net_card:
        for it in interfaces:
            if it.get("name") == net_card:
                iface = it
                break
    if iface is None:
        iface = interfaces[0]
        if net_card:
            log("warn", "vnstat 未找到网卡 %s, 回退使用 %s" % (net_card, iface.get("name")))

    total = 0
    matched_days = 0
    for d in iface.get("traffic", {}).get("day", []) or []:
        date = d.get("date") or {}
        try:
            dd = datetime.date(int(date["year"]), int(date["month"]), int(date["day"]))
        except (KeyError, ValueError, TypeError):
            continue
        if dd >= since:
            total += int(d.get("tx", 0) or 0)
            matched_days += 1

    log("debug", "vnstat 周期 tx 汇总: 网卡=%s 周期内天数=%d tx=%d 字节 (%.4f GiB)"
        % (iface.get("name"), matched_days, total, total / 1073741824.0))
    return total, iface.get("name")


# ============================================================
# POST /api/node/edit — JSON 信封, Bearer 鉴权
# ============================================================
def edit_node(api_url, api_token, node_id, params):
    url = api_url.rstrip("/") + "/api/node/edit"
    body = json.dumps({"id": int(node_id), "params": params}).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + api_token,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.getcode(), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body_txt = ""
        try:
            body_txt = e.read().decode("utf-8", "replace")
        except Exception:
            pass
        return e.code, body_txt
    except urllib.error.URLError as e:
        raise RuntimeError("edit 请求失败: %s" % e.reason)


# ============================================================
# 主流程
# ============================================================
def main():
    cfg = load_config()

    api_token = cfg.get("API_TOKEN") or os.environ.get("API_TOKEN")
    api_url = cfg.get("API_URL") or os.environ.get("API_URL")
    node_id = cfg.get("node_id") or cfg.get("NODE_ID") or os.environ.get("node_id")
    reset_day_raw = cfg.get("NODE_TRAFFIC_RESETDAY") or os.environ.get("NODE_TRAFFIC_RESETDAY")
    net_card = cfg.get("net_card") or os.environ.get("net_card") or "eth0"

    missing = []
    if not api_token:
        missing.append("API_TOKEN")
    if not api_url:
        missing.append("API_URL")
    if not node_id:
        missing.append("node_id")
    if not reset_day_raw:
        missing.append("NODE_TRAFFIC_RESETDAY")
    if missing:
        die("必需配置缺失: %s (检查 ~/.env / ~/node.env)" % ", ".join(missing))

    # reset_day 合法性
    try:
        reset_day = int(reset_day_raw)
    except ValueError:
        die("NODE_TRAFFIC_RESETDAY 非整数: %r" % reset_day_raw)
    if reset_day < 1 or reset_day > 31:
        die("NODE_TRAFFIC_RESETDAY 越界 (需 1-31): %d" % reset_day)

    # API_URL 标准化 (无 scheme 补 https://)
    if not api_url.startswith("http://") and not api_url.startswith("https://"):
        api_url = "https://" + api_url

    today = datetime.date.today()
    since = cycle_start_date(reset_day, today)
    log("info", "节点 %s — reset_day=%d 周期=%s ~ %s(今天) 网卡=%s"
        % (node_id, reset_day, since.isoformat(), today.isoformat(), net_card))

    # 计算 traffic_used (vnstat 缺失时为 None); 内部以字节计
    traffic_used_bytes, used_iface = compute_traffic_used_tx(net_card, since)

    # vnstat 缺失/无数据 → 直接发 Telegram warn, 并跳过本次上报 (脚本独立处理, 不靠 shell)
    if traffic_used_bytes is None:
        log("warn", "vnstat 缺失/无数据, 无法计算 traffic_used, 跳过本次上报")
        notify_tg("warn", "vnstat 缺失/无数据, 无法计算 traffic_used, 已跳过 traffic_used 上报")
        return 0

    # 组装 params: 仅上报 traffic_used (traffic_reset_day 上报已注释)
    # 面板 EDITABLE_FIELDS['traffic_used'] 类型 = 'gb' (round(gib*1024³)→字节),
    # 故上报 GiB (字节/2^30). float64 下整数字节 <9PB 往返无损.
    params = {}
    # params["traffic_reset_day"] = reset_day   # 已注释: 不再上报 traffic_reset_day
    params["traffic_used"] = traffic_used_bytes / 1073741824.0

    log("info", "上报 edit — params=%s" % json.dumps(params, ensure_ascii=False))

    code, body = edit_node(api_url, api_token, node_id, params)
    log("info", "edit 响应 HTTP %s — %s" % (code, body[:500]))

    if code != 200:
        die("edit 上报失败 HTTP %s" % code)

    # 解析响应, 明确提示 traffic_used 是否被面板接受
    try:
        resp = json.loads(body)
    except ValueError:
        resp = {}

    status = resp.get("status")
    updated = resp.get("updated") or []
    ignored = resp.get("ignored") or []

    if status == "success":
        log("info", "✅ edit 成功 (updated=%s)" % updated)
    else:
        log("warn", "面板返回非 success: status=%s message=%s" % (status, resp.get("message")))

    # traffic_used 是否被面板接受 (理论上报 GiB 后应进 updated)
    tu_ignored = any(
        (isinstance(it, dict) and it.get("field") == "traffic_used") or it == "traffic_used"
        for it in ignored
    )
    if "traffic_used" in params:
        if "traffic_used" in updated:
            log("info", "✅ traffic_used 已更新 (GiB→字节校准)")
        elif tu_ignored:
            log("warn", "⚠ traffic_used 被面板忽略 — 请确认面板 EDITABLE_FIELDS 已含 "
                       "'traffic_used' => ['type'=>'gb', ...]")
        else:
            log("warn", "⚠ traffic_used 既未在 updated 也未在 ignored, 请核对面板响应")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        die("中断", 130)
    except RuntimeError as e:
        die(str(e))
