#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tcpingCheck.py — NODE_PORT 大陆 tcping 被墙检测 (单文件模块, Python3 原生库).

定位 (nodeHub 节点端 tcping 的唯一正典实现, 见 plans/tcping-check.md):
  从 proxyDiagnose.py 的 _check_node_port_cn_tcping (NW10) 提取核心探测逻辑,
  做成独立 Python3 模块 (零第三方依赖, 仅标准库), 供:
    · nodeAgent.sh 每周期 (小时) 调用: 检测本节点 NODE_PORT 是否被墙 +
      推送结果至 ServerStatus-Rust-Moniter (/ingest/tcping);
      被墙处置 (换端口重装等) 由远程面板基于推送数据统一下发, 节点端
      不自动换端口 (block_level 供面板区分端口级/IP级处置依据)
    · 人工排障: python3 tcpingCheck.py --ip 1.2.3.4 --port 443 [--xcheck always]
  ServerStatus-Rust-Moniter 的中央侧检测 (monitor/core/checks/tcping_client.py)
  与本文件同源 (同一套 tcp.ping.pe 接口流程与判定口径), 两份实现需保持同步.

为什么不用 stat_client 的三网丢包判被墙:
  stat 数据的三网 ping 由探测点对节点做 ICMP ping, 双栈节点优先走 IPv6,
  而用户实际连接的是 IPv4:PORT —— v6 通不代表 v4 业务端口可达.
  本检测直接对 <用户连接的 IP:PORT> 做 TCP 握手测试 (借 tcp.ping.pe 大陆
  探测点, 分电信/联通/移动/厂商 + 海外对照), 与用户链路同构, 判定即真相.

探测原理 (tcp.ping.pe 接口流程, 与 proxyDiagnose.py / cn_port_check.py 同源):
  1) GET  /IP:PORT              → antiflood=<hex> cookie
  2) GET  /IP:PORT?browsercheck=ok -b cookie → taskStartQuery/taskStartToken
  3) POST ajax_startTask_v1.php (query+token, 须带 Origin)  → stream_id
  4) 轮询 ajax_getPingResults_v2.php (增量拼接) 至 outstandingNodeCount:0
  结果: {"node_id":"CN_5",...,"result":V} — V=1 失败 / V>1 成功 (V/100≈ms);
  CN_ 前缀 = 大陆探测点, 按 data-provider 细分 ct/cu/cm/vendor, 其余作海外对照.

判定 (与中央侧 cn_port_check.py 同一口径, 宁可漏报不可误报):
  blocked     = 有探测点的大陆组 (ct/cu/cm/vendor) 全部失败 且 海外至少 1 个成功
                (海外对照证明端口活着 —— 全球全断是端口没开/安全组, 不是被墙)
  unreachable = 海外也全失败 (端口全球不可达, 非大陆方向问题)
  partial     = 有组部分失败, 无组全断
  ok          = 全部正常
  not_listening = 本机 node_port 无 TCP 监听 (纯 UDP: Hysteria2 直听) —
                TCP/UDP 是两个独立命名空间, 纯 UDP 端口 tcping 全失败属正常,
                绝不能判被墙 (同 proxyDiagnose NW10 的协议感知注意).

block_level (端口级 vs IP 级被墙的区分 — xcheck 交叉验证, 只有节点端能做):
  主测判 blocked 时, 本机随机开一个临时 TCP 端口 (20000-60000, 标准库 socket)
  再测一轮 (探测点连的是本机公网 IP, 临时端口由本机监听 → 必须在节点上跑):
    port    = 新端口大陆可达 (任一大陆组有成功) → 端口级封锁, IP 未被墙 ★换端口可救 (处置由远程面板下发)
    ip      = 新端口大陆也全断 且 新端口海外正常 → IP 级封锁, 换端口无效
    unknown = 新端口全球不可达 (云安全组/防火墙拦了临时端口) 或探测服务异常 → 无定论
  无定论绝不误判 IP 被墙; 换端口自愈仅在 block_level=port 时触发 (nodeAgent 侧).

输出: 单个 JSON 对象到 stdout (机器可读; nodeAgent/人工均消费此格式),
      进度日志到 stderr (--verbose 开启, 默认静默).
      退出码: 0=检测完成 (无论结果), 2=参数/内部错误, 3=探测服务不可用.

用法:
  python3 tcpingCheck.py                          # 自动解析本节点 ip/port (~/node.json)
  python3 tcpingCheck.py --port 443 --xcheck auto # 指定端口; blocked 时自动跑交叉验证
  python3 tcpingCheck.py --ip 1.2.3.4 --port 443  # 在任意机器测任意目标 (远测别的节点)
  python3 tcpingCheck.py --module                 # 作为模块导入的提示

版本: 1.0 (2026-09-05)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

VERSION = "tcpingCheck.py 1.0 (nodeHub)"

# ── 探测服务参数 (与 proxyDiagnose.py / cn_port_check.py 同源) ──
TCPING_BASE = "https://tcp.ping.pe"
TCPING_UA = "Mozilla/5.0 (X11; Linux x86_64) NodeHub-tcpingCheck"
PAGE_TIMEOUT = 25.0          # 单个 HTTP 请求超时 (秒)
BROWSERCHECK_DELAY = 2.0     # antiflood cookie 之后的礼貌等待 (秒)
POLL_INTERVAL = 4            # 结果轮询间隔 (秒)
MAX_POLLS = 12               # 最多轮询次数 (≈48s; outstandingNodeCount:0 提前收工)

# 交叉验证 (xcheck) 参数
XCHECK_PORT_MIN = 20000
XCHECK_PORT_MAX = 60000
XCHECK_ATTEMPTS = 20         # 随机端口 bind 尝试次数
XCHECK_LISTEN_SEC = 150      # 临时监听时长上限 (秒; 探测一轮 ~60s, 留余量)

# 大陆运营商组 (与中央侧 cn_port_check.py 一致)
ISP_GROUPS = (("ct", "电信"), ("cu", "联通"), ("cm", "移动"), ("vendor", "厂商"))
ALL_GROUPS = ("ct", "cu", "cm", "vendor", "os")

# 状态 → 中文 (人工可读输出/通知文案用)
STATUS_LABEL = {
    "blocked": "疑似被墙",
    "partial": "部分线路干扰",
    "unreachable": "全球不可达",
    "ok": "正常",
    "not_listening": "无TCP监听(纯UDP?)",
    "no_cn_probe": "无大陆探测点",
    "no_contrast": "无海外对照",
    "no_result": "无结果",
    "error": "探测服务异常",
}
BLOCK_LEVEL_LABEL = {"port": "端口级封锁(IP未墙)", "ip": "IP级封锁(换端口无效)",
                     "none": "未封锁", "unknown": "无定论"}


class TcpingError(Exception):
    """探测服务侧失败 (非目标端口问题). kind ∈
    {service_down, interface_changed, busy, start_error, poll_error}"""

    def __init__(self, kind: str, detail: str = "") -> None:
        super().__init__("%s: %s" % (kind, detail) if detail else kind)
        self.kind = kind
        self.detail = detail


# ═══════════════════════════════════════════════════════════
#  探测客户端 (tcp.ping.pe)
# ═══════════════════════════════════════════════════════════

def _http(url: str, cookie: Optional[str] = None, data: Optional[bytes] = None,
          referer: Optional[str] = None, timeout: float = PAGE_TIMEOUT) -> str:
    """带 UA/cookie/Origin 头的 GET/POST, 返回响应文本.

    网络层异常统一转 TcpingError(service_down) —— 探测服务不可达
    绝不能误判成目标端口被墙.
    """
    req = urllib.request.Request(url, data=data)
    req.add_header("User-Agent", TCPING_UA)
    if cookie:
        req.add_header("Cookie", cookie)
    if referer:
        req.add_header("Referer", referer)
    if data is not None:
        # POST ajax_startTask_v1.php 必须带这两个头, 否则 {"ok":false,"error":"Invalid origin"}
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
        req.add_header("X-Requested-With", "XMLHttpRequest")
        req.add_header("Origin", TCPING_BASE)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return str(r.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise TcpingError("service_down", "%s: %s" % (url.split("?")[0], e)) from e


# 探测点分组表 (进程内缓存; 每次任务从页面节点表解析)
#   {node_id: group}  group ∈ ct/cu/cm/vendor/os
_NODE_GROUPS: Dict[str, str] = {}


def parse_node_labels(page_html: str) -> int:
    """从 tcp.ping.pe 任务页面解析探测点表 → 填充 _NODE_GROUPS.

    页面每探测点一行 (实测格式):
      <tr id='ping-CN_104-tr' data-pinger-id='CN_104'
          data-location='China, Jiangsu' data-provider='China Mobile' ...>
    分组: provider 含 Telecom→ct / Unicom→cu / Mobile→cm / 其余大陆→vendor;
    非大陆 node_id (无 CN_ 前缀) → os (海外对照). 返回解析到的探测点数.
    """
    n = 0
    for m in re.finditer(
            r"<tr[^>]*data-pinger-id='([\w]+)'[^>]*data-location='([^']*)'"
            r"[^>]*data-provider='([^']*)'", page_html):
        node_id, _loc, provider = m.group(1), m.group(2), m.group(3)
        p = provider.lower()
        if node_id.startswith("CN_"):
            if "telecom" in p:
                g = "ct"
            elif "unicom" in p:
                g = "cu"
            elif "mobile" in p:
                g = "cm"
            else:                       # Tencent / Aliyun / … IDC
                g = "vendor"
        else:
            g = "os"
        _NODE_GROUPS[node_id] = g
        n += 1
    return n


def _group_of(node_id: str) -> str:
    """node_id → 组; 无标注时按前缀兜底 (CN_→vendor, 其余→os)."""
    g = _NODE_GROUPS.get(node_id)
    if g:
        return g
    return "vendor" if node_id.startswith("CN_") else "os"


def tcping(ip: str, port: int) -> Dict[str, Any]:
    """对 ip:port 跑一轮大陆/海外 tcping, 返回按组统计 (不抛异常).

    返回: {"status": "ok"|"error", "error": str,
          "groups": {g: {"ok": N, "total": N}},     # g ∈ ct/cu/cm/vendor/os
          "probes": N}
      · status=ok: 探测完成; groups 为逐组成功/总数
      · status=error: groups 全 0, error 为归类说明 (探测服务侧问题, 不是端口问题)
    """
    # IPv6 字面量在 URL path 里需方括号包裹 (与 proxyDiagnose.py 同)
    tgt = "[%s]:%d" % (ip, port) if ":" in ip else "%s:%d" % (ip, port)
    groups: Dict[str, Dict[str, int]] = {
        g: {"ok": 0, "total": 0} for g in ALL_GROUPS}
    empty: Dict[str, Any] = {"status": "error", "error": "",
                             "groups": groups, "probes": 0}
    try:
        # 1) 首访: 响应内嵌 antiflood=<hex> cookie, 后续请求必须携带
        page = _http("%s/%s" % (TCPING_BASE, urllib.parse.quote(tgt)))
        m = re.search(r"antiflood=([a-f0-9]+)", page)
        if not m:
            raise TcpingError("service_down", "no antiflood cookie")
        cookie = "antiflood=%s" % m.group(1)

        # 2) 带 cookie 复访 (浏览器自检页) → 任务令牌 + 顺带解析探测点分组表
        time.sleep(BROWSERCHECK_DELAY)
        page = _http("%s/%s?browsercheck=ok" % (TCPING_BASE, urllib.parse.quote(tgt)),
                     cookie=cookie)
        if not _NODE_GROUPS:
            n = parse_node_labels(page)
            if n:
                _log("探测点分组表解析: %d 个 (%s)" % (n, groups_summary()))
        tok = re.search(r'var taskStartToken = "([^"]*)"', page)
        qry = re.search(r'var taskStartQuery = "([^"]*)"', page)
        if not (tok and qry):
            raise TcpingError("interface_changed", "no taskStartToken/taskStartQuery")

        # 3) 启动探测任务 (须带 Origin 头)
        body = urllib.parse.urlencode(
            {"query": qry.group(1), "start_token": tok.group(1)}).encode()
        start = _http("%s/ajax_startTask_v1.php" % TCPING_BASE, cookie=cookie,
                      data=body, referer="%s/%s" % (TCPING_BASE, urllib.parse.quote(tgt)))
        sid_m = re.search(r'"stream_id":"?(\d+)', start)
        if not sid_m:
            if "too_many" in start:
                raise TcpingError("busy", start[:80])
            raise TcpingError("start_error", start[:80])
        sid = sid_m.group(1)

        # 4) 轮询增量结果拼接; "outstandingNodeCount":0 = 全部探测点已回报
        all_resp = ""
        for i in range(1, MAX_POLLS + 1):
            time.sleep(POLL_INTERVAL)
            r = _http("%s/ajax_getPingResults_v2.php?type=tcp&totalPolls=%d&stream_id=%s"
                      % (TCPING_BASE, i, sid), cookie=cookie,
                      referer="%s/%s" % (TCPING_BASE, urllib.parse.quote(tgt)))
            all_resp += "\n" + r
            if '"outstandingNodeCount":0' in r:
                break

        # 5) 解析: {"node_id":"CN_5","timestamp_ms":N,"result":V,"result_text":""}
        #    V=1 失败 / V>1 成功 (V/100≈ms)
        probes = re.findall(
            r'"node_id":"([A-Za-z0-9_]+)","timestamp_ms":\d+,"result":(-?\d+)', all_resp)
        if not probes:
            raise TcpingError("poll_error", "no results parsed")

        out = dict(empty)
        for node_id, v in probes:
            g = _group_of(node_id)
            groups[g]["total"] += 1
            if int(v) > 1:
                groups[g]["ok"] += 1
        out["groups"] = groups
        out["status"] = "ok"
        out["probes"] = len(probes)
        return out
    except TcpingError as e:
        out = dict(empty)
        out["error"] = "%s: %s" % (e.kind, e.detail) if e.detail else e.kind
        return out
    except Exception as e:  # noqa: BLE001 — 兜底: 任何异常都归为服务侧错误, 不误判
        out = dict(empty)
        out["error"] = "unexpected: %s" % e
        return out


def groups_summary() -> str:
    """当前探测点分组表的人话摘要 (日志用), 如 'ct=2 cu=2 cm=2 vendor=7 os=154'."""
    c: Dict[str, int] = {g: 0 for g, _ in ISP_GROUPS}
    c["os"] = 0
    for g in _NODE_GROUPS.values():
        if g in c:
            c[g] += 1
    return " ".join("%s=%d" % (g, c[g]) for g in ALL_GROUPS)


# ═══════════════════════════════════════════════════════════
#  判定 (与中央侧 cn_port_check.py 同一口径)
# ═══════════════════════════════════════════════════════════

def group_verdict(stat: Dict[str, Any], group: str) -> str:
    """单组判定: blocked / partial / ok / n/a (无探测点) / no_contrast (无海外对照).

    blocked 要求: 该组全部失败 且 海外至少 1 个成功 (对照证明端口活着).
    海外对照组 (os) 特殊: ≥1 成功即 ok (对照组只证明端口活着, 抖动不算噪声).
    """
    g = (stat.get("groups") or {}).get(group) or {"ok": 0, "total": 0}
    if g["total"] == 0:
        return "n/a"
    os_ok = ((stat.get("groups") or {}).get("os") or {"ok": 0})["ok"]
    if group == "os":
        return "ok" if g["ok"] >= 1 else "no_contrast"
    if g["ok"] == 0:
        return "blocked" if os_ok >= 1 else "no_contrast"
    if g["ok"] < g["total"]:
        return "partial"
    return "ok"


def classify(stat: Dict[str, Any]) -> str:
    """整体状态: blocked/unreachable/partial/ok/no_cn_probe/no_result/error.

    blocked = 有探测点的大陆组 (ct/cu/cm/vendor) 全部 blocked —— 覆盖
    「全组被墙」与「仅某一运营商方向被墙」两种形态;
    unreachable = 海外也全部失败 (端口全球不可达, 非大陆方向问题);
    宁可漏报不可误报 (海外零成功/零样本时不判 blocked).
    """
    if stat.get("status") != "ok":
        return "error"
    groups = stat.get("groups") or {}
    cn_total = sum((groups.get(g) or {"total": 0})["total"] for g, _ in ISP_GROUPS)
    os_g = groups.get("os") or {"ok": 0, "total": 0}
    if cn_total == 0 and os_g["total"] == 0:
        return "no_result"
    if os_g["total"] > 0 and os_g["ok"] == 0:
        return "unreachable"
    verdicts = {g: group_verdict(stat, g) for g, _ in ISP_GROUPS}
    if "blocked" in verdicts.values():
        return "blocked"
    if "partial" in verdicts.values():
        return "partial"
    if cn_total == 0:
        return "no_cn_probe"
    return "ok"


def blocked_isps(stat: Dict[str, Any]) -> List[str]:
    """被墙的大陆组列表 (如 ['ct','cm']; 仅整体 blocked 时非空)."""
    if classify(stat) != "blocked":
        return []
    return [g for g, _ in ISP_GROUPS if group_verdict(stat, g) == "blocked"]


def groups_marks(stat: Dict[str, Any]) -> str:
    """组状态标记串: '电信✗ 联通✗ 移动✗ 厂商✓ 海外✓'."""
    mark = {"blocked": "✗", "partial": "△", "ok": "✓", "n/a": "·", "no_contrast": "?"}
    parts = ["%s%s" % (lbl, mark.get(group_verdict(stat, g), "?")) for g, lbl in ISP_GROUPS]
    parts.append("海外%s" % mark.get(group_verdict(stat, "os"), "?"))
    return " ".join(parts)


# ═══════════════════════════════════════════════════════════
#  节点端本地能力 (标准库)
# ═══════════════════════════════════════════════════════════

def local_tcp_listening(port: int) -> bool:
    """本机 port 是否有 TCP 监听 (loopback 直连探测, 无需 ss/netstat).

    纯 UDP 端口 (Hysteria2 直听) 无 TCP 监听 → tcping 全失败属正常,
    不能判被墙 (与 proxyDiagnose NW10 的 ss 前置检查等价).
    """
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=3)
        s.close()
        return True
    except OSError:
        return False


class TempListener:
    """临时 TCP 监听 (xcheck 交叉验证用, 标准库 socket + 后台 accept 线程).

    随机端口 20000-60000, bind 失败 (端口被占) 自动重试;
    探测点只需 TCP 握手成功 (内核 SYN backlog 即可完成), 后台线程
    accept-and-close 兜底防止 backlog 溢出. with 语句退出自动关闭.
    """

    def __init__(self, avoid_ports: Tuple[int, ...] = ()) -> None:
        self.sock: Optional[socket.socket] = None
        self.port = 0
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._avoid = set(avoid_ports)

    def __enter__(self) -> "TempListener":
        last_err: Optional[str] = None
        for _ in range(XCHECK_ATTEMPTS):
            cand = random.randint(XCHECK_PORT_MIN, XCHECK_PORT_MAX)
            if cand in self._avoid:
                continue
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind(("0.0.0.0", cand))
                s.listen(64)
                s.settimeout(1.0)
                self.sock, self.port = s, cand
                break
            except OSError as e:
                last_err = str(e)
                s.close()
        if self.sock is None:
            raise TcpingError("start_error",
                              "temp port bind failed (%d attempts, last=%s)"
                              % (XCHECK_ATTEMPTS, last_err or "?"))
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()
        return self

    def _accept_loop(self) -> None:
        """后台 accept-and-close (仅保证握手完成; 不承载任何业务)."""
        assert self.sock is not None
        deadline = time.time() + XCHECK_LISTEN_SEC
        self.sock.settimeout(1.0)
        while not self._stop.is_set() and time.time() < deadline:
            try:
                conn, _ = self.sock.accept()
                conn.close()
            except socket.timeout:
                continue
            except OSError:
                break

    def __exit__(self, *exc: Any) -> None:
        self._stop.set()
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass


def xcheck(ip: str, avoid_ports: Tuple[int, ...] = ()) -> Dict[str, Any]:
    """交叉验证: 本机随机开临时端口 → 再测一轮 → 区分端口级 / IP 级被墙.

    返回: {"level": "port"|"ip"|"unknown", "port": N, "stat": {...}}
      port    = 新端口大陆任一组可达 → 端口级封锁, IP 未被墙 ★换端口可救 (处置由远程面板下发)
      ip      = 新端口大陆全断 且 海外正常 → IP 级封锁, 换端口无效
      unknown = 新端口全球不可达 (安全组/防火墙拦了临时端口) / 探测服务异常
                → 无定论, 绝不据此误判 IP 被墙 (同 proxyDiagnose CN_XCHECK_INCONCLUSIVE)
    """
    try:
        with TempListener(avoid_ports) as tl:
            _log("xcheck: 临时监听 0.0.0.0:%d, 开始交叉验证探测" % tl.port)
            stat = tcping(ip, tl.port)
            xc_port = tl.port
    except TcpingError as e:
        return {"level": "unknown", "port": 0,
                "stat": {"status": "error", "error": str(e),
                         "groups": {g: {"ok": 0, "total": 0} for g in ALL_GROUPS},
                         "probes": 0}}
    if stat.get("status") != "ok":
        return {"level": "unknown", "port": xc_port, "stat": stat}

    groups = stat.get("groups") or {}
    cn_ok = sum((groups.get(g) or {"ok": 0})["ok"] for g, _ in ISP_GROUPS)
    os_g = groups.get("os") or {"ok": 0, "total": 0}
    level = "unknown"
    if cn_ok > 0:
        level = "port"        # 新端口大陆可达 → 仅原端口被针对, IP 未整段封
    elif os_g["ok"] >= 1:
        level = "ip"          # 新端口大陆也全断, 但海外正常 → IP 级
    # else: 新端口全球全断 → 安全组/防火墙拦截, 无定论
    return {"level": level, "port": xc_port, "stat": stat}


# ═══════════════════════════════════════════════════════════
#  目标解析 (IP / 端口 / stat_user — 与 proxyDiagnose/proxyInstall 同源)
# ═══════════════════════════════════════════════════════════

def _norm_ip(ip: str) -> str:
    """IP 归一化 (与 plans/stat-ip-identity.md §4 契约一致):
    去首尾空白/换行 → 转小写 → 去 %zone 后缀."""
    return ip.strip().lower().split("%")[0]


def _read_node_json() -> Dict[str, Any]:
    path = os.path.join(os.path.expanduser("~"), "node.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _read_node_env() -> Dict[str, str]:
    out: Dict[str, str] = {}
    for name in ("node.env", ".env"):
        path = os.path.join(os.path.expanduser("~"), name)
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if "=" in line and not line.startswith("#"):
                        k, v = line.split("=", 1)
                        out[k.strip()] = v.strip().strip('"').strip("'")
        except OSError:
            continue
    return out


def _detect_public_ip() -> str:
    """公网 IPv4 探测 (api.ip.sb → ifconfig.me, 与 proxyDiagnose 同源)."""
    for url in ("https://api.ip.sb", "https://ifconfig.me"):
        try:
            with urllib.request.urlopen(
                    urllib.request.Request(url, headers={"User-Agent": "curl/8"}),
                    timeout=10) as r:
                ip = _norm_ip(r.read().decode("utf-8", "replace"))
                if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", ip):
                    return ip
        except (urllib.error.URLError, TimeoutError, OSError):
            continue
    return ""


def resolve_target(ip_arg: Optional[str], port_arg: Optional[int],
                    ) -> Tuple[str, int, str, str]:
    """解析检测目标: (ip, port, stat_user, ip_source).

    优先级 (与 proxyDiagnose.py / proxyInstall.sh 同源):
      IP   : --ip 参数 > ~/node.json .node_ip > ~/node.env node_ip= > 公网探测
             (★IPv4 优先 — stat_client 三网 ping 双栈优先 v6 是本检测存在的原因)
      PORT : --port 参数 > ~/node.json .node_port > ~/node.env node_port= > 443
      stat_user (推送/匹配身份): --stat-user 参数 > ~/node.stat_user >
             ~/node.json .stat_user > ~/node.env stat_user= > md5(ip) 兜底
             (契约: stat_user = md5(归一化IP), 见 nodeHub plans/stat-ip-identity.md)
    """
    nj = _read_node_json()
    ne = _read_node_env()

    ip = _norm_ip(ip_arg or "")
    ip_source = "arg"
    if not ip:
        ip = _norm_ip(str(nj.get("node_ip") or ""))
        ip_source = "node.json"
    if not ip:
        ip = _norm_ip(ne.get("node_ip") or "")
        ip_source = "node.env"
    if not ip:
        ip = _detect_public_ip()
        ip_source = "detect"

    port = int(port_arg or 0)
    if port <= 0:
        try:
            port = int(str(nj.get("node_port") or "0").strip() or 0)
        except ValueError:
            port = 0
    if port <= 0:
        try:
            port = int(ne.get("node_port") or "0")
        except ValueError:
            port = 0
    if port <= 0:
        port = 443

    stat_user = _norm_ip(str(nj.get("stat_user") or "")) or _norm_ip(ne.get("stat_user") or "")
    if not stat_user:
        p = os.path.join(os.path.expanduser("~"), "node.stat_user")
        try:
            with open(p, encoding="ascii") as f:
                stat_user = f.read().strip()
        except OSError:
            stat_user = ""
    if not stat_user and ip:
        stat_user = hashlib.md5(ip.encode()).hexdigest()

    return ip, port, stat_user or "", ip_source


# ═══════════════════════════════════════════════════════════
#  主流程
# ═══════════════════════════════════════════════════════════

_VERBOSE = False


def _log(msg: str) -> None:
    if _VERBOSE:
        sys.stderr.write("[tcpingCheck] %s\n" % msg)
        sys.stderr.flush()


def run_check(ip_arg: Optional[str] = None, port_arg: Optional[int] = None,
              stat_user_arg: Optional[str] = None, xcheck_mode: str = "auto",
              skip_local_check: bool = False) -> Dict[str, Any]:
    """执行一次完整检测, 返回报告 dict (同时为 stdout JSON 与推送 payload).

    xcheck_mode:
      auto   = 仅主测判 blocked 时跑交叉验证 (默认; 省探测服务压力)
      always = 无条件跑 (人工排障: ok 时作自检对照)
      never  = 不跑 (block_level 恒 unknown)
    """
    t0 = time.time()
    ip, port, stat_user, ip_source = resolve_target(ip_arg, port_arg)
    if stat_user_arg:
        stat_user = stat_user_arg

    report: Dict[str, Any] = {
        "ok": False,
        "ts": int(time.time()),
        "agent": VERSION,
        "ip": ip,
        "ip_family": 6 if ":" in ip else 4,
        "ip_source": ip_source,
        "port": port,
        "stat_user": stat_user,
        "status": "error",
        "blocked_isps": [],
        "block_level": "none",
        "groups": {g: {"ok": 0, "total": 0} for g in ALL_GROUPS},
        "os_contrast_ok": False,
        "xcheck": None,
        "local_listening": None,
        "duration_ms": 0,
        "error": "",
    }
    if not ip:
        report["error"] = "无法确定目标 IP (--ip / ~/node.json / ~/node.env / 公网探测均失败)"
        return report

    _NODE_GROUPS.clear()  # 单次进程内清空, 保证每次运行重新解析探测点表

    # 前置: 纯 UDP 端口 (无 TCP 监听) tcping 无意义, 不判被墙
    # (仅测本机目标时检查; --ip 显式指定远端目标时无法本地判断)
    if not skip_local_check and ip_arg is None:
        listening = local_tcp_listening(port)
        report["local_listening"] = listening
        if not listening:
            report["ok"] = True
            report["status"] = "not_listening"
            report["error"] = ("NODE_PORT=%d 无 TCP 监听 (疑似纯 UDP: Hysteria2 直听), "
                               "tcping 只能测 TCP, 跳过被墙判定" % port)
            report["duration_ms"] = int((time.time() - t0) * 1000)
            return report

    stat = tcping(ip, port)
    status = classify(stat)
    report["groups"] = stat.get("groups") or report["groups"]
    report["status"] = status
    report["blocked_isps"] = blocked_isps(stat)
    report["os_contrast_ok"] = bool(((stat.get("groups") or {}).get("os")
                                     or {"ok": 0})["ok"] >= 1)
    report["error"] = str(stat.get("error") or "")
    report["probes"] = stat.get("probes", 0)

    if status == "error":
        report["duration_ms"] = int((time.time() - t0) * 1000)
        return report  # ok=False: 探测服务异常, 调用方下周期重试

    # 交叉验证: 端口级 vs IP 级 (must)
    need_xcheck = (
        xcheck_mode == "always"
        or (xcheck_mode == "auto" and status == "blocked")
    )
    if status == "blocked" and xcheck_mode == "never":
        report["block_level"] = "unknown"
    if need_xcheck and status in ("blocked", "ok", "partial"):
        if status == "blocked":
            xc = xcheck(ip, avoid_ports=(port,))
            report["xcheck"] = {
                "port": xc["port"], "level": xc["level"],
                "groups": (xc["stat"].get("groups") or {}),
            }
            report["block_level"] = xc["level"]
        else:
            # 自检模式 (always + 非 blocked): 新端口理应同样可达; 记录对照不发难
            xc = xcheck(ip, avoid_ports=(port,))
            report["xcheck"] = {
                "port": xc["port"], "level": xc["level"],
                "groups": (xc["stat"].get("groups") or {}),
                "selftest": True,
            }
            report["block_level"] = "none"

    report["ok"] = True
    report["duration_ms"] = int((time.time() - t0) * 1000)
    _log("完成: %s:%d → %s [%s] level=%s (%.1fs)"
         % (ip, port, status, groups_marks(stat), report["block_level"],
            (time.time() - t0)))
    return report


def main() -> int:
    global _VERBOSE
    p = argparse.ArgumentParser(
        description="NODE_PORT 大陆 tcping 被墙检测 (tcp.ping.pe, 分三网+厂商+海外对照; "
                    "blocked 时交叉验证区分端口级/IP 级). 输出 JSON 到 stdout.")
    p.add_argument("--ip", help="目标 IP (默认: ~/node.json node_ip > node.env > 公网探测, IPv4 优先)")
    p.add_argument("--port", type=int, help="目标端口 (默认: ~/node.json node_port > 443)")
    p.add_argument("--stat-user", help="覆盖 stat_user (默认: ~/node.stat_user > node.json > md5(ip))")
    p.add_argument("--xcheck", choices=["auto", "always", "never"], default="auto",
                   help="交叉验证模式: auto=仅 blocked 时 (默认) / always=总是 / never=关闭")
    p.add_argument("--no-local-check", action="store_true",
                   help="跳过本机 TCP 监听前置检查 (--ip 远测别的节点时)")
    p.add_argument("--pretty", action="store_true", help="JSON 缩进输出 (人工阅读)")
    p.add_argument("-v", "--verbose", action="store_true", help="进度日志输出到 stderr")
    args = p.parse_args()
    _VERBOSE = args.verbose

    rc = 0
    try:
        report = run_check(ip_arg=args.ip, port_arg=args.port,
                           stat_user_arg=args.stat_user, xcheck_mode=args.xcheck,
                           skip_local_check=args.no_local_check)
    except Exception as e:  # noqa: BLE001 — 兜底: 输出合法 JSON 而非裸异常
        report = {"ok": False, "ts": int(time.time()), "agent": VERSION,
                  "status": "error", "error": "internal: %s" % e,
                  "blocked_isps": [], "block_level": "none"}
        rc = 2
    if report.get("status") == "error" and report.get("error", "").startswith(
            ("service_down", "busy", "interface_changed", "start_error", "poll_error")):
        rc = 3  # 探测服务侧问题 (调用方下周期重试, 不影响其他功能)
    elif report.get("status") == "error":
        rc = 3

    print(json.dumps(report, ensure_ascii=False,
                     indent=2 if args.pretty else None))
    return rc


if __name__ == "__main__":
    sys.exit(main())
