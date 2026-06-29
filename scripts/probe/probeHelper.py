#!/usr/bin/env python3
"""probeHelper.py — 节点端 pcap ClientHello 提取器 (纯 Python, 无依赖)

用途: probeReporter.sh 调用, 从 tcpdump 抓的 pcap 中提取每个 TLS ClientHello
      的 (源IP, TLS record hex), 供上传给监控端算 JA3 + 判 CN.

设计:
  - 不依赖 tshark/scapy (瘦节点友好), 仅用标准库 struct 解析 pcap
  - 输出: 每行 "src_ip\trecord_hex" (record 从 0x16 handshake 开始)
  - 仅提取 ClientHello (handshake type == 1), 自动跳过 GREASE 噪声

用法:
  probeHelper.py parse <pcap_file> [max_count]
"""

import struct
import sys


def _iter_pcap(path):
    """迭代 pcap 文件中的每个包 → (linktype, raw_bytes)"""
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic == b"\xd4\xc3\xb2\xa1":
            endian = "<"; lt_off = 20
        elif magic == b"\xa1\xb2\xc3\xd4":
            endian = ">"; lt_off = 20
        elif magic == b"\x4d\x3c\xb2\xa1":
            endian = "<"; lt_off = 20  # nanosecond variant
        elif magic == b"\xa1\xb2\x3c\x4d":
            endian = ">"; lt_off = 20
        else:
            return  # 非 pcap
        gh = f.read(20)
        ver_major, ver_minor, _tz, _sig, _snap, linktype = struct.unpack(endian + "HHIIIi", gh)
        while True:
            hdr = f.read(16)
            if len(hdr) < 16:
                return
            _ts_s, _ts_us, incl_len, _orig_len = struct.unpack(endian + "IIII", hdr)
            data = f.read(incl_len)
            if len(data) < incl_len:
                return
            yield linktype, data


def _strip_l2(linktype, data):
    """剥离链路层, 返回 IP payload (或 None)"""
    # 1 = Ethernet (14 字节头), 101 = Raw IP, 113 = Linux SLL (16 字节头),
    # 12 = Raw IP (旧), 228 = Linux SLL2 (20 字节头)
    if linktype == 1:
        off = 14
        if len(data) < off + 1:
            return None
        # VLAN tag (0x8100) 处理
        if data[12:14] == b"\x81\x00":
            off = 18
        ip = data[off:]
    elif linktype in (101, 12):
        ip = data
    elif linktype == 113:
        ip = data[16:]
    elif linktype in (228, 276):
        ip = data[20:]
    else:
        return None
    if len(ip) < 1:
        return None
    return ip


def _parse_ip_tcp(ip):
    """解析 IPv4/IPv6 → (src_ip_str, tcp_payload_bytes or None)"""
    if len(ip) < 1:
        return None, None
    ver = ip[0] >> 4
    if ver == 4:
        if len(ip) < 20:
            return None, None
        ihl = (ip[0] & 0x0f) * 4
        proto = ip[9]
        if proto != 6:  # TCP
            return None, None
        src = ".".join(str(b) for b in ip[12:16])
        tcp = ip[ihl:]
    elif ver == 6:
        if len(ip) < 40:
            return None, None
        nxt = ip[6]
        if nxt != 6:
            return None, None
        src_bytes = ip[8:24]
        src = ":".join("%x" % int.from_bytes(src_bytes[i:i+2], "big") for i in range(0, 16, 2))
        tcp = ip[40:]
    else:
        return None, None
    if len(tcp) < 20:
        return None, None
    data_off = (tcp[12] >> 4) * 4
    return src, tcp[data_off:]


def extract_clienthellos(path, max_count=200):
    """提取 ClientHello → list of (src_ip, tls_record_hex)"""
    results = []
    for linktype, data in _iter_pcap(path):
        ip = _strip_l2(linktype, data)
        if ip is None:
            continue
        src, payload = _parse_ip_tcp(ip)
        if payload is None or len(payload) < 6:
            continue
        # TLS record: [0]=0x16 handshake, [1:3]=version, [3:5]=length
        # handshake: [5]=0x01 client_hello
        if payload[0] != 0x16:
            continue
        if payload[5] != 0x01:
            continue
        results.append((src, payload.hex()))
        if len(results) >= max_count:
            break
    return results


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "parse":
        sys.stderr.write("usage: probeHelper.py parse <pcap> [max_count]\n")
        sys.exit(2)
    path = sys.argv[2]
    max_count = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    chs = extract_clienthellos(path, max_count)
    out = []
    for src, hx in chs:
        out.append("%s\t%s" % (src, hx))
    sys.stdout.write("\n".join(out))
    if out:
        sys.stdout.write("\n")


if __name__ == "__main__":
    main()
