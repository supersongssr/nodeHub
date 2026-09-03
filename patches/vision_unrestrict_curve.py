#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
一次性补丁 (2026-09-03): npanel vision-curvePreferences → 无限制 vision

背景:
  npanel 面板下发 vision-curvePreferences 协议时, xray 配置中
  inbounds[].streamSettings.tlsSettings.curvePreferences 仅含
  "X25519MLKEM768x25519" (PQ-only), 不支持 PQ 的客户端 (旧版 xray-core /
  sing-box / 部分移动端) 无法完成 TLS 握手。
  本补丁在 curvePreferences 的 mlkem 条目后追加 "X25519",
  使服务端同时接受 PQ 混合曲线与传统椭圆曲线 — 即纯 vision, 不带任何限制。

目标节点 (同时满足, 否则静默跳过):
  * ~/.env     中 API_PANEL=srp
  * ~/node.json 中 "v2_name" == "vision-curvePreferences"

动作:
  1. 备份并修改 /usr/local/etc/xray/config.json:
       inbounds[].streamSettings.tlsSettings.curvePreferences
         "X25519MLKEM768x25519"  →  "X25519MLKEM768x25519", "X25519"
     (仅当列表含 mlkem 条目且尚无 "X25519" 时; 幂等)
  2. xray run -test 校验配置 (失败自动回滚备份)
  3. systemctl restart xray 并验证 is-active (失败回滚备份并再次重启)
  4. 备份并修改 ~/node.json: "v2_name": "vision-curvePreferences" → "vision"
  5. 成功后写标记文件 ~/nodeAgent.vision-unrestrict.patch.done (仅一次)
  6. 成功后发 Telegram 通知 (TG_BOT_TOKEN / TG_CHAT_ID, 未配置则跳过)

约束:
  * 仅在 2026-09-03 当天 (本地时区) 允许执行, 其余日期直接退出
  * 标记文件存在则不再执行 (一次性; nodeAgent.sh 侧另有同名标记双重防护)

用法: python3 vision_unrestrict_curve.py
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
MARKER = os.path.join(HOME, "nodeAgent.vision-unrestrict.patch.done")

ALLOW_DATE = "2026-09-03"                # 仅当天可执行
TARGET_PANEL = "srp"                     # ~/.env API_PANEL
TARGET_V2 = "vision-curvePreferences"    # ~/node.json v2_name 匹配值
NEW_V2 = "vision"                        # 补丁后写入的 v2_name
PQ_SUBSTR = "mlkem"                      # 大小写不敏感, 匹配 X25519MLKEM768x25519 等
CLASSIC_CURVE = "X25519"                 # 追加的传统曲线 (解除 PQ-only 限制)
BACKUP_SUFFIX = ".bak.vision-unrestrict"  # 备份后缀 (同名覆盖, 只留最近一份)


def log(level, msg):
    print("[vision-unrestrict][%s] %s" % (level, msg), flush=True)


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


# ---------- 步骤 1: 修改 xray curvePreferences ----------
def patch_xray_config():
    """返回 (是否修改, 修改的 inbound tag 列表); 未命中目标则 (False, [])"""
    with open(XRAY_CONFIG, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    patched_tags = []
    for inbound in cfg.get("inbounds") or []:
        if not isinstance(inbound, dict):
            continue
        stream = inbound.get("streamSettings") or {}
        tls = stream.get("tlsSettings") or {}
        prefs = tls.get("curvePreferences")
        if not isinstance(prefs, list) or not prefs:
            continue
        if CLASSIC_CURVE in prefs:  # 已解除限制 (幂等)
            continue
        # 在 mlkem (PQ) 条目之后插入 X25519 — PQ 优先, 传统曲线兜底
        for i, curve in enumerate(prefs):
            if isinstance(curve, str) and PQ_SUBSTR in curve.lower():
                prefs.insert(i + 1, CLASSIC_CURVE)
                patched_tags.append(str(inbound.get("tag", "<无tag>")))
                break

    if patched_tags:
        backup_file(XRAY_CONFIG)
        with open(XRAY_CONFIG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
            f.write("\n")
    return bool(patched_tags), patched_tags


    # ---------- 步骤 1.5: 判断配置中是否存在 mlkem 曲线 ----------
def has_mlkem_curve():
    try:
        with open(XRAY_CONFIG, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return False
    for inbound in cfg.get("inbounds") or []:
        if not isinstance(inbound, dict):
            continue
        prefs = ((inbound.get("streamSettings") or {}).get("tlsSettings") or {}).get("curvePreferences") or []
        if any(isinstance(c, str) and PQ_SUBSTR in c.lower() for c in prefs):
            return True
    return False


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


# ---------- 步骤 4: 修改 ~/node.json v2_name ----------
def patch_node_json():
    with open(NODE_JSON, "r", encoding="utf-8") as f:
        node = json.load(f)
    if node.get("v2_name") == NEW_V2:  # 已改过 (幂等)
        return False
    backup_file(NODE_JSON)
    node["v2_name"] = NEW_V2
    with open(NODE_JSON, "w", encoding="utf-8") as f:
        json.dump(node, f, indent=2, ensure_ascii=False)
        f.write("\n")
    return True


def main():
    # 0) 一次性 + 日期硬约束 (仅 2026-09-03 当天可执行一次)
    if os.path.exists(MARKER):
        log("debug", "标记文件已存在, 补丁已执行过, 跳过")
        return 0
    today = datetime.now().strftime("%Y-%m-%d")
    if today != ALLOW_DATE:
        log("warn", "当前日期 %s != %s, 本补丁仅允许在 %s 当天执行一次, 退出"
            % (today, ALLOW_DATE, ALLOW_DATE))
        return 0

    # 1) 目标节点筛选
    panel = parse_env_file(ENV_FILE).get("API_PANEL", "")
    if panel != TARGET_PANEL:
        log("debug", "API_PANEL=%s != %s, 非目标节点, 跳过" % (panel or "空", TARGET_PANEL))
        return 0
    try:
        with open(NODE_JSON, "r", encoding="utf-8") as f:
            v2_name = (json.load(f) or {}).get("v2_name", "")
    except (OSError, ValueError):
        v2_name = ""
    if v2_name != TARGET_V2:
        log("debug", "v2_name=%s != %s, 非目标节点, 跳过" % (v2_name or "空", TARGET_V2))
        return 0

    # ---- 以下为目标节点, 执行改造 ----
    log("info", "命中目标节点 (API_PANEL=srp, v2_name=%s): 解除 vision PQ-only 限制" % TARGET_V2)
    if not os.path.exists(XRAY_CONFIG):
        log("error", "%s 不存在, 无法修改" % XRAY_CONFIG)
        return 1

    # 2) 修改 curvePreferences (备份→改写; 幂等)
    try:
        changed, tags = patch_xray_config()
    except (OSError, ValueError) as exc:
        log("error", "修改 %s 失败: %s" % (XRAY_CONFIG, exc))
        return 1
    if not changed and not has_mlkem_curve():
        # 配置里根本没有 mlkem 曲线可改 (非典型 vision-curve 配置) — 不重启, 落标记退出
        log("warn", "未发现 curvePreferences 中的 mlkem 条目, 无需修改, 落标记退出")
        with open(MARKER, "w", encoding="utf-8") as f:
            f.write("skip: no mlkem curvePreferences, %s\n" % datetime.now().isoformat())
        return 0
    # changed=False 且含 mlkem → 上次运行已改过 X25519 (幂等重入), 继续走完收尾

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
    log("info", "xray 已重启且 active, 新 curvePreferences 生效 (inbounds: %s)"
        % ", ".join(tags))

    # 5) 修改 ~/node.json: v2_name → vision
    try:
        node_changed = patch_node_json()
    except (OSError, ValueError) as exc:
        log("error", "修改 %s 失败: %s (xray 侧已生效, 本项可人工补改)" % (NODE_JSON, exc))
        return 1
    log("info", "%s v2_name: %s → %s" % (NODE_JSON, TARGET_V2, NEW_V2)
        if node_changed else "%s v2_name 已是 %s" % (NODE_JSON, NEW_V2))

    # 6) 落标记 + 通知
    with open(MARKER, "w", encoding="utf-8") as f:
        f.write("done: curvePreferences += X25519, v2_name -> %s, %s\n"
                % (NEW_V2, datetime.now().isoformat()))
    env = parse_env_file(ENV_FILE)
    node_id = ""
    try:
        with open(NODE_JSON, "r", encoding="utf-8") as f:
            node_id = str((json.load(f) or {}).get("node_id", ""))
    except (OSError, ValueError):
        pass
    notify_tg(
        "🔓 vision 解除 PQ-only 限制完成\n"
        "• node_id: %s (%s)\n"
        "• curvePreferences: + X25519 (不再强制 PQ)\n"
        "• v2_name: %s → %s\n"
        "• xray 已重启生效" % (node_id or "?", env.get("API_URL", "?"), TARGET_V2, NEW_V2)
    )
    log("info", "补丁完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
