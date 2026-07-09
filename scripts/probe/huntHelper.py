#!/usr/bin/env python3
"""huntHelper.py — JA3↔用户 关联捕获器 (纯 Python, 无第三方依赖)

用途: 在节点本地把 tcpdump 抓到的 TLS ClientHello 与 xray access.log 关联,
      得到 (JA3, 用户邮箱, 源IP, SNI) 四元组 —— 回答"指纹 X 是哪个用户/客户端".

核心原理 (vision/reality, xray 前置):
  - ClientHello 包的 TCP 四元组 (client_ip:client_port -> node:443)
    与 xray access.log 里 "from client_ip:client_port ... email: xxx" 是同一条连接.
  - 用 src_ip:src_port 做 JOIN 键, 即可把 JA3 关联到 VLESS 用户邮箱.

命令:
  huntHelper.py hunt <pcap> <xray_access_log> <window_secs>
    → stdout 每行: ja3<TAB>user<TAB>src_ip<TAB>src_port<TAB>sni<TAB>matched(yes/no)
      matched=yes: 该 ClientHello 的连接被 xray 接受并关联到了用户 (真实用户)
      matched=no : access.log 里找不到该连接 (探针/扫描/未认证, 无用户)
  huntHelper.py ja3 <pcap>            → 仅算 JA3, 每行 ja3<TAB>src_ip<TAB>sni (调试)
  huntHelper.py watchlist <hash,...>  → 校验 watchlist 格式

注意: JA3 算法必须与监控端 probe_ingest_server.parse_clienthello_ja3 完全一致,
      否则节点算的 hash 与服务端存的 hash 对不上. 本文件是它的逐字移植.
"""

import struct
import sys
import hashlib
import re
import os
from datetime import datetime, timedelta


# ═══════════════════════════════════════════════════════════
# GREASE 判定 (与服务端一致)
# ═══════════════════════════════════════════════════════════
def _is_grease(v):
    """GREASE 值: 形如 0x?a?a (低字节==高字节, 且 (v&0x0f0f)==0x0a0a)."""
    return (v & 0x0f0f) == 0x0a0a and (v & 0xff) == ((v >> 8) & 0xff)


# ═══════════════════════════════════════════════════════════
# pcap 解析 (移植自 probeHelper.py)
# ═══════════════════════════════════════════════════════════
def _iter_pcap(path):
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic == b"\xd4\xc3\xb2\xa1":
            endian = "<"
        elif magic == b"\xa1\xb2\xc3\xd4":
            endian = ">"
        elif magic == b"\x4d\x3c\xb2\xa1":
            endian = "<"  # nanosecond
        elif magic == b"\xa1\xb2\x3c\x4d":
            endian = ">"
        else:
            return
        gh = f.read(20)
        _vmaj, _vmin, _tz, _sig, _snap, linktype = struct.unpack(endian + "HHIIIi", gh)
        while True:
            hdr = f.read(16)
            if len(hdr) < 16:
                return
            ts_s, ts_us, incl_len, _orig = struct.unpack(endian + "IIII", hdr)
            data = f.read(incl_len)
            if len(data) < incl_len:
                return
            yield linktype, ts_s, data


def _strip_l2(linktype, data):
    if linktype == 1:
        off = 14
        if len(data) < off + 1:
            return None
        if data[12:14] == b"\x81\x00":  # VLAN
            off = 18
        return data[off:]
    elif linktype in (101, 12):
        return data
    elif linktype == 113:  # Linux SLL
        return data[16:]
    elif linktype in (228, 276):  # Linux SLL2
        return data[20:]
    return None


def _parse_ip_tcp(ip):
    """返回 (src_ip_str, src_port, tcp_payload) 或 (None, None, None)."""
    if not ip:
        return None, None, None
    ver = ip[0] >> 4
    if ver == 4:
        if len(ip) < 20:
            return None, None, None
        ihl = (ip[0] & 0x0f) * 4
        if ip[9] != 6:  # 非 TCP
            return None, None, None
        src = ".".join(str(b) for b in ip[12:16])
        tcp = ip[ihl:]
    elif ver == 6:
        if len(ip) < 40:
            return None, None, None
        if ip[6] != 6:
            return None, None, None
        sb = ip[8:24]
        src = ":".join("%x" % int.from_bytes(sb[i:i + 2], "big") for i in range(0, 16, 2))
        tcp = ip[40:]
    else:
        return None, None, None
    if len(tcp) < 20:
        return None, None, None
    src_port = int.from_bytes(tcp[0:2], "big")
    data_off = (tcp[12] >> 4) * 4
    return src, src_port, tcp[data_off:]


# ═══════════════════════════════════════════════════════════
# ClientHello → (JA3 md5, SNI)  [JA3 逐字移植自服务端]
# ═══════════════════════════════════════════════════════════
def parse_clienthello(payload):
    """payload = TCP payload (含 TLS record header).
    返回 (ja3_md5, sni) 或 (None, None). 与服务端算法严格一致."""
    try:
        b = payload
        if len(b) < 5 or b[0] != 0x16:          # handshake record
            return None, None
        hs_off = 5
        if len(b) < hs_off + 4 or b[hs_off] != 0x01:  # client_hello
            return None, None
        p = hs_off + 4
        if p + 2 + 32 + 1 > len(b):
            return None, None
        ja3_ver = str(int.from_bytes(b[p:p + 2], "big"))
        p += 2 + 32
        sid_len = b[p]; p += 1 + sid_len
        cs_len = int.from_bytes(b[p:p + 2], "big"); p += 2
        ciphers = []
        for i in range(0, cs_len, 2):
            c = int.from_bytes(b[p + i:p + i + 2], "big")
            if not _is_grease(c):
                ciphers.append(str(c))
        p += cs_len
        cm_len = b[p]; p += 1 + cm_len
        ext_total = int.from_bytes(b[p:p + 2], "big"); p += 2
        ext_list = []
        curves = []
        ec_pf = []
        sni = None
        ext_end = p + ext_total
        while p + 4 <= ext_end and p + 4 <= len(b):
            ext_type = int.from_bytes(b[p:p + 2], "big")
            ext_len = int.from_bytes(b[p + 2:p + 4], "big")
            ext_data = b[p + 4:p + 4 + ext_len]
            if not _is_grease(ext_type):
                ext_list.append(str(ext_type))
            if ext_type == 0 and sni is None and len(ext_data) >= 5:  # server_name
                # SNI list: 2-byte len, 1-byte type(0=host), 2-byte len, name
                try:
                    sl = int.from_bytes(ext_data[0:2], "big")
                    if sl + 2 <= len(ext_data) and ext_data[2] == 0:
                        nl = int.from_bytes(ext_data[3:5], "big")
                        sni = ext_data[5:5 + nl].decode("ascii", "replace")
                except Exception:
                    pass
            elif ext_type == 10 and len(ext_data) >= 2:  # supported_groups
                gl = int.from_bytes(ext_data[0:2], "big")
                for i in range(2, min(2 + gl, len(ext_data)), 2):
                    g = int.from_bytes(ext_data[i:i + 2], "big")
                    if not _is_grease(g):
                        curves.append(str(g))
            elif ext_type == 11 and len(ext_data) >= 1:  # ec_point_formats
                pl = ext_data[0]
                for i in range(1, min(1 + pl, len(ext_data))):
                    ec_pf.append(str(ext_data[i]))
            p += 4 + ext_len
        ja3_str = ",".join([
            ja3_ver,
            "-".join(ciphers),
            "-".join(ext_list),
            "-".join(curves),
            "-".join(ec_pf),
        ])
        return hashlib.md5(ja3_str.encode()).hexdigest(), sni
    except Exception:
        return None, None


# ═══════════════════════════════════════════════════════════
# pcap → ClientHello 列表: (src_ip, src_port, ja3, sni)
# ═══════════════════════════════════════════════════════════
def extract_from_pcap(path, max_count=500):
    results = []
    seen = set()  # 同一 (src_ip:port) 只取第一个 ClientHello (重传去重)
    for linktype, _ts, data in _iter_pcap(path):
        ip = _strip_l2(linktype, data)
        if ip is None:
            continue
        src, src_port, payload = _parse_ip_tcp(ip)
        if payload is None or len(payload) < 6:
            continue
        if payload[0] != 0x16 or payload[5] != 0x01:
            continue
        key = (src, src_port)
        if key in seen:
            continue
        seen.add(key)
        ja3, sni = parse_clienthello(payload)
        if ja3:
            results.append((src, src_port, ja3, sni))
        if len(results) >= max_count:
            break
    return results


# ═══════════════════════════════════════════════════════════
# xray access.log → { "src_ip:src_port": email }
#   典型格式 (loglevel>=info, VLESS 用户认证后):
#     2026/07/08 16:00:00 from 1.2.3.4:5678 accepted tcp:google.com:443 email: foo@bar.com ...
#   也兼容无 email 的行 (探针/未认证), 这些不进字典.
# ═══════════════════════════════════════════════════════════
_FROM_RE = re.compile(r"from\s+([0-9a-fA-F:.]+):(\d+)\b")
_EMAIL_RE = re.compile(r"email:\s*(\S+)")


def parse_xray_accesslog(path, window_secs=300):
    """解析 xray access.log 最近 window_secs 秒内的 accepted 连接 → {ip:port: email}."""
    mapping = {}
    if not path or not os.path.isfile(path):
        return mapping
    try:
        # 只读尾部 256KB (足够覆盖几分钟的连接日志, 避免读全文件)
        with open(path, "rb") as f:
            try:
                f.seek(0, 2); size = f.tell()
                f.seek(max(0, size - 262144))
                data = f.read().decode("utf-8", "replace")
            except Exception:
                return mapping
    except Exception:
        return mapping
    now = datetime.now()
    cutoff = now - timedelta(seconds=window_secs)
    for line in data.splitlines():
        # 时间戳: "2026/07/08 16:00:00 ..."  (xray 本地时区)
        mts = re.match(r"(\d{4})/(\d{2})/(\d{2})\s+(\d{2}):(\d{2}):(\d{2})", line)
        if mts:
            try:
                ts = datetime(int(mts.group(1)), int(mts.group(2)), int(mts.group(3)),
                              int(mts.group(4)), int(mts.group(5)), int(mts.group(6)))
                if ts < cutoff:
                    continue
            except ValueError:
                pass
        if "accepted" not in line:
            continue
        mf = _FROM_RE.search(line)
        me = _EMAIL_RE.search(line)
        if mf and me:
            ip, port = mf.group(1), mf.group(2)
            # 跳过本机 (nginx 前置的 xhttp 场景, xray 看到的是 127.0.0.1, 无法关联真实用户)
            if ip in ("127.0.0.1", "::1"):
                continue
            mapping["%s:%s" % (ip, port)] = me.group(1)
    return mapping


# ═══════════════════════════════════════════════════════════
# 主: 关联 pcap ClientHello 与 xray 用户
# ═══════════════════════════════════════════════════════════
def hunt(pcap, accesslog, window_secs):
    chs = extract_from_pcap(pcap)
    users = parse_xray_accesslog(accesslog, window_secs)
    out = []
    for src_ip, src_port, ja3, sni in chs:
        user = users.get("%s:%s" % (src_ip, src_port), "")
        out.append("%s\t%s\t%s\t%s\t%s\t%s" % (
            ja3, user, src_ip, src_port, sni or "", "yes" if user else "no"))
    return out, len(chs), len(users)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        sys.exit(2)
    mode = sys.argv[1]
    if mode == "hunt":
        pcap = sys.argv[2]
        accesslog = sys.argv[3] if len(sys.argv) > 3 else "/var/log/xray/access.log"
        window = int(sys.argv[4]) if len(sys.argv) > 4 else 300
        out, nch, nu = hunt(pcap, accesslog, window)
        for line in out:
            sys.stdout.write(line + "\n")
        sys.stderr.write("[hunt] clienthellos=%d user_conn=%d matched_lines=%d\n" % (nch, nu, len(out)))
    elif mode == "ja3":
        for src_ip, src_port, ja3, sni in extract_from_pcap(sys.argv[2]):
            sys.stdout.write("%s\t%s\t%s\n" % (ja3, src_ip, sni or ""))
    elif mode == "watchlist":
        wl = [h.strip() for h in sys.argv[2].split(",") if h.strip()]
        for h in wl:
            ok = len(h) == 32 and all(c in "0123456789abcdef" for c in h.lower())
            sys.stdout.write("%s  %s\n" % (h, "OK" if ok else "BAD(需32位hex md5)"))
        sys.stdout.write("total %d hashes\n" % len(wl))
    else:
        sys.stderr.write("unknown mode: %s\n" % mode)
        sys.exit(2)


if __name__ == "__main__":
    main()
