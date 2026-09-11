#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
一次性补丁 (2026-09-11): tiktok 解锁出站密码更换

背景:
  tiktok 解锁中转站 (unlocktiktok.freessr.bid) 更换了 shadowsocks 密码,
  节点 /usr/local/etc/xray/config.json 的 outbounds 中 address 为该域名的
  出站仍持旧密码 fbiopenthedoor, 导致解锁链路失效。
  本补丁将该出站的 password 替换为新密码 aiopenthedoor 并重启 xray 生效。

目标节点:
  * /usr/local/etc/xray/config.json 的 outbounds 中存在
    address == "unlocktiktok.freessr.bid" 的出站 (shadowsocks settings.servers,
    兼容 vnext/users 嵌套); 无该出站的节点静默跳过并落标记。

动作:
  1. 备份并修改 /usr/local/etc/xray/config.json:
       outbounds[].settings.servers[] (及 vnext[].users[]) 中
       address == unlocktiktok.freessr.bid 条目的
       "password": "fbiopenthedoor"  →  "password": "aiopenthedoor"
     (幂等: 已是新密码 / 无该出站 均安全重入)
  2. xray run -test 校验配置 (失败自动回滚备份)
  3. systemctl restart xray 并验证 is-active (失败回滚备份并再次重启)
  4. 成功后写标记文件 ~/nodeAgent.tiktok-outbound-password.patch.done (仅一次)
  5. 成功后发 Telegram 通知 (TG_BOT_TOKEN / TG_CHAT_ID, 未配置则跳过)

约束:
  * 仅在 2026-09-11 当天 (本地时区) 允许执行, 其余日期直接退出
  * 标记文件存在则不再执行 (一次性; nodeAgent.sh 侧另有同名标记双重防护)

用法: python3 fix_tiktok_outbound_password.py
退出码: 0=完成或无需处理, 1=执行失败 (nodeAgent 下个周期可重试)
仅依赖 python3 标准库 (原生 json 解析, 不依赖 jq)。
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime

HOME = os.path.expanduser("~")
ENV_FILE = os.path.join(HOME, ".env")
NODE_JSON = os.path.join(HOME, "node.json")
XRAY_CONFIG = "/usr/local/etc/xray/config.json"
XRAY_BIN = "/usr/local/bin/xray"
MARKER = os.path.join(HOME, "nodeAgent.tiktok-outbound-password.patch.done")

ALLOW_DATE = "2026-09-11"                 # 仅当天可执行
TARGET_ADDRESS = "unlocktiktok.freessr.bid"  # 出站 address 匹配值
OLD_PASSWORD = "fbiopenthedoor"           # 旧密码
NEW_PASSWORD = "aiopenthedoor"            # 新密码
BACKUP_SUFFIX = ".bak.tiktok-outbound-pwd"  # 备份后缀 (同名覆盖, 只留最近一份)


def log(level, msg):
    print("[tiktok-outbound-pwd][%s] %s" % (level, msg), flush=True)


# ---------- ~/.env 解析 (取最后出现的值, 兼容引号 / export 前缀) ----------
def parse_env_file(path):
    values = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                if key.startswith("export "):
                    key = key[len("export "):].strip()
                val = val.strip().strip('"').strip("'")
                values[key] = val
    except OSError:
        pass
    return values


# ---------- Telegram 通知 (可选) ----------
def notify_tg(text):
    env = parse_env_file(ENV_FILE)
    token = env.get("TG_BOT_TOKEN") or env.get("TELEGRAM_BOT_TOKEN")
    chat = env.get("TG_CHAT_ID") or env.get("TELEGRAM_CHAT_ID")
    if not token or not chat:
        return
    try:
        data = urllib.parse.urlencode({"chat_id": chat, "text": text}).encode()
        urllib.request.urlopen(
            urllib.request.Request(
                "https://api.telegram.org/bot%s/sendMessage" % token, data=data
            ),
            timeout=15,
        )
    except Exception as exc:  # 通知失败不影响补丁结果
        log("warn", "Telegram 通知失败: %s" % exc)


# ---------- 备份 / 回滚 ----------
def backup_file(path):
    bak = path + BACKUP_SUFFIX
    shutil.copy2(path, bak)
    return bak


def restore_file(bak):
    if bak and os.path.exists(bak):
        shutil.copy2(bak, bak[: -len(BACKUP_SUFFIX)])


# ---------- 遍历出站内的 server 条目 (shadowsocks servers / vmess·vless vnext) ----------
def iter_server_entries(outbound):
    settings = outbound.get("settings")
    if not isinstance(settings, dict):
        return
    for key in ("servers", "vnext"):
        entries = settings.get(key)
        if isinstance(entries, list):
            for entry in entries:
                if isinstance(entry, dict):
                    yield entry


def replace_password_in_entry(entry):
    """在单个 server 条目 (含 users 嵌套) 内替换旧密码; 返回替换次数"""
    count = 0
    if entry.get("password") == OLD_PASSWORD:
        entry["password"] = NEW_PASSWORD
        count += 1
    users = entry.get("users")
    if isinstance(users, list):
        for user in users:
            if isinstance(user, dict) and user.get("password") == OLD_PASSWORD:
                user["password"] = NEW_PASSWORD
                count += 1
    return count


# ---------- 步骤 1: 修改出站密码 ----------
def patch_xray_config():
    """返回 (是否修改, 命中出站 tag 列表, 是否存在目标出站)"""
    with open(XRAY_CONFIG, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    patched_tags = []
    has_target = False
    for outbound in cfg.get("outbounds") or []:
        if not isinstance(outbound, dict):
            continue
        for entry in iter_server_entries(outbound):
            if entry.get("address") != TARGET_ADDRESS:
                continue
            has_target = True
            if replace_password_in_entry(entry) > 0:
                patched_tags.append(str(outbound.get("tag", "<无tag>")))

    if patched_tags:
        backup_file(XRAY_CONFIG)
        with open(XRAY_CONFIG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
            f.write("\n")
    return bool(patched_tags), patched_tags, has_target


# ---------- 步骤 2: xray 配置校验 ----------
def xray_config_ok():
    bin_path = XRAY_BIN if os.path.exists(XRAY_BIN) else "xray"
    try:
        r = subprocess.run(
            [bin_path, "run", "-test", "-config", XRAY_CONFIG],
            capture_output=True, text=True, timeout=60,
        )
    except Exception as exc:
        log("warn", "xray -test 执行异常: %s" % exc)
        return False
    if r.returncode != 0:
        detail = (r.stderr or r.stdout or "").strip()[:500]
        log("error", "xray -test 校验失败: %s" % (detail or "退出码 %d (无输出)" % r.returncode))
        return False
    return True


# ---------- 步骤 3: 重启 xray 并验证 ----------
def restart_xray():
    for attempt in range(1, 6):
        try:
            subprocess.run(
                ["systemctl", "restart", "xray"],
                capture_output=True, timeout=90,
            )
        except Exception as exc:
            log("warn", "systemctl restart xray 异常: %s" % exc)
        for _ in range(6):
            try:
                r = subprocess.run(
                    ["systemctl", "is-active", "xray"],
                    capture_output=True, text=True, timeout=15,
                )
                if r.stdout.strip() == "active":
                    return True
            except Exception:
                pass
            time.sleep(2)
        log("warn", "restart 第 %d 次后 xray 仍非 active" % attempt)
    return False


def write_marker(reason):
    with open(MARKER, "w", encoding="utf-8") as f:
        f.write("%s, %s\n" % (reason, datetime.now().isoformat()))


def read_node_id():
    try:
        with open(NODE_JSON, "r", encoding="utf-8") as f:
            return str((json.load(f) or {}).get("node_id", ""))
    except (OSError, ValueError):
        return ""


def main():
    # 0) 一次性 + 日期硬约束 (仅 2026-09-11 当天可执行一次)
    if os.path.exists(MARKER):
        log("debug", "标记文件已存在, 补丁已执行过, 跳过")
        return 0
    today = datetime.now().strftime("%Y-%m-%d")
    if today != ALLOW_DATE:
        log("warn", "当前日期 %s != %s, 本补丁仅允许在 %s 当天执行一次, 退出"
            % (today, ALLOW_DATE, ALLOW_DATE))
        return 0

    # 1) 目标检测: 配置文件不存在 → 视为非目标节点, 落标记退出
    if not os.path.exists(XRAY_CONFIG):
        log("warn", "%s 不存在, 非目标节点, 落标记退出" % XRAY_CONFIG)
        write_marker("skip: no xray config")
        return 0

    # 2) 修改出站密码 (备份→改写; 幂等); 配置损坏 → 退出码 1, 下个周期重试
    try:
        changed, tags, has_target = patch_xray_config()
    except (OSError, ValueError) as exc:
        log("error", "读取/修改 %s 失败: %s" % (XRAY_CONFIG, exc))
        return 1
    if not has_target:
        log("info", "outbounds 中无 address=%s 的出站, 无需修改, 落标记退出" % TARGET_ADDRESS)
        write_marker("skip: no target outbound")
        return 0
    if not changed:
        # 存在目标出站但旧密码已不在 (已改过或密码非预期) — 幂等重入, 落标记退出
        log("info", "目标出站密码已非 %s (已改过或不一致), 无需修改, 落标记退出" % OLD_PASSWORD)
        write_marker("skip: password already changed / unexpected")
        return 0

    # 3) 校验配置 (失败回滚)
    if not xray_config_ok():
        log("error", "修改后配置校验失败, 回滚备份")
        restore_file(XRAY_CONFIG + BACKUP_SUFFIX)
        return 1

    # 4) 重启 xray (失败回滚后再拉起)
    if not restart_xray():
        log("error", "重启 xray 失败, 回滚备份并尝试再次拉起原配置")
        restore_file(XRAY_CONFIG + BACKUP_SUFFIX)
        restart_xray()
        return 1
    log("info", "xray 已重启且 active, 新密码生效 (outbounds: %s)" % ", ".join(tags))

    # 5) 落标记 + 通知
    write_marker("done: %s password -> %s" % (OLD_PASSWORD, NEW_PASSWORD))
    notify_tg(
        "🔧 tiktok 解锁出站密码更换完成\n"
        "• node_id: %s (%s)\n"
        "• address: %s\n"
        "• password: %s → %s\n"
        "• xray 已重启生效" % (
            read_node_id() or "?",
            parse_env_file(ENV_FILE).get("API_URL", "?"),
            TARGET_ADDRESS, OLD_PASSWORD, NEW_PASSWORD,
        )
    )
    log("info", "补丁完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
