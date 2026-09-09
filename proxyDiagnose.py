#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
proxyDiagnose.py — 代理服务 (xray / nginx / 代理安装环境) 故障诊断脚本 (Python3 原生版)

由 proxyDiagnose.sh (POSIX sh, 1858 行) 移植而来, 行为/结果码/JSON schema/退出码兼容:
  · jq / GNU date / busybox-date 兼容层全部由 stdlib (json/datetime) 取代
  · HTTP (tcp.ping.pe / Telegram / 公网 IP 探测 api.ip.sb) 走 urllib, 不再依赖 curl
    (check_outbound 的 -4/-6 强制地址族探测仍借用 curl — urllib 无法强制 IPv4/IPv6)
  · 交叉验证临时监听改为进程内 daemon 线程 (原为 timeout+python3/socat 子进程)
  · 远程 --host 模式: ssh 推送自身到远端 `python3 -s -` 执行 (远端需 python3;
    本项目节点已视 python3 为标配 — nodeAgent/tcpingCheck 同依赖)

职责: 一键检查 xray / nginx / 代理无法【安装】或【运行】的各种可能原因。覆盖真实生产
故障场景, 包括但不限于:
  · 端口冲突 (nginx 与 xray 【同协议同端口】抢占 443/80; 注意 TCP/UDP 是两个独立
    命名空间, xray UDP:443 + nginx TCP:443 属正常共存非冲突 — 179.61.138.177 根因)
  · 配置 JSON 语法错误 / 二进制缺失 / 架构不匹配 / systemd mask / 重启风暴
  · TLS 证书缺失/过期/不可读; geo 数据缺失; OOM / 磁盘满 / 包锁
  · 系统时间不同步; 防火墙; DNS; 面板辅助脚本 0 字节空文件 (198.12.124.74 根因)
  · apt 仓库 Release 文件 Valid-Until 过期 → apt-get update 退出 100, 安装脚本 set -e
    直接中断 (103.227.224.98 根因: Debian 11 bullseye 于 2026-08-31 结束 LTS,
    security 套件冻结, Valid-Until=最后更新+7天 过后必然触发) — --fix 自动关闭
    Acquire::Check-Valid-Until 校验并 apt-get update 验证; 附带包锁残留自动解除
  · 出站 IPv4 web 端口被上游封锁但 freedom 强制 IPv4 → 代理"假活" (38.45.72.223 根因)
  · NODE_PORT 只 bind 127.0.0.1 → 本地"在监听"但外部不可达
  · NODE_PORT 大陆方向被墙 (借 tcp.ping.pe 三网+云厂探测点与海外对照逐网判定,
    检出封锁时随机开临时端口交叉验证 端口级/IP级)
  · conntrack 表打满 → 丢包 → 内存耗尽硬死锁 (103.173.155.212 根因; 常因 sysctl
    空值坏行静默失效回退默认 8192)
  · 本周期出站流量 (vnstat tx × NODE_TRAFFIC_RESETDAY, 配 LIMIT 时限额提醒)

设计原则:
  1. 默认只读诊断, 绝不修改系统 (只查询 + 报告); --fix 显式开启自动修复, 仅限两类
     低风险项 (apt/dpkg 锁解除 + 仓库有效期校验关闭), 每个修复动作以 WARN 结果呈现
  2. 每项检查独立 — 单个检查内部异常被捕获为 INTERNAL_* 结果, 绝不中断其它检查
  3. 输出三级结论: PASS(正常) / WARN(潜在风险) / FAIL(直接故障原因)
  4. --json 机器可读输出, 供面板/nodeAgent 调用

用法:
  python3 proxyDiagnose.py                      # 全量检查
  python3 proxyDiagnose.py --target xray|nginx|env|net|cert|outbound|traffic
  python3 proxyDiagnose.py --json               # 输出 JSON (供程序解析)
  python3 proxyDiagnose.py --no-notify          # 抑制 Telegram 推送 (程序化调度用)
  python3 proxyDiagnose.py --fix                # 自动修复: 解除 apt/dpkg 残留包锁 +
                                                #   关闭过期仓库有效期校验 (修复动作报 WARN)
  python3 proxyDiagnose.py --quiet              # 只输出 FAIL/WARN
  python3 proxyDiagnose.py --no-color           # 关闭颜色
  python3 proxyDiagnose.py --host root@1.2.3.4  # 远程诊断 (ssh 推送自身, 远端需 python3)
  NODE_TARGET_IP=5.6.7.8 NODE_PORT=443 python3 proxyDiagnose.py --target net
                                                # 在第三方服务器上远测别的节点是否被墙

退出码: 失败项数 (上限 99), 0 = 全部通过
"""

import calendar
import datetime
import email.utils
import fnmatch
import glob
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from collections import defaultdict

try:
    __file__
    SCRIPT_PATH = os.path.abspath(__file__)
except NameError:  # 远程 stdin 执行 (`python3 -s -`) 时无 __file__
    SCRIPT_PATH = ''
SCRIPT_NAME = os.path.basename(SCRIPT_PATH) if SCRIPT_PATH else 'proxyDiagnose.py'
HOME = os.path.expanduser('~')

USAGE = """\
用法:
  python3 proxyDiagnose.py                      # 全量检查 (xray + nginx + 环境 + 网络)
  python3 proxyDiagnose.py --target xray        # 只查 xray
  python3 proxyDiagnose.py --target nginx       # 只查 nginx
  python3 proxyDiagnose.py --target env         # 只查安装环境 (磁盘/内存/DNS/依赖/锁)
  python3 proxyDiagnose.py --target net         # 只查网络与防火墙 (含 NODE_PORT 对外可达性
                                                #   + 大陆 tcping 被墙检测, 检出封锁时随机开
                                                #   临时端口交叉验证 端口级/IP级)
  python3 proxyDiagnose.py --target cert        # 只查 TLS 证书
  python3 proxyDiagnose.py --target outbound    # 只查出站连通性 (IPv4/IPv6 web)
  python3 proxyDiagnose.py --target traffic     # 只查本周期流量 (vnstat tx)
  python3 proxyDiagnose.py --json               # 输出 JSON (供程序解析)
  python3 proxyDiagnose.py --no-notify          # 抑制 Telegram 推送
  python3 proxyDiagnose.py --fix                # 自动修复 (apt/dpkg 锁 + 仓库有效期校验)
  python3 proxyDiagnose.py --quiet              # 只输出 FAIL/WARN, 不输出 PASS
  python3 proxyDiagnose.py --no-color           # 关闭颜色
  python3 proxyDiagnose.py --host root@1.2.3.4  # 远程诊断 (ssh 执行, 远端需 python3)
  NODE_TARGET_IP=5.6.7.8 NODE_PORT=443 python3 proxyDiagnose.py --target net
                                                # 在任意第三方服务器上远程测别的节点是否被墙
                                                #   (探测由 ping.pe 代测, 与运行位置无关)

退出码: 失败项数 (上限 99), 0 = 全部通过\
"""

VALID_TARGETS = ('all', 'xray', 'nginx', 'env', 'net', 'cert', 'outbound', 'traffic')

# ============================================================
# 配置加载 — 兼容 ~/.env / ~/node.env / ./.env (顺序与 source 语义一致, 后者覆盖)
#   显式 KEY=VALUE 解析 (非 shell source): 不执行任意代码, 更安全;
#   面板写入的均为纯值行, 语义等价。
# ============================================================
ENV = dict(os.environ)


def _apply_env_file(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith('#'):
                    continue
                m = re.match(r"(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", line)
                if not m:
                    continue
                key, val = m.group(1), m.group(2).strip()
                if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                    val = val[1:-1]
                ENV[key] = val
    except OSError:
        pass


for _env_path in (os.path.join(HOME, '.env'), os.path.join(HOME, 'node.env'),
                  os.path.join(os.getcwd(), '.env')):
    if os.path.isfile(_env_path):
        _apply_env_file(_env_path)

XRAY_BIN = ENV.get('XRAY_BIN') or '/usr/local/bin/xray'
XRAY_CONF = ENV.get('XRAY_CONF') or '/usr/local/etc/xray/config.json'
XRAY_DIR = os.path.dirname(XRAY_CONF)
NGINX_CONF_DIR = ENV.get('NGINX_CONF_DIR') or '/etc/nginx'

# ============================================================
# 命令行参数解析 (与 sh 版一致; --target 白名单在远程分支之前校验,
# 防止未校验值拼入远程命令串 — 注入面)
# ============================================================
TARGET = 'all'
JSON_OUTPUT = False
QUIET = False
USE_COLOR = True
REMOTE_HOST = ''
NO_NOTIFY = False
FIX = False  # --fix: 显式开启自动修复 (默认只读, 见设计原则 1)

_args = sys.argv[1:]
_i = 0
while _i < len(_args):
    _a = _args[_i]
    if _a in ('--target', '--host'):
        if _i + 1 >= len(_args):
            print(f"参数 {_a} 缺少值 (用 --help 查看用法)", file=sys.stderr)
            sys.exit(2)
        if _a == '--target':
            TARGET = _args[_i + 1]
        else:
            REMOTE_HOST = _args[_i + 1]
        _i += 2
    elif _a == '--json':
        JSON_OUTPUT = True
        USE_COLOR = False
        _i += 1
    elif _a == '--no-notify':
        NO_NOTIFY = True
        _i += 1
    elif _a == '--fix':
        FIX = True
        _i += 1
    elif _a == '--quiet':
        QUIET = True
        _i += 1
    elif _a == '--no-color':
        USE_COLOR = False
        _i += 1
    elif _a in ('-h', '--help'):
        print(USAGE)
        sys.exit(0)
    else:
        print(f"未知参数: {_a} (用 --help 查看用法)", file=sys.stderr)
        sys.exit(2)

if TARGET not in VALID_TARGETS:
    print(f"未知 --target: {TARGET} (可选: {'|'.join(VALID_TARGETS)})", file=sys.stderr)
    sys.exit(2)

# ============================================================
# 远程模式: 把自身推送到远程主机执行 (远端需 python3; 无需预装本脚本)
#   StrictHostKeyChecking=accept-new (OpenSSH>=7.6): 首连记录主机密钥、指纹变化即拒绝 —
#   比 =no 抗 DNS 劫持/中间人。老版 OpenSSH 不识别 accept-new 时 DIAG_SSH_STRICT=no 回退。
#   --no-notify 必须转发: 避免远端与调用方双重 TG 告警。
#   (TARGET 已过白名单校验, 单引号包裹传递为纵深防御)
# ============================================================
if REMOTE_HOST:
    _flags = ''
    if JSON_OUTPUT:
        _flags += ' --json'
    if QUIET:
        _flags += ' --quiet'
    if NO_NOTIFY:
        _flags += ' --no-notify'
    if FIX:
        _flags += ' --fix'
    _remote_cmd = f"python3 -s - --target '{TARGET}'{_flags}"
    _strict = ENV.get('DIAG_SSH_STRICT') or 'accept-new'
    try:
        with open(SCRIPT_PATH, 'rb') as _self:
            _proc = subprocess.run(
                ['ssh', '-o', f'StrictHostKeyChecking={_strict}',
                 '-o', 'ConnectTimeout=10', REMOTE_HOST, _remote_cmd],
                stdin=_self)
        sys.exit(_proc.returncode)
    except OSError as _e:
        print(f"ssh 执行失败: {_e}", file=sys.stderr)
        sys.exit(1)

# ============================================================
# 输出系统 — 三级 PASS/WARN/FAIL, 逐项累计, 汇总 + JSON
# ============================================================
_counts = {'PASS': 0, 'WARN': 0, 'FAIL': 0}
RESULTS = []  # [{level, code, title, detail}] — 供 JSON 汇总 (与 sh 版 TSV 等价)

if USE_COLOR and sys.stdout.isatty():
    C_RED, C_YELLOW, C_GREEN = '\033[31m', '\033[33m', '\033[32m'
    C_CYAN, C_DIM, C_BOLD, C_RESET = '\033[36m', '\033[2m', '\033[1m', '\033[0m'
else:
    C_RED = C_YELLOW = C_GREEN = C_CYAN = C_DIM = C_BOLD = C_RESET = ''

try:  # ssh/管道下保持行缓冲, 实时输出 (等价 sh 的无缓冲 printf)
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass


def result(level, code, title, detail=''):
    """记录并实时输出单项结果 (与 sh 版 result() 等价; detail 换行/Tab 折叠为空格)"""
    if isinstance(detail, (list, tuple)):
        detail = ' '.join(str(x) for x in detail)
    detail = str(detail).replace('\n', ' ').replace('\t', ' ').strip()
    _counts[level] += 1
    RESULTS.append({'level': level, 'code': code, 'title': title, 'detail': detail})
    if QUIET and level == 'PASS':
        return
    if not JSON_OUTPUT:
        _c, _mark = {
            'PASS': (C_GREEN, '✅'),
            'WARN': (C_YELLOW, '⚠️ '),
            'FAIL': (C_RED, '❌'),
        }[level]
        print(f"{_c}[{level}] {_mark} {title}{C_RESET}")
        if detail:
            print(f"{C_DIM}    └ {detail}{C_RESET}")


def say(header):
    """非结果性的说明性分节输出 (JSON 模式抑制)"""
    if not JSON_OUTPUT:
        print(f"\n{C_BOLD}{C_CYAN}=== {header} ==={C_RESET}")


def note(text):
    """附注行 (仅文本模式)"""
    if not JSON_OUTPUT:
        print(f"{C_DIM}    └ {text}{C_RESET}")


# ============================================================
# 通用工具
# ============================================================
def has(cmd):
    return shutil.which(cmd) is not None


def to_int(v, d=0):
    """安全取整 (等价 sh 版 _num: 非法/空 → 默认值)"""
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return d


def run(cmd, timeout=90):
    """运行外部命令; 返回 (rc, stdout, stderr), 任何失败都不抛异常"""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           errors='replace', timeout=timeout)
        return p.returncode, p.stdout or '', p.stderr or ''
    except FileNotFoundError:
        return 127, '', ''
    except Exception:
        return 1, '', ''


def run_out(cmd, timeout=90):
    return run(cmd, timeout=timeout)[1]


def run_all(cmd, timeout=90):
    """stdout+stderr 合并输出 (等价 sh 的 2>&1 捕获)"""
    rc, out, err = run(cmd, timeout=timeout)
    return (out + '\n' + err) if (out and err) else (out or err)


def load_json_file(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            return json.load(fh)
    except Exception:
        return None


def env_file_read(path, key):
    """读 env 文件中该 key 【最后一行】的值 (面板会追加同名行, 后写覆盖先写);
    值内所有引号/空白移除 (等价原 sed 's/[\"'\''[:space:]]//g')"""
    val = ''
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            for raw in fh:
                if re.match(rf'^\s*{re.escape(key)}\s*=', raw):
                    val = raw.split('=', 1)[1]
    except OSError:
        return ''
    return re.sub(r'''["'\s]''', '', val)


def find_files(root, patterns, maxdepth=3):
    """等价 find <root> -maxdepth N -type f -name ... (多 pattern)"""
    out = []
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        return out
    for dirpath, dirnames, filenames in os.walk(root):
        depth = dirpath[len(root):].count(os.sep)
        if depth >= maxdepth:
            dirnames[:] = []
        for fn in sorted(filenames):
            if any(fnmatch.fnmatch(fn, p) for p in patterns):
                out.append(os.path.join(dirpath, fn))
    return sorted(out)


def host_ips():
    return run_out(['hostname', '-I']).strip()


def host_ip_first():
    ip = host_ips().split()[0] if host_ips() else ''
    if not ip:
        rc, out, _ = run(['hostname'])
        ip = out.strip()
    return ip


def ss_lines(flags=('-H', '-tulnp')):
    out = run_out(['ss', *flags])
    return out.splitlines() if out else []


def port_listening(port, tcp_only=False):
    """端口是否在监听 (锚定 [:.]PORT([^0-9]|$), 防 :443 误匹 :4430 / IPv6 地址段;
    正则锚定替代 GNU grep \b — 跨实现一致)"""
    flags = ('-H', '-tlnp') if tcp_only else ('-H', '-tulnp')
    pat = re.compile(rf'[:.]{re.escape(str(port))}([^0-9]|$)')
    return any(pat.search(l) for l in ss_lines(flags))


# ============================================================
# NODE_PORT 解析 (代理对外端口, 默认 443; 与 proxyInstall.sh 同源)
#   优先级: NODE_PORT 变量 (环境/已加载 env 文件) > ~/node.json node_port
#           > ~/node.env node_port > 默认 443
# ============================================================
_node_port_cache = None


def resolve_node_port():
    global _node_port_cache
    if _node_port_cache is not None:
        return _node_port_cache
    v = (ENV.get('NODE_PORT') or '').strip()
    if v:
        _node_port_cache = v
        return v
    nj = load_json_file(os.path.join(HOME, 'node.json'))
    if isinstance(nj, dict):
        jp = nj.get('node_port')
        if jp not in (None, False, ''):
            _node_port_cache = str(jp)
            return _node_port_cache
    ep = env_file_read(os.path.join(HOME, 'node.env'), 'node_port')
    if ep:
        _node_port_cache = ep
        return ep
    _node_port_cache = '443'
    return '443'


# ============================================================
# HTTP 原生封装 (urllib) — tcp.ping.pe / Telegram / 公网 IP 探测共用;
#   失败返回 '' (等价 curl 2>/dev/null), 跳转自动跟随 (等价 -L)
# ============================================================
def http_get(url, headers=None, timeout=20):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode('utf-8', 'replace')
    except Exception:
        return ''


def http_post_form(url, data, headers=None, timeout=20):
    body = urllib.parse.urlencode(data).encode('utf-8')
    h = {'Content-Type': 'application/x-www-form-urlencoded'}
    h.update(headers or {})
    req = urllib.request.Request(url, data=body, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode('utf-8', 'replace')
    except Exception:
        return ''


# ============================================================
# Telegram 通知 — 仅 FAIL 时推送; --no-notify 全部抑制 (供 nodeAgent 等
#   程序化调度使用, 由调用方按自身语义组织通知, 避免双重告警)
# ============================================================
def _tg_creds():
    token = ENV.get('TELEGRAM_BOT_TOKEN') or ENV.get('TG_BOT_TOKEN') or ''
    chat = ENV.get('TELEGRAM_CHAT_ID') or ENV.get('TG_CHAT_ID') or ''
    return token, chat


def tg_send(text):
    if NO_NOTIFY:
        return
    token, chat = _tg_creds()
    if not token or not chat:
        return
    http_post_form(f'https://api.telegram.org/bot{token}/sendMessage',
                   {'chat_id': chat, 'text': text}, timeout=15)


def notify_tg():
    if NO_NOTIFY or _counts['FAIL'] == 0:
        return
    fails = [r['title'] for r in RESULTS if r['level'] == 'FAIL'][:8]
    bullets = '\n'.join(f"• {t}" for t in fails)
    tg_send(f"""🚨 [NodeHub] {SCRIPT_NAME} 诊断告警
主机: {host_ip_first()}
失败 {_counts['FAIL']} 项 / 警告 {_counts['WARN']} 项
{bullets}""")


# ============================================================
# apt 包锁 / 仓库有效期 — 自动修复辅助 (仅 --fix 时调用; 默认只读)
#   背景: Debian 11 bullseye 于 2026-08-31 结束 LTS, security.debian.org 套件
#   冻结不再更新, Release 的 Valid-Until (最后更新+7天) 过期后 apt-get update
#   直接报 'E: Release file ... is expired' 退出 100 → 安装脚本 set -e 中断
#   (103.227.224.98 实测根因)。archive.debian.org 归档放出前无源可换,
#   唯一出路 = 关闭 Acquire::Check-Valid-Until 校验 (修复动作以 WARN 提示)。
# ============================================================
VALID_UNTIL_CONF = '/etc/apt/apt.conf.d/99check-valid-until'


def apt_expired_repos():
    """扫描 /var/lib/apt/lists 已缓存的 InRelease/Release, 找出 Valid-Until 已过期的仓库。
    判定与 apt 自身一致 (本地时间 vs Valid-Until), 纯只读不联网。
    返回 [(仓库名, Valid-Until 原文)], 空列表 = 无过期/无法判定"""
    expired = []
    now = datetime.datetime.now(datetime.timezone.utc)
    for f in (glob.glob('/var/lib/apt/lists/*_InRelease')
              + glob.glob('/var/lib/apt/lists/*_Release')):
        vu = ''
        try:
            with open(f, 'r', encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    if line.startswith('Valid-Until:'):
                        vu = line.split(':', 1)[1].strip()
                        break
        except OSError:
            continue
        if not vu:
            continue
        try:
            dt = email.utils.parsedate_to_datetime(vu)  # RFC 1123 (apt Release 日期格式)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
            if dt >= now:
                continue
        except (TypeError, ValueError):
            continue
        base = os.path.basename(f)
        for suf in ('_InRelease', '_Release'):
            if base.endswith(suf):
                base = base[:-len(suf)]
                break
        # security.debian.org_debian-security_dists_bullseye-security →
        # security.debian.org/debian-security/bullseye-security
        expired.append((base.replace('_dists_', '/').replace('_', '/'), vu))
    return expired


def fix_apt_valid_until():
    """写 Acquire::Check-Valid-Until=false 并以 apt-get update 验证。返回 (ok, 说明)。"""
    already = False
    try:
        with open(VALID_UNTIL_CONF, 'r', encoding='utf-8', errors='replace') as fh:
            already = 'Check-Valid-Until' in fh.read()
    except OSError:
        pass
    if not already:
        try:
            with open(VALID_UNTIL_CONF, 'w', encoding='utf-8') as fh:
                fh.write('Acquire::Check-Valid-Until "false";\n')
        except OSError as e:
            return False, f'写入 {VALID_UNTIL_CONF} 失败: {e} (需要 root)'
    rc, _, err = run(['apt-get', 'update'], timeout=300)
    if rc == 0:
        return True, ('配置已存在, ' if already else '') + VALID_UNTIL_CONF
    tail = ' '.join(err.split())[:160] or f'apt-get update 退出码 {rc}'
    return False, f'写入配置后 apt-get update 仍失败 (退出码 {rc}): {tail}'


def fix_apt_locks(locks):
    """解除 apt/dpkg 包锁 (与 proxyInstall.sh WaitForAptLock 同策略):
    停 unattended-upgrades → SIGKILL 残余持锁进程 → 删锁文件 → dpkg --configure -a。
    返回 (ok, 说明)。"""
    pids = []
    for line in run_out(['ps', 'aux']).splitlines():
        if 'grep' in line or SCRIPT_NAME in line:
            continue
        if re.search(r'(unattended-upgr|apt-get|apt |dpkg)', line):
            parts = line.split()
            if len(parts) > 10:
                pids.append((parts[1], ' '.join(parts[10:])))
    if pids:
        # 常驻自动升级 (unattended-upgrades) 是锁的主要来源, 先停服务防杀后复活
        run(['systemctl', 'stop', 'unattended-upgrades'])
        for pid, cmd in pids:
            note(f'终止持锁进程 pid={pid} ({cmd[:70]})')
            run(['kill', '-9', pid])
        time.sleep(1)
    for lock in locks:
        try:
            os.remove(lock)
        except OSError:
            pass
    rc, _, _err = run(['dpkg', '--configure', '-a'], timeout=300)
    still = [lk for lk in locks if os.path.exists(lk) and has('fuser')
             and run(['fuser', lk])[0] == 0]
    if still:
        return False, '锁仍被占用: ' + ' '.join(still)
    if rc != 0:
        return False, f'dpkg --configure -a 退出码 {rc}, 存在半完成的包配置, 需人工检查'
    return True, f'终止 {len(pids)} 个持锁进程, 解除 {len(locks)} 把锁'


# ============================================================
# 基础环境检查 (env) — 影响安装能否成功
# ============================================================
def check_env():
    say('基础环境 (磁盘 / 内存 / 时间 / DNS / 包锁 / 仓库 / 依赖)')

    # E1. 磁盘空间 — 根分区使用率
    root_use = 0
    lines = run_out(['df', '-P', '/']).splitlines()
    if len(lines) >= 2 and len(lines[1].split()) >= 5:
        root_use = to_int(lines[1].split()[4].rstrip('%'), 0)
    if root_use >= 95:
        result('FAIL', 'ENV_DISK_FULL', f'根分区已使用 {root_use}% (≥95%)',
               '磁盘满会导致: 写不了日志/临时文件/证书, 安装中断, 服务启动失败。清理: apt clean / 删旧日志 / du -sh /* | sort -h')
    elif root_use >= 85:
        result('WARN', 'ENV_DISK_HIGH', f'根分区已使用 {root_use}% (≥85%)', '建议清理, 逼近 95% 将影响服务')
    else:
        result('PASS', 'ENV_DISK_OK', f'根分区使用率 {root_use}%')

    # E2. 内存 — free -m (available / swap free)
    mem, swap = 0, 0
    for line in run_out(['free', '-m']).splitlines():
        parts = line.split()
        if line.startswith('Mem:') and len(parts) > 6:
            mem = to_int(parts[6], 0)
        elif line.startswith('Swap:') and len(parts) > 3:
            swap = to_int(parts[3], 0)
    if mem < 50 and swap < 50:
        result('FAIL', 'ENV_OOM_RISK', f'可用内存 {mem}MB + swap {swap}MB 严重不足 (<50MB)',
               "极易触发 OOM Killer 杀掉 xray/nginx。检查: dmesg | grep -i 'killed process'")
    elif mem < 128:
        result('WARN', 'ENV_MEM_LOW', f'可用内存仅 {mem}MB', '高峰期可能 OOM, 建议加 swap')
    else:
        result('PASS', 'ENV_MEM_OK', f'可用内存 {mem}MB / swap {swap}MB')

    # E3. 系统时间同步 (TLS 握手关键依赖, 时钟偏差>5min 会握手失败)
    if has('timedatectl'):
        sync = run_out(['timedatectl', 'show', '-p', 'NTPSynchronized', '--value']).strip()
        ts_out = run_out(['timedatectl', 'timesync-status'])
        m = re.search(r'Offset=\s*([0-9.\-]+)', ts_out)
        offset = to_int((m.group(1) if m else '').split('.')[0], 0)
        if sync in ('no', ''):
            result('WARN', 'ENV_TIME_NOSYNC', f'NTP 未同步 (NTPSynchronized={sync})',
                   '时钟偏差过大会导致: TLS 握手失败 (cert not yet valid/expired), 证书校验异常。修复: systemctl enable --now systemd-timesyncd')
        elif abs(offset) > 300:
            result('FAIL', 'ENV_TIME_SKEW', f'系统时间偏差约 {offset}秒 (绝对值>300s)',
                   'TLS 会因证书时间校验失败而无法握手')
        else:
            result('PASS', 'ENV_TIME_OK', f'NTP 已同步, 偏差约 {offset}s')
    else:
        result('WARN', 'ENV_TIME_UNKNOWN', '无 timedatectl, 无法确认时间同步状态', '请手动确认 date 输出是否准确')

    # E4. DNS 解析 — 能否解析公共域名 (装包/下载二进制前提)
    if has('getent'):
        rc, _, _ = run(['getent', 'hosts', 'github.com'])
        if rc == 0:
            result('PASS', 'ENV_DNS_OK', 'DNS 解析正常 (github.com 可解析)')
        else:
            result('FAIL', 'ENV_DNS_FAIL', 'DNS 解析失败 (getent hosts github.com 失败)',
                   '会导致 apt/yum 装包失败, xray 二进制下载失败。检查: /etc/resolv.conf 是否有 nameserver')
    else:
        result('WARN', 'ENV_DNS_UNKNOWN', '无 getent, 跳过 DNS 检测')

    # E5. 包管理器锁占用 — apt/dpkg 正在被占用会卡住安装
    #     --fix: 沿用 proxyInstall.sh WaitForAptLock 策略自动解除, 修复动作以 WARN 呈现
    if has('fuser'):
        locks = []
        for lock in ('/var/lib/dpkg/lock-frontend', '/var/lib/apt/lists/lock',
                     '/var/cache/apt/archives/lock', '/var/run/yum.pid'):
            if os.path.exists(lock):
                rc, _, _ = run(['fuser', lock])
                if rc == 0:
                    locks.append(lock)
        if locks:
            if FIX:
                ok, msg = fix_apt_locks(locks)
                if ok:
                    result('WARN', 'ENV_PKG_LOCK_FIXED',
                           f'包管理器锁被占用, 已自动解除 ({msg}): ' + ' '.join(locks),
                           '修复动作: 停 unattended-upgrades → 终止持锁 apt/dpkg 进程 → 删锁文件 → dpkg --configure -a。若锁属于一个仍在进行的真实安装, 请重跑该安装')
                else:
                    result('WARN', 'ENV_PKG_LOCK',
                           f'包管理器锁被占用, --fix 自动解除未成功 ({msg})',
                           '人工处理: ps aux | grep -E "apt|dpkg" 找到卡死进程, 终止后 rm 锁文件并 dpkg --configure -a')
            else:
                result('WARN', 'ENV_PKG_LOCK', '包管理器锁被占用: ' + ' '.join(locks),
                       '可能有 apt/dpkg 正在运行; 若确认卡死: 加 --fix 自动解除, 或手动 rm 锁文件并 dpkg --configure -a')
        else:
            result('PASS', 'ENV_PKG_LOCK_OK', '包管理器锁空闲')

    # E10. apt 仓库 Release 有效期 — Valid-Until 过期 → apt-get update 必失败 (退出 100),
    #      安装脚本 set -e 直接中断。真实故障 (2026-09-09, 103.227.224.98):
    #      Debian 11 bullseye 于 2026-08-31 结束 LTS, security 套件冻结,
    #      InRelease Valid-Until=2026-09-07 一过 apt 即报 'Release file ... is expired'。
    #      --fix: 写 Acquire::Check-Valid-Until=false 并 apt-get update 验证。
    _lists = '/var/lib/apt/lists'
    _has_lists = os.path.isdir(_lists) and (
        glob.glob(os.path.join(_lists, '*_InRelease'))
        or glob.glob(os.path.join(_lists, '*_Release')))
    if has('apt-get') and _has_lists:
        expired = apt_expired_repos()
        if expired:
            names = '; '.join(f'{r} (Valid-Until: {v})' for r, v in expired)
            if FIX:
                ok, msg = fix_apt_valid_until()
                if ok:
                    result('WARN', 'ENV_REPO_EXPIRED_FIXED',
                           f'apt 仓库 Release 已过期, 已自动关闭有效期校验: {names}',
                           f'⚠️ 过期根因是该仓库已停止更新 (OS 停止安全维护), 本修复仅恢复安装能力, 不恢复安全更新。已写入/确认 {VALID_UNTIL_CONF} 并 apt-get update 验证通过')
                else:
                    result('FAIL', 'ENV_REPO_EXPIRED_FIX_FAILED',
                           f'apt 仓库 Release 过期, --fix 自动修复未成功: {names}', msg)
            else:
                result('FAIL', 'ENV_REPO_EXPIRED',
                       f'apt 仓库 Release 已过期 (apt-get update 必报 expired 退出 100): {names}',
                       '修复: printf \'Acquire::Check-Valid-Until "false";\\n\' > /etc/apt/apt.conf.d/99check-valid-until 后重试安装; 或直接加 --fix 自动修复并验证')
        else:
            result('PASS', 'ENV_REPO_FRESH', 'apt 仓库 Release 有效期正常 (无过期仓库)')
    else:
        note('E10 跳过: 无 apt-get 或本地无仓库索引 (未跑过 apt update), 无法静态判断 Release 有效期')

    # E11. OS 生命周期 — Debian 10/11 已停止 (LTS) 安全支持, 是 E10 仓库过期的根因。
    #      检测只提示不修复 (升级 OS 超出诊断脚本职责), 但给出明确路径。
    _deb_ver = ''
    try:
        with open('/etc/debian_version', 'r', encoding='utf-8', errors='replace') as fh:
            _deb_ver = fh.read().strip()
    except OSError:
        pass
    _major = to_int(re.split(r'[./]', _deb_ver)[0] if _deb_ver else '', 0)
    if _major in (10, 11):
        _codename = {10: 'buster', 11: 'bullseye'}.get(_major, '')
        result('WARN', 'ENV_OS_EOL',
               f'Debian {_major} ({_codename}) 已结束生命周期 (含 LTS), 不再有任何安全更新',
               f'当前版本 {_deb_ver}: security 仓库已冻结 (Release 过期后 apt 持续报 expired, 见 E10); 短期: --fix 关闭有效期校验维持安装能力; 长期: 升级 Debian 12 (bookworm)')
    elif _major >= 12:
        result('PASS', 'ENV_OS_OK', f'Debian {_deb_ver} 仍在官方支持期内')

    # E6. 关键依赖 — 代理安装/运维脚本常用工具
    #   (jq 为 nodeAgent/proxyInstall 等脚本所需; 本脚本自身已用原生 json 解析)
    missing = [t for t in ('curl', 'wget', 'unzip', 'tar', 'jq') if not has(t)]
    if missing:
        result('WARN', 'ENV_DEPS_MISSING', '缺少依赖工具: ' + ' '.join(missing),
               f"安装/运维脚本可能依赖这些工具; 缺 jq 会影响 nodeAgent/proxyInstall 解析 JSON 配置。修复: apt install -y {' '.join(missing)}")
    else:
        result('PASS', 'ENV_DEPS_OK', '关键依赖 (curl/wget/unzip/tar/jq) 齐全')

    # E7. 架构识别 — 防止下错二进制 (exec format error)
    arch = platform.machine()
    if arch in ('x86_64', 'amd64'):
        result('PASS', 'ENV_ARCH_OK', f'CPU 架构: {arch} (x86_64)')
    elif arch in ('aarch64', 'arm64'):
        result('PASS', 'ENV_ARCH_OK', f'CPU 架构: {arch} (arm64)')
    else:
        result('WARN', 'ENV_ARCH_UNK', f'CPU 架构: {arch} (非主流 x86/arm)',
               "确认安装脚本下载了对应架构的二进制, 否则启动报 'exec format error'")

    # E8. 面板辅助脚本完整性 — 0 字节空文件让 source 静默成功但函数未定义
    #   真实故障 (2026-08-05, 198.12.124.74): /root/panels/panel-common.sh 等为 0 字节
    #   (失败下载 wget -O 残留), install 用 [ -f ] 只判存在误判"已存在"跳过重下 →
    #   source 空文件成功但 DetectTransportMode 未定义 → set -u 崩溃
    #   ("_TRANSPORT_MODE: parameter not set" 退出码 2)。
    #   教训: 判"文件可用"必须用非空而非存在。
    panel_found = ''
    for d in (os.path.join(HOME, 'panels'), '/tmp/panels', '/root/panels'):
        if os.path.isdir(d):
            panel_found = d
            break
    if panel_found:
        empty_p, ok_p = [], []
        for fn in ('panel-common.sh', 'panel-1panel.sh', 'panel-btpanel.sh'):
            p = os.path.join(panel_found, fn)
            if os.path.exists(p):
                if os.path.getsize(p) == 0:
                    empty_p.append(p)
                else:
                    ok_p.append(fn)
        if empty_p:
            result('FAIL', 'ENV_PANEL_SCRIPT_EMPTY',
                   '面板辅助脚本为 0 字节空文件: ' + ' '.join(empty_p),
                   "空文件让安装脚本 source 静默成功但【不定义任何函数】(如 DetectTransportMode), 后续 set -u 访问未赋值变量直接退出 (典型报错 '_TRANSPORT_MODE: parameter not set' 退出码 2)。成因: 历史失败下载 wget -O 残留 0 字节文件, install 用 [ -f ] 只判存在误判'已存在'而跳过重下。修复: rm -f "
                   + ' '.join(empty_p) + ' 后重跑安装 (会从 NODEHUB_URL 重新下载真实文件)')
        elif ok_p:
            result('PASS', 'ENV_PANEL_SCRIPT_OK',
                   f'面板辅助脚本完整 ({panel_found}): ' + ' '.join(ok_p))

    # E9. 小内存代理节点无 swap — 把"可恢复的 OOM"恶化为"整机硬死锁"
    #   真实故障 (2026-08-08, 103.173.155.212): 1核1GB 无 swap, conntrack 打满引发
    #   内存耗尽时内核来不及 OOM-kill/写日志 → 整机硬挂 (宕机 10h 才人工重启)。
    has_xray = (os.path.exists(XRAY_BIN) and os.access(XRAY_BIN, os.X_OK)) \
        or os.path.isfile('/etc/systemd/system/xray.service') \
        or os.path.isfile('/lib/systemd/system/xray.service')
    if has_xray:
        tot_mb = 0
        try:
            with open('/proc/meminfo', 'r', errors='replace') as fh:
                for line in fh:
                    if line.startswith('MemTotal:'):
                        # 同 awk printf "%d": 截断取整 (KB→MB)
                        tot_mb = int(int(line.split()[1]) / 1024)
                        break
        except (OSError, ValueError, IndexError):
            pass
        swap_tot = 0
        for line in run_out(['free', '-m']).splitlines():
            parts = line.split()
            if line.startswith('Swap:') and len(parts) > 1:
                swap_tot = to_int(parts[1], 0)  # Swap 行第 2 列 = 总量
        if 0 < tot_mb < 2048 and swap_tot == 0:
            result('WARN', 'ENV_NO_SWAP_PROXY', f'代理节点内存 {tot_mb}MB 且【无 swap】',
                   "小内存代理节点无 swap 时, 内存尖峰(conntrack 打满/连接暴增)会从 'OOM-kill 自愈' 恶化为 '整机硬死锁'(本次 103.173.155.212 死机的放大器: 宕机 10h)。修复: fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile, 并写入 /etc/fstab (proxyInstall.sh 的 TuneKernelForProxy 已对小节点自动处理)")
        else:
            result('PASS', 'ENV_SWAP_OK', f'内存 {tot_mb}MB / swap {swap_tot}MB')


# ============================================================
# 端口声明与冲突检测 (核心: nginx ↔ xray 抢占; 协议感知)
#
# 关键认知: "端口号"不是端口的唯一身份 —— (协议, 端口) 才是。TCP 与 UDP 是两个
#   独立命名空间: TCP:443 与 UDP:443 可同时被不同进程监听互不冲突 (典型: nginx
#   listen 443 ssl (TCP) + xray hysteria (UDP) 同处 443 = 正常共存)。
#   真冲突 = 双方【同协议同端口】声明; 再按当前谁实际占用细分 4 类根因。
# ============================================================
def xray_declared_proto_ports():
    """xray 声明的 (协议, 端口) 集合 (原生 json 解析, 替代 jq)。
    协议判定: protocol ∈ {hysteria,hysteria2,tuic} 或 network ∈ {kcp,quic} → UDP;
    其余 (vless/vmess/trojan/shadowsocks/dokodemo) → TCP。port 仅取纯数字 (丢弃范围)。"""
    if not os.path.isfile(XRAY_CONF):
        return set()
    cfg = load_json_file(XRAY_CONF)
    if not isinstance(cfg, dict):
        return set()
    ports = set()
    inbounds = cfg.get('inbounds')
    if not isinstance(inbounds, list):
        return ports
    for inb in inbounds:
        if not isinstance(inb, dict):
            continue
        proto = inb.get('protocol') or ''
        stream = inb.get('streamSettings')
        network = (stream.get('network') if isinstance(stream, dict) else '') or ''
        p = inb.get('port')
        p = str(p) if p is not None else ''
        if not re.fullmatch(r'[0-9]+', p):
            continue
        is_udp = proto in ('hysteria', 'hysteria2', 'tuic') or network in ('kcp', 'quic')
        ports.add(('udp' if is_udp else 'tcp', int(p)))
    return ports


def nginx_conf_text():
    """nginx 全量配置文本: nginx -T 优先 (含 include 展开); 失败 (配置坏/未起) 时
    直扫 conf 目录所有文件 (与原 grep -rhE '.' 等价)。"""
    if not has('nginx'):
        return None
    rc, out, _ = run(['nginx', '-T'], timeout=30)
    if rc == 0 and out:
        return out
    lines = []
    for dirpath, _dirs, filenames in os.walk(NGINX_CONF_DIR):
        for fn in sorted(filenames):
            try:
                with open(os.path.join(dirpath, fn), 'r', errors='replace') as fh:
                    for line in fh:
                        if line.strip():
                            lines.append(line.rstrip('\n'))
            except OSError:
                pass
    return '\n'.join(lines)


def nginx_declared_proto_ports():
    """nginx 声明的 (协议, 端口) 集合。
    listen 形态: `80` / `443 ssl` / `[::]:443 ssl` / `1234 udp` / `127.0.0.1:8080`
    → 取 listen 后第一个 token 的最后冒号后部分 = port; 同行含 udp/quic → UDP
    (HTTP/3 的 `listen ... quic` 同样监听 UDP, 必须一并判为 UDP 否则与 xray UDP:443
    的真实抢占漏报)。先剥离 # 注释, 否则被注释的 listen 会被误判。"""
    text = nginx_conf_text()
    if text is None:
        return set()
    ports = set()
    for line in text.splitlines():
        line = re.sub(r'#.*', '', line)
        if not re.search(r'(?:^|\s)listen\s', line):
            continue
        proto = 'udp' if re.search(r'\s(udp|quic)([\s;]|$)', line) else 'tcp'
        after = re.sub(r'.*listen\s+', '', line, count=1)
        token = re.split(r'[\s;]', after, 1)[0]
        port = token.rsplit(':', 1)[-1]
        if re.fullmatch(r'[0-9]+', port):
            ports.add((proto, int(port)))
    return ports


def runtime_holders(proto, port):
    """某 (协议, 端口) 的运行时占用进程名集合 (解析 ss -H -tulnp; 精确匹配:
    Netid 前缀 = proto, 本地地址最后冒号后 = port — 防止 :443 误匹 :8443/IPv6 段)"""
    names = set()
    pat_port = str(port)
    for line in ss_lines():
        parts = line.split()
        if len(parts) < 5 or not parts[0].startswith(proto):
            continue
        if parts[4].rsplit(':', 1)[-1] != pat_port:
            continue
        m = re.search(r'users:\(\("([^"]+)"', line)
        if m:
            names.add(m.group(1))
    return names


_XPP = None  # xray 声明 (proto, port) 缓存
_NPP = None  # nginx 声明缓存


def ensure_proto_ports():
    global _XPP, _NPP
    if _XPP is None:
        _XPP = xray_declared_proto_ports()
    if _NPP is None:
        _NPP = nginx_declared_proto_ports()


def _pp_sort_key(pp):
    """(proto, port) 排序键 — 与 sh 版 `sort -u` 的字符串序一致 ("tcp 443" < "tcp 80"),
    保证 JSON 结果条目顺序与旧版逐字节兼容"""
    return f'{pp[0]} {pp[1]}'


def port_overlap_check():
    """同协议同端口双重声明抢占检查 (幂等, 全程仅报告一次); 命中后按当前实际占用者
    细分 4 类根因 (xray 抢到 / nginx 抢到 / 第三方占用 / 双方都没起来)。"""
    if port_overlap_check.done:
        return
    port_overlap_check.done = True
    if not (has('nginx') and os.path.isfile(XRAY_CONF)):
        report_cross_proto_coexist()
        return
    ensure_proto_ports()
    if not (_XPP and _NPP):
        report_cross_proto_coexist()
        return

    for proto, port in sorted(_XPP, key=_pp_sort_key):
        if (proto, port) not in _NPP:
            continue
        holders = runtime_holders(proto, port)
        hx = bool(holders & {'xray', 'xray-core'})
        hn = 'nginx' in holders
        others = sorted(h for h in holders if h not in ('xray', 'xray-core', 'nginx'))
        tag = f'{proto}/{port}'
        if hx:
            result('FAIL', f'PORT_DUAL_DECL_XRAY_WON_{port}',
                   f'{tag} 同时被 xray 与 nginx 声明 → 抢占冲突 (当前 xray 占用, nginx bind 失败)',
                   f'根因: 同协议同端口只能有一个监听者; xray 先启动已抢到, nginx 启动必然 \'address already in use\' 失败。修复: 让 nginx 让出 {tag} (改 listen 端口如 8443; 或 xray 走 nginx 反代 / SNI 分流, 二者只留一个对外)')
        elif hn:
            result('FAIL', f'PORT_DUAL_DECL_NGINX_WON_{port}',
                   f'{tag} 同时被 xray 与 nginx 声明 → 抢占冲突 (当前 nginx 占用, xray bind 失败)',
                   f"根因: nginx 先启动已抢到 {tag}, xray 启动必然 'address already in use' 失败退出。修复: 让 xray 让出 {tag} (改 inbound.port; 或 nginx 反代到 xray, xray 改 listen 127.0.0.1)")
        elif others:
            how = ','.join(others)
            result('FAIL', f'PORT_DUAL_DECL_3RD_{port}',
                   f'{tag} 同时被 xray 与 nginx 声明, 但已被无关进程 [{how}] 占用 → 两边都会 bind 失败',
                   f'根因: 真正占住端口的是第三方 [{how}], xray 与 nginx 谁也抢不到。修复: 先查清 [{how}] 是什么 (ss -tulnp / lsof -i :{port}), 停掉或迁移它, 再重启 xray/nginx; 切勿盲目重启 xray/nginx')
        else:
            result('FAIL', f'PORT_DUAL_DECL_NONE_{port}',
                   f'{tag} 同时被 xray 与 nginx 声明, 但当前无任何进程占用 → 二者均未成功监听',
                   "根因: 端口本身空闲, 说明 xray 和 nginx 都没跑起来 (而非互相抢占)。看服务状态项与 journalctl: 可能服务 down、配置语法错、证书缺失、或反复 bind 失败被 systemd 'start-limit hit' 放弃。先 systemctl reset-failed 再 start")
    report_cross_proto_coexist()


port_overlap_check.done = False


def report_cross_proto_coexist():
    """同端口号不同协议 = 跨协议共存 (非冲突), 显式 PASS — 回答 "xray 和 nginx 都用
    443 到底有没有冲突": 协议不同则完全正常 (TCP/UDP 独立命名空间)。"""
    if not (_XPP and _NPP):
        return
    reported = set()
    for xp, xport in sorted(_XPP, key=_pp_sort_key):
        if (xp, xport) in _NPP or xport in reported:
            continue
        for np_, nport in sorted(_NPP, key=_pp_sort_key):
            if nport != xport or np_ == xp:
                continue
            reported.add(xport)
            result('PASS', f'PORT_CROSS_PROTO_{xport}',
                   f'端口 {xport} 跨协议共存: xray={xp}/{xport} + nginx={np_}/{xport} → 非冲突',
                   'TCP 与 UDP 是独立命名空间, 同端口号可分别被监听, 互不影响 (典型: nginx TCP:443 ssl + xray UDP:443 hysteria)。这是健康状态, 无需处理')


def xray_port_runtime_check():
    """xray 独占 (proto,port) 的运行时占用检查 (允许 xray 自身占用; 跳过已报告的重叠项)"""
    if not os.path.isfile(XRAY_CONF):
        return
    ensure_proto_ports()
    for proto, port in sorted(_XPP, key=_pp_sort_key):
        if (proto, port) in _NPP:
            continue
        holders = runtime_holders(proto, port)
        if 'xray' in holders:
            result('PASS', f'PORT_XRAY_LISTEN_{proto}_{port}', f'{proto}/{port}: xray 正在监听 (允许占用)')
        elif not holders:
            result('PASS', f'PORT_FREE_{proto}_{port}', f'{proto}/{port}: 空闲, 可供 xray 使用')
        else:
            how = ','.join(sorted(holders))
            result('FAIL', f'PORT_OCCUPIED_{proto}_{port}',
                   f'{proto}/{port}: xray 需要该端口, 但被无关进程 [{how}] 占用',
                   f'停止 [{how}] 或让 xray 改用空闲端口 (注意: 仅【同协议同端口】才算占用; 若仅另一协议占用同端口号则不冲突)')


def nginx_port_runtime_check():
    """nginx 独占 (proto,port) 的运行时占用检查 (允许 nginx 自身占用; 跳过重叠项)"""
    if not has('nginx'):
        return
    ensure_proto_ports()
    for proto, port in sorted(_NPP, key=_pp_sort_key):
        if (proto, port) in _XPP:
            continue
        holders = runtime_holders(proto, port)
        if 'nginx' in holders:
            result('PASS', f'PORT_NGINX_LISTEN_{proto}_{port}', f'{proto}/{port}: nginx 正在监听')
        elif not holders:
            result('PASS', f'PORT_NGINX_FREE_{proto}_{port}', f'{proto}/{port}: 空闲, 可供 nginx 使用')
        else:
            how = ','.join(sorted(holders))
            result('FAIL', f'NGINX_PORT_OCCUPIED_{proto}_{port}',
                   f'{proto}/{port}: nginx 需要该端口, 但被无关进程 [{how}] 占用',
                   f'停止 [{how}] 或修改 nginx listen 端口')


# ============================================================
# TLS 证书通用检查 — 被 xray/nginx/cert 三个入口共用, 按文件路径全局去重
# ============================================================
_CERT_FILES_CHECKED = set()


def check_cert_file(cf, pfx):
    if cf in _CERT_FILES_CHECKED:
        return
    _CERT_FILES_CHECKED.add(cf)
    if not os.path.exists(cf):
        result('FAIL', f'{pfx}_MISSING', f'引用的证书不存在: {cf}', '启动会因找不到证书而失败; 补齐证书或修正路径')
    elif not os.access(cf, os.R_OK):
        result('FAIL', f'{pfx}_NOREAD', f'证书不可读: {cf}', '检查文件权限与运行用户')
    else:
        result('PASS', f'{pfx}_OK', f'证书文件就绪: {cf}')
        check_cert_expiry(cf)


def check_cert_expiry(f):
    """过期检查 (仅对 PEM 文本证书; 原生 datetime 解析 openssl 日期 — 不再依赖
    GNU date, busybox 环境也不会漏报, 原 CERT_EXPIRY_CHECK_FAILED 兜底子系统随之删除)"""
    if not has('openssl'):
        return
    try:
        with open(f, 'r', errors='replace') as fh:
            if 'BEGIN CERTIFICATE' not in fh.read():
                return
    except OSError:
        return
    out = run_out(['openssl', 'x509', '-in', f, '-noout', '-enddate']).strip()
    if not out.startswith('notAfter='):
        return
    end_str = out.split('=', 1)[1].strip()
    try:
        # notAfter 为 GMT (UTC) — 必须 UTC-aware 解析, 再与 UTC now 相减
        # (naive 会按本地时区错位, 天数可能偏差)
        end_dt = datetime.datetime.strptime(end_str.replace(' GMT', '').strip(),
                                            '%b %d %H:%M:%S %Y').replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        result('WARN', 'CERT_EXPIRY_CHECK_FAILED',
               f'证书过期检查无法执行 (openssl 日期解析失败): {f} (到期 {end_str})',
               '人工核对: openssl x509 -checkend 0 -noout -in <cert>')
        return
    secs = (end_dt - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
    days = int(secs / 86400)  # C 风格向零截断 (与 sh 整数除法一致)
    cn = ''
    subj = run_out(['openssl', 'x509', '-in', f, '-noout', '-subject']).strip()
    if subj:
        subj = re.sub(r'^subject[= ]*', '', subj)
        subj = re.sub(r'.*CN\s*=\s*', '', subj, count=1)
        cn = subj.split('/')[0]
    if days < 0:
        result('FAIL', 'CERT_EXPIRED', f'证书已过期 {-days} 天: {f} (CN={cn}, 到期 {end_str})',
               '已过期证书: xray/nginx 仍能启动但客户端 TLS 握手会失败/告警。续期: acme.sh / certbot')
    elif days <= 7:
        result('WARN', 'CERT_EXPIRING', f'证书即将过期 (剩 {days} 天): {f} (CN={cn})', '尽快续期')
    elif days <= 30:
        result('WARN', 'CERT_RENEW_SOON', f'证书 30 天内过期 (剩 {days} 天): {f} (CN={cn})', '安排续期')
    else:
        result('PASS', 'CERT_VALID', f'证书有效 (剩 {days} 天): {f} (CN={cn})')


def check_cert_refs_in_xray(cfg_path):
    """扫描 xray 配置中的证书引用 (递归任意层级的 certificateFile/keyFile, 原生 json)"""
    if not os.path.isfile(cfg_path):
        return
    cfg = load_json_file(cfg_path)
    if not isinstance(cfg, dict):
        return

    def walk(obj, key, acc):
        if isinstance(obj, dict):
            for k, v in obj.items():
                if k == key and isinstance(v, str):
                    acc.add(v)
                walk(v, key, acc)
        elif isinstance(obj, list):
            for it in obj:
                walk(it, key, acc)

    certs, keys = set(), set()
    walk(cfg, 'certificateFile', certs)
    walk(cfg, 'keyFile', keys)
    for f in sorted(certs):
        if f.startswith('/'):  # 只查绝对路径
            check_cert_file(f, 'XRAY_CERT')
    for f in sorted(keys):  # 密钥文件不做过期检查, 只查存在/可读
        if not f.startswith('/'):
            continue
        if not os.path.exists(f):
            result('FAIL', 'XRAY_CERT_MISSING', f'配置引用的密钥不存在: {f}',
                   'xray 启动会因找不到密钥而失败; 补齐证书或修正路径')
        elif not os.access(f, os.R_OK):
            result('FAIL', 'XRAY_CERT_NOREAD', f'密钥不可读: {f}', '检查文件权限与运行用户 (systemd User=)')


def check_geo_files(conf_dir):
    """geo 数据文件 (geoip.dat / geosite.dat; xray 默认在 conf 目录或二进制同目录找)"""
    found = ''
    for loc in (conf_dir, os.path.dirname(XRAY_BIN), '/usr/local/share/xray', '/usr/share/xray'):
        if not os.path.isdir(loc):
            continue
        for geo in ('geoip.dat', 'geosite.dat'):
            if os.path.isfile(os.path.join(loc, geo)):
                found = os.path.join(loc, geo)
    if found:
        result('PASS', 'XRAY_GEO_OK', f'geo 数据文件就绪: {found}')
    else:
        result('WARN', 'XRAY_GEO_MISSING', '未找到 geoip.dat / geosite.dat',
               '若配置用到 geosite/geoip 路由规则, 缺失会导致分流失效或启动报错; 下载到 conf 目录')


# ============================================================
# OOM 杀进程检查
# ============================================================
def check_oom_for(proc):
    hit = ''
    if has('dmesg'):
        for line in run_out(['dmesg']).splitlines():
            if re.search(r'out of memory|killed process', line, re.I) \
               and re.search(re.escape(proc), line, re.I):
                hit = line
    if not hit and has('journalctl'):
        for line in run_out(['journalctl', '-k', '--no-pager']).splitlines():
            if re.search(r'oom|killed process', line, re.I) \
               and re.search(re.escape(proc), line, re.I):
                hit = line
    if hit:
        result('WARN', f'{proc}_OOM', f'{proc} 曾被 OOM Killer 杀掉', f'{hit} | 考虑加 swap 或限制内存')


# ============================================================
# xray 检查
# ============================================================
def check_xray():
    say('xray (二进制 / 配置 / 服务 / 端口冲突 / 证书 / geo / OOM)')

    # X1. 二进制存在 + 可执行
    if not os.path.exists(XRAY_BIN):
        result('FAIL', 'XRAY_BIN_MISSING', f'xray 二进制不存在: {XRAY_BIN}',
               f'重新安装 xray-core (下载对应架构二进制到 {XRAY_BIN} 并 chmod +x)')
        return  # 二进制都没有, 后续检查无意义
    if not os.access(XRAY_BIN, os.X_OK):
        result('FAIL', 'XRAY_BIN_NOEXEC', f'xray 二进制无执行权限: {XRAY_BIN}', f'修复: chmod +x {XRAY_BIN}')
    else:
        result('PASS', 'XRAY_BIN_OK', 'xray 二进制存在且可执行')

    # X2. 二进制能运行 (架构不匹配会报 exec format error)
    ver_out = run_all([XRAY_BIN, '-version'])
    ver = ver_out.splitlines()[0] if ver_out.splitlines() else ''
    if 'Xray' in ver:
        result('PASS', 'XRAY_VER_OK', 'xray 版本: ' + ' '.join(ver.split()[1:3]))
    elif 'exec format error' in ver or 'cannot execute binary file' in ver:
        result('FAIL', 'XRAY_BIN_ARCH', f'二进制架构不匹配, 无法执行: {ver}',
               f'下载了错误 CPU 架构的 xray。本机: {platform.machine()}, 请重新下载对应架构版本')
    else:
        result('WARN', 'XRAY_VER_UNK', f'xray -version 输出异常: {ver}')

    # X3. 配置文件存在
    if not os.path.isfile(XRAY_CONF):
        result('FAIL', 'XRAY_CONF_MISSING', f'配置文件不存在: {XRAY_CONF}',
               '生成配置 (x-ui/3x-ui 面板或手写), 或从备份恢复')
        return
    result('PASS', 'XRAY_CONF_OK', f'配置文件存在: {XRAY_CONF}')

    # X4. JSON 语法 + xray 自检
    test = run_all([XRAY_BIN, '-test', '-config', XRAY_CONF])
    if 'Configuration OK' in test:
        result('PASS', 'XRAY_CONF_OK2', 'xray -test 通过 (Configuration OK)')
    else:
        err = next((l for l in test.splitlines()
                    if re.search(r'error|invalid|failed', l, re.I)), '')
        result('FAIL', 'XRAY_CONF_BAD', 'xray 配置语法/校验失败', err or test)

    # X5. systemd 单元存在 + 未被 mask
    if not has('systemctl'):
        result('WARN', 'XRAY_NO_SYSTEMD', '无 systemctl, 跳过服务检查 (非 systemd 系统)')
        return
    rc, _, _ = run(['systemctl', 'list-unit-files', 'xray.service'])
    if rc != 0 \
       and not os.path.isfile('/etc/systemd/system/xray.service') \
       and not os.path.isfile('/lib/systemd/system/xray.service'):
        result('FAIL', 'XRAY_UNIT_MISSING', 'systemd 单元不存在: xray.service',
               '创建 /etc/systemd/system/xray.service 并 systemctl daemon-reload')
    enabled = run_out(['systemctl', 'is-enabled', 'xray.service']).strip()
    if enabled == 'masked':
        result('FAIL', 'XRAY_MASKED', '服务被 mask (systemctl unmask xray)', '')

    # X6. 当前服务状态 + 失败详情
    state = run_out(['systemctl', 'is-active', 'xray.service']).strip()
    if state == 'active':
        result('PASS', 'XRAY_ACTIVE', 'xray 服务运行中 (active)')
    else:
        s_result = run_out(['systemctl', 'show', 'xray.service', '-p', 'Result', '--value']).strip()
        exec_status = run_out(['systemctl', 'show', 'xray.service', '-p', 'ExecMainStatus', '--value']).strip()
        nrestart = run_out(['systemctl', 'show', 'xray.service', '-p', 'NRestarts', '--value']).strip()
        journal = run_out(['journalctl', '-u', 'xray.service', '-n', '80', '--no-pager'])
        lasterr = ''
        for line in journal.splitlines():
            if re.search(r'failed to|error|bind|address already in use|exec format|no such file|permission',
                         line, re.I):
                lasterr = line
        detail = f'状态={state} Result={s_result} ExecMainStatus={exec_status} NRestarts={nrestart}'
        if lasterr:
            detail += f' | 日志: {lasterr}'
        result('FAIL', 'XRAY_INACTIVE', f'xray 未运行 (state={state})', detail)

    # X8. 重启风暴 — systemd 因反复失败放弃拉起
    nrestart = to_int(run_out(['systemctl', 'show', 'xray.service', '-p', 'NRestarts', '--value']), 0)
    if nrestart >= 5:
        storm = ''
        for line in run_out(['journalctl', '-u', 'xray.service', '--no-pager']).splitlines():
            if re.search(r'repeated too quickly', line, re.I):
                storm = line
        if storm:
            result('WARN', 'XRAY_RESTART_STORM', f'systemd 因重启风暴放弃拉起 (NRestarts={nrestart})',
                   'systemctl reset-failed xray 后再 start。根因通常是: 端口占用/配置错误/证书缺失, 见其它 FAIL 项')

    # X9. 端口冲突 — nginx↔xray 同协议同端口抢占 (协议感知) + 运行时占用
    port_overlap_check()
    xray_port_runtime_check()

    # X10. 证书文件存在 + 可读 (扫描配置里的 certificateFile / keyFile)
    check_cert_refs_in_xray(XRAY_CONF)

    # X11. geo 数据文件
    check_geo_files(XRAY_DIR)

    # X12. 近期 OOM 杀进程记录
    check_oom_for('xray')


# ============================================================
# nginx 检查
# ============================================================
def check_nginx_certs():
    """只查 NGINX_CONF_DIR 下 *.conf 声明的 ssl_certificate (剥注释; 不依赖 nginx -T,
    nginx -t 失败/服务未起也能查出引用; 未被引用的散落证书不在检查范围)"""
    if not os.path.isdir(NGINX_CONF_DIR):
        return
    certs = set()
    for path in find_files(NGINX_CONF_DIR, ('*.conf',), maxdepth=3):
        try:
            with open(path, 'r', errors='replace') as fh:
                for raw in fh:
                    line = re.sub(r'#.*', '', raw)
                    if not re.search(r'\sssl_certificate\s', line):
                        continue
                    after = re.sub(r'.*ssl_certificate\s+', '', line, count=1)
                    token = re.split(r'[;\s]', after, 1)[0]
                    if token.startswith('/'):
                        certs.add(token)
        except OSError:
            pass
    for f in sorted(certs):
        check_cert_file(f, 'NGINX_CERT')


def check_nginx():
    say('nginx (二进制 / 配置测试 / 服务 / 端口冲突 / 证书 / 用户 / include)')

    # N1. 已安装
    if not has('nginx'):
        if TARGET == 'all':
            result('WARN', 'NGINX_ABSENT', '未安装 nginx (若该节点本应使用 nginx 反代则需安装)', '')
        return
    ver_out = run_all(['nginx', '-v']).strip()
    result('PASS', 'NGINX_INSTALLED', 'nginx 已安装: ' + re.sub(r'.*/', '', ver_out))

    # N2. 配置测试 nginx -t
    t = run_all(['nginx', '-t'])
    if 'test is successful' in t or 'syntax is ok' in t:
        result('PASS', 'NGINX_CONF_OK', 'nginx -t 通过')
    else:
        errs = [l for l in t.splitlines() if re.search(r'emerg|error|failed', l, re.I)][:2]
        result('FAIL', 'NGINX_CONF_BAD', 'nginx -t 失败', ' '.join(errs) if errs else t)

    # N3. 服务状态
    if has('systemctl'):
        ns = run_out(['systemctl', 'is-active', 'nginx.service']).strip()
        if ns == 'active':
            result('PASS', 'NGINX_ACTIVE', 'nginx 服务运行中')
        else:
            nerr = ''
            for line in run_out(['journalctl', '-u', 'nginx.service', '-n', '40', '--no-pager']).splitlines():
                if re.search(r'emerg|error|failed|bind|address already', line, re.I):
                    nerr = line
            result('FAIL', 'NGINX_INACTIVE', f'nginx 未运行 (state={ns})', nerr or '无明确错误日志')

    # N4. 端口冲突 — 委托统一检测
    port_overlap_check()
    nginx_port_runtime_check()

    # N5. 证书引用检查
    check_nginx_certs()

    # N6. nginx user 是否存在
    nginx_conf = os.path.join(NGINX_CONF_DIR, 'nginx.conf')
    if os.path.isfile(nginx_conf):
        user = 'www-data'
        try:
            with open(nginx_conf, 'r', errors='replace') as fh:
                for raw in fh:
                    m = re.match(r'\s*user\s+([^;\s]+)', raw)
                    if m:
                        user = m.group(1)
                        break
        except OSError:
            pass
        rc, _, _ = run(['getent', 'passwd', user])
        if rc != 0:
            result('FAIL', 'NGINX_USER_MISSING', f'nginx.conf 配置 user {user} 但系统无此用户',
                   f'worker 进程会启动失败; useradd {user} 或改用 www-data')
        else:
            result('PASS', 'NGINX_USER_OK', f"nginx user '{user}' 存在")


# ============================================================
# 网络与防火墙 (net)
# ============================================================
def check_net():
    say('网络与防火墙 (iptables / ufw / firewalld / SELinux / conntrack / sysctl / NODE_PORT 对外可达与大陆 tcping)')

    # NW1. iptables DROP/REJECT 规则 (可能拦截代理端口)
    if has('iptables'):
        drop = sum(1 for l in run_out(['iptables', '-L', '-n']).splitlines()
                   if re.search(r'DROP|REJECT', l, re.I))
        if drop > 5:
            result('WARN', 'NET_IPTABLES_DROP', f'iptables 有 {drop} 条 DROP/REJECT 规则',
                   'iptables -L -n --line-numbers 检查是否误拦了 xray/nginx 端口 (443/80/自定义)')
        else:
            result('PASS', 'NET_IPTABLES_OK', f'iptables DROP/REJECT 规则数 {drop} (低)')

    # NW2. ufw
    if has('ufw'):
        ufw = run_out(['ufw', 'status']).splitlines()
        first = ufw[0] if ufw else ''
        if 'inactive' in first:
            result('PASS', 'NET_UFW_OFF', 'ufw 未启用')
        elif 'active' in first:
            result('WARN', 'NET_UFW_ON', 'ufw 已启用, 确认放行了代理端口',
                   'ufw status 查看, ufw allow 443/tcp 放行')

    # NW3. firewalld
    if has('firewall-cmd'):
        rc, _, _ = run(['systemctl', 'is-active', 'firewalld'])
        if rc == 0:
            result('WARN', 'NET_FIREWALLD_ON', 'firewalld 已启用, 确认放行了代理端口', 'firewall-cmd --list-ports')
        else:
            result('PASS', 'NET_FIREWALLD_OFF', 'firewalld 未运行')

    # NW4. SELinux
    if has('getenforce'):
        se = run_out(['getenforce']).strip()
        if se == 'Enforcing':
            result('WARN', 'NET_SELINUX_ENF', 'SELinux 处于 Enforcing 模式',
                   '可能阻止 nginx/xray 绑定非标准端口或读取证书。setenforce 0 临时放宽排查, 或 restorecon 修复标签')
        elif se in ('Permissive', 'Disabled'):
            result('PASS', 'NET_SELINUX_OK', f'SELinux: {se}')

    # NW5. 提示云安全组 (本地无法检测)
    result('WARN', 'NET_SG_REMINDER', '云厂商安全组 (AWS SG / 阿里云安全组 / GCP 防火墙) 需在控制台单独放行端口',
           '若本地端口监听正常但外部连不上, 99% 是云安全组未放行')

    # NW6. conntrack 连接跟踪表 — 代理高并发的生命线
    #   真实故障 (2026-08-08, 103.173.155.212): nf_conntrack_max 默认 8192 多用户下
    #   秒级打满 → 海量 'table full, dropping packet' → 内存耗尽 → 整机硬死锁。
    ct_max_path = '/proc/sys/net/netfilter/nf_conntrack_max'
    if os.access(ct_max_path, os.R_OK) and os.path.isfile(ct_max_path):
        ct_max = to_int(_read_proc(ct_max_path), 8192)
        ct_count = to_int(_read_proc('/proc/sys/net/netfilter/nf_conntrack_count'), 0)
        ct_pct = (ct_count * 100 // ct_max) if ct_max > 0 else 0
        if ct_max < 65536:
            if ct_pct >= 50:
                result('FAIL', 'NET_CONNTRACK_TOO_SMALL',
                       f'nf_conntrack_max={ct_max} 过小 (<代理建议 65536), 当前占用已 {ct_pct}% ({ct_count})',
                       '表小且占用过半, 多用户高并发下随时秒级打满 → 海量丢包 → 内存耗尽硬死锁 (本次 103.173.155.212 死机根因)。修复: /etc/sysctl.d/99-nodehub-proxy.conf 写 net.netfilter.nf_conntrack_max=262144 (proxyInstall.sh 的 TuneKernelForProxy 已自动处理)')
            else:
                result('WARN', 'NET_CONNTRACK_SMALL',
                       f'nf_conntrack_max={ct_max} 低于代理建议 65536, 当前占用 {ct_count} ({ct_pct}%) 尚低',
                       '暂无打满风险; 建议空闲时抬高到 262144 防患高并发 (proxyInstall.sh 的 TuneKernelForProxy 已自动处理)')
        elif ct_pct >= 85:
            result('WARN', 'NET_CONNTRACK_HIGH', f'conntrack 占用 {ct_pct}% ({ct_count}/{ct_max})',
                   '逼近上限, 检查是否有异常连接暴增; 必要时再抬高 nf_conntrack_max')
        else:
            result('PASS', 'NET_CONNTRACK_OK', f'nf_conntrack_max={ct_max}, 占用 {ct_pct}% ({ct_count})')

    # NW7. 历史打满痕迹 — 本次/上次启动的内核日志是否记录过 'table full'
    if has('journalctl'):
        ctf_cur = sum(1 for l in run_out(['journalctl', '-b', '0', '-k', '--no-pager']).splitlines()
                      if 'table full' in l)
        ctf_prev = sum(1 for l in run_out(['journalctl', '-b', '-1', '-k', '--no-pager']).splitlines()
                       if 'table full' in l)
        if ctf_cur > 0:
            result('FAIL', 'NET_CONNTRACK_FULL_NOW',
                   f"本次启动已记录 {ctf_cur} 次 'nf_conntrack: table full, dropping packet'",
                   '连接跟踪表【正在】打满丢包, 立即抬高 nf_conntrack_max 否则随时硬死锁')
        elif ctf_prev > 50:
            result('WARN', 'NET_CONNTRACK_FULL_LASTBOOT',
                   f"上次启动记录 {ctf_prev} 次 'table full' (疑似上次宕机根因)",
                   '已重启但根因未除, 建议立即抬高 nf_conntrack_max 防止复发')

    # NW8. sysctl 配置完整性 — key= 空值坏行会让 sysctl -p 静默失败 (死机根因之一)
    bad = []
    sysctl_paths = ['/etc/sysctl.conf'] + sorted(glob.glob('/etc/sysctl.d/*.conf'))
    for sc in sysctl_paths:
        if not os.path.isfile(sc):
            continue
        try:
            with open(sc, 'r', errors='replace') as fh:
                for raw in fh:
                    line = raw.rstrip('\n')
                    if not line or line.startswith('#') or '=' not in line:
                        continue
                    val = line.split('=', 1)[1].split('#', 1)[0]
                    if val.replace(' ', '').replace('\t', '') == '':
                        key = line.split('=', 1)[0].replace(' ', '').replace('\t', '')
                        bad.append(key)
        except OSError:
            pass
    if bad:
        result('FAIL', 'NET_SYSCTL_EMPTY_VALUE',
               'sysctl 配置存在【空值坏行】(key= 后无值): ' + ' '.join(bad),
               '空值使 sysctl -p 对该行报错而被忽略 → 调优静默失效回退默认值 (本次死机: 6 行 conntrack 空值 → 回退 8192 → 打满死锁)。修复: 删除这些空行, 或补上正确数值')
    else:
        result('PASS', 'NET_SYSCTL_OK', 'sysctl 配置无空值坏行')

    # NW9. NODE_PORT 对外可达性 (端口监听 ≠ 外部可访问)
    check_node_port_external()

    # NW10. NODE_PORT 大陆 tcping 被墙检测
    check_node_port_cn_tcping()


def _read_proc(path):
    try:
        with open(path, 'r') as fh:
            return fh.read().strip()
    except OSError:
        return ''


# ============================================================
# NODE_PORT 对外可达性 — 端口监听 ≠ 外部可访问
#   端口若只 bind 127.0.0.1/::1, 本地 ss 显示"在监听"但外部客户端永远连不上。
# ============================================================
def check_node_port_external():
    node_port = resolve_node_port()
    target_ip = (ENV.get('NODE_TARGET_IP') or '').strip()
    if target_ip and f' {target_ip} ' not in f' {host_ips()} ':
        note(f'远程目标模式: NODE_TARGET_IP={target_ip} 非本机, 跳过 NODE_PORT 本机监听检查 (ss 只能看本机)')
        return
    # 协议感知: NODE_PORT 可能承载 TCP 也可能 UDP (Hysteria2 直听), 双协议同查
    pat = re.compile(rf'[:.]{re.escape(node_port)}([^0-9]|$)')
    listen = [l for l in ss_lines() if pat.search(l)]
    if not listen:
        actual = []
        for line in ss_lines():
            if re.search(r'users:.+"(xray|nginx)"', line) \
               and not re.search(r'127\.0\.0\.1|::1', line):
                parts = line.split()
                if len(parts) >= 5:
                    actual.append(parts[4])
        if actual:
            hint = (f'实际对外监听端口: [{",".join(actual)}] —— ~/.env 的 NODE_PORT={node_port} '
                    '疑似过期, 与实际不符 (重跑安装脚本会读到错误端口搞坏代理)')
        else:
            hint = 'xray/nginx 均未监听任何对外端口, 检查服务是否启动'
        result('FAIL', 'NODE_PORT_NOT_LISTENING',
               f'NODE_PORT={node_port} (TCP/UDP 均无监听) → 外部无法连接',
               hint + '。核对 ~/.env / node.json / node.env 的 NODE_PORT 与实际配置一致')
        return
    # 外部可达 = 存在非环回监听地址 (* / 0.0.0.0 / [::] / 公网IP)
    external = next((l.split()[4] for l in listen
                     if len(l.split()) >= 5 and not re.match(r'^(127\.|\[?::1\])', l.split()[4])), '')
    if external:
        b = ','.join(sorted({f"{l.split()[0]}/{l.split()[4]}" for l in listen if len(l.split()) >= 5}))
        result('PASS', 'NODE_PORT_EXTERNAL',
               f'NODE_PORT={node_port} 监听在对外地址 [{b}] → 外部可达',
               'TCP/UDP 任一协议对外监听即视为可达 (Hysteria2 走 UDP)')
    else:
        result('FAIL', 'NODE_PORT_LOCALHOST_ONLY',
               f'NODE_PORT={node_port} 仅监听 127.0.0.1/::1 → 外部无法访问',
               'xray inbound 的 listen 留空或设 0.0.0.0; nginx listen 行去掉 127.0.0.1: 前缀')


# ============================================================
# NODE_PORT 大陆 tcping 被墙检测 (NW10) — "端口在监听 + 海外可达" ≠ "大陆可达"
#
# 被墙的表现: 本机端口监听正常 / 证书有效 / 海外客户端一切正常, 但大陆方向 TCP
#   握手全部超时或重置 → 用户侧"连不上", 节点侧常规检查全部 PASS — 与出站 IPv4
#   被封 (check_outbound) 同属"本机一切正常"型隐蔽故障, 必须借大陆视角才能发现。
#
# 做法: 借 tcp.ping.pe 的大陆探测点 (三网 + 云厂) 对 <node_ip:node_port> 做 TCP
#   连通测试, 与海外探测点对照; 逐网展示 (移动/电信/联通/云厂/海外 各自: 通/部分/断):
#   · 大陆全断 + 海外正常 → FAIL NODE_PORT_CN_BLOCKED
#   · 单网 0/N 全挂       → WARN NODE_PORT_CN_PARTIAL (单网被墙/干扰)
#   · 大陆全部成功        → PASS NODE_PORT_CN_OK
#   全球探测点全失败 → 不是大陆方向问题 (端口未开/安全组), 不误报被墙。
#
# 交叉验证 (xcheck): 随机开临时 TCP 端口 (20000-60000, 进程内 daemon 线程) 再测一轮:
#   A. 主测判出封锁 → 区分【端口被墙】(换端口可救) vs【IP 整段被墙】(需 CDN/中转/换 IP)
#   B. 主测大陆全通 → 自检模式: 新开随机端口理应同样可达, 矛盾则 WARN (验证测试逻辑可信度)
#   开关: NODE_CN_TCPING=0 关整个检测; NODE_CN_TCPING_XCHECK=0 只关交叉验证 (省 ~60s)。
#
# 接口流程 (实测逆向): 1) GET /IP:PORT 提取 antiflood cookie; 2) GET ?browsercheck=ok
#   提取 taskStartQuery/taskStartToken; 3) POST ajax_startTask_v1.php (须带 Origin 头)
#   → stream_id; 4) 轮询 ajax_getPingResults_v2.php (每轮增量, 拼接累积) 至
#   outstandingNodeCount:0。结果语义: result:1 = 失败, V>1 = 成功 (V/100 ≈ ms);
#   CN_ 前缀 = 大陆探测点, provider 取探测页 data-provider (电信/移动/联通/云厂)。
# ============================================================
PE_BASE = 'https://tcp.ping.pe'
PE_UA = 'Mozilla/5.0 (X11; Linux x86_64) NodeHub-proxyDiagnose'


def _pe_tag(provider):
    if 'Telecom' in provider:
        return 'CT'
    if 'Mobile' in provider:
        return 'CM'
    if 'Unicom' in provider:
        return 'CU'
    return 'CLD'


def pe_probe(target, label=''):
    """跑一轮 tcp.ping.pe 全球 tcping; 失败自行 emit WARN 并返回 None;
    成功返回 {t, cnok, cnfail, ok, fail, avg, segs[(网, 状态, ok/total), ...]}"""
    # 1) antiflood cookie: 首访响应内嵌 document.cookie 赋值, 提取后携带重访
    page = http_get(f'{PE_BASE}/{target}', headers={'User-Agent': PE_UA}, timeout=20)
    m = re.search(r'antiflood=([a-f0-9]+)', page)
    if not m:
        result('WARN', 'CN_TCPING_SERVICE_DOWN', f'tcp.ping.pe 不可达, 跳过{label} {target} 检测',
               f'本检查依赖其大陆探测点代测; 服务恢复后重跑, 或人工在 https://tcp.ping.pe/{target} 复核')
        return None
    cookie = f'antiflood={m.group(1)}'
    time.sleep(2)
    page = http_get(f'{PE_BASE}/{target}?browsercheck=ok',
                    headers={'User-Agent': PE_UA, 'Cookie': cookie}, timeout=40)
    m_tok = re.search(r'var taskStartToken = "([^"]*)"', page)
    m_qry = re.search(r'var taskStartQuery = "([^"]*)"', page)
    if not (m_tok and m_qry):
        result('WARN', 'CN_TCPING_SERVICE_CHANGE', f'tcp.ping.pe 页面无任务令牌 (接口疑似变更), 跳过{label}检测',
               f'人工在 https://tcp.ping.pe/{target} 复核大陆节点连通性')
        return None

    # 2) 启动探测任务 (须带 Origin 头, 否则 {"ok":false,"error":"Invalid origin"})
    start = http_post_form(f'{PE_BASE}/ajax_startTask_v1.php',
                           {'query': m_qry.group(1), 'start_token': m_tok.group(1)},
                           headers={'User-Agent': PE_UA, 'Cookie': cookie,
                                    'X-Requested-With': 'XMLHttpRequest',
                                    'Origin': PE_BASE, 'Referer': f'{PE_BASE}/{target}'},
                           timeout=20)
    m_sid = re.search(r'"stream_id":"?(\d+)', start)
    if not m_sid:
        if 'too_many' in start:
            result('WARN', 'CN_TCPING_SERVICE_BUSY', f'tcp.ping.pe 并发任务已满, 跳过{label}检测',
                   '检测服务繁忙, 稍后重跑 ./proxyDiagnose.py --target net')
        else:
            result('WARN', 'CN_TCPING_SERVICE_ERROR',
                   f'tcp.ping.pe 任务启动失败, 跳过{label}检测: {start[:120]}',
                   f'人工在 https://tcp.ping.pe/{target} 复核')
        return None
    sid = m_sid.group(1)

    # 3) 轮询增量结果拼接累积; "outstandingNodeCount":0 = 全部探测点已回报
    all_text = ''
    for i in range(12):
        time.sleep(4)
        r = http_get(f'{PE_BASE}/ajax_getPingResults_v2.php?type=tcp&totalPolls={i + 1}&stream_id={sid}',
                     headers={'User-Agent': PE_UA, 'Cookie': cookie,
                              'Referer': f'{PE_BASE}/{target}'}, timeout=25)
        all_text += '\n' + r
        if '"outstandingNodeCount":0' in r:
            break
        if r == '' and i >= 2:  # 连续空响应及早止损
            break

    # 4) 解析汇总: node→provider 映射取自探测页 <tr> 的 data-provider 属性
    prov = dict(re.findall(r"data-pinger-id='(CN_[0-9]+)'[^>]*data-provider='([^']*)'", page))
    t = cnok = cnfail = ok = fail = cns = 0
    cok, cfa = defaultdict(int), defaultdict(int)
    for node_id, val in re.findall(r'"node_id":"([A-Za-z0-9_]+)","timestamp_ms":\d+,"result":(-?\d+)', all_text):
        v = int(val)
        t += 1
        if node_id.startswith('CN_'):
            tag = _pe_tag(prov.get(node_id, ''))
            if v > 1:
                cnok += 1
                cns += v
                cok[tag] += 1
            else:
                cnfail += 1
                cfa[tag] += 1
        else:
            if v > 1:
                ok += 1
            else:
                fail += 1
    avg = int(cns / cnok / 100 + 0.5) if cnok else 0

    segs = []
    for lbl, key in (('移动', 'CM'), ('电信', 'CT'), ('联通', 'CU'), ('云厂', 'CLD')):
        o, n = cok[key], cok[key] + cfa[key]
        if n > 0:
            segs.append((lbl, '通' if o == n else ('部分' if o > 0 else '断'), f'{o}/{n}'))
    o, n = ok, ok + fail
    if n > 0:
        segs.append(('海外', '通' if o == n else ('部分' if o > 0 else '断'), f'{o}/{n}'))
    return {'t': t, 'cnok': cnok, 'cnfail': cnfail, 'ok': ok, 'fail': fail,
            'avg': avg, 'segs': segs}


def _pe_carrier_compact(segs):
    return ' '.join(f'{l}:{s}({n})' for l, s, n in segs)


def _pe_table(segs):
    lines = ''
    for l, s, n in segs:
        sc = C_RED if s == '断' else (C_YELLOW if s == '部分' else C_GREEN)
        lines += f'    │   {l}  {sc}{s}{C_RESET}  {n}\n'
    return lines


def _pe_dead_nets(segs):
    return [l for l, s, n in segs if s == '断' and l != '海外']


def _detect_public_ipv4():
    """公网 IPv4 探测 (api.ip.sb → ifconfig.me; 有 curl 时用 -4 强制 IPv4 —
    urllib 无法强制地址族, 双栈网络下会误得 IPv6)"""
    if has('curl'):
        ip = run_out(['curl', '-4', '-sS', '--connect-timeout', '6',
                      '--max-time', '10', 'https://api.ip.sb'], timeout=15).strip()
        if not ip:
            ip = run_out(['curl', '-4', '-sS', '--connect-timeout', '6',
                          '--max-time', '10', 'https://ifconfig.me'], timeout=15).strip()
        return ip
    ip = http_get('https://api.ip.sb', timeout=10).strip()
    if not ip:
        ip = http_get('https://ifconfig.me', timeout=10).strip()
    return ip


def check_node_port_cn_tcping():
    if ENV.get('NODE_CN_TCPING', '1') == '0':
        return
    node_port = resolve_node_port()

    # 目标 IP: NODE_TARGET_IP (第三方服务器上测别的节点; 最高优先, 不被 ~/.env 覆盖)
    #   > 已加载的 node_ip > ~/node.json .node_ip > 公网探测 (探测的就是运行机自己)
    from_detect = False
    host = (ENV.get('NODE_TARGET_IP') or '').strip() or (ENV.get('node_ip') or '').strip()
    if not host:
        nj = load_json_file(os.path.join(HOME, 'node.json'))
        if isinstance(nj, dict) and nj.get('node_ip'):
            host = str(nj['node_ip'])
    if not host:
        host = _detect_public_ipv4()
        from_detect = bool(host)
    if not host:
        result('WARN', 'CN_TCPING_NO_IP',
               f'无法确定目标公网 IP, 跳过 NODE_PORT={node_port} 大陆 tcping 被墙检测',
               '未配 node_ip 且公网探测 (api.ip.sb/ifconfig.me) 失败; 测远程节点用 NODE_TARGET_IP=<目标IP> NODE_PORT=<端口>')
        return

    # 目标是否本机: 决定监听类检查 (ss 前置 / 交叉验证临时端口) 是否适用
    ips = host_ips()
    is_local = (not ips.strip()) or (f' {host} ' in f' {ips} ') or from_detect

    # 前置 (仅本机目标): NODE_PORT 必须有 TCP 监听 (纯 UDP 端口 tcping 无意义;
    #   远程目标无法 ss, 端口实际未开时海外探测点也会失败 → PORT_UNREACHABLE 兜底)
    if is_local and not port_listening(node_port, tcp_only=True):
        result('WARN', 'CN_TCPING_UDP_ONLY',
               f'NODE_PORT={node_port} 无 TCP 监听 (疑似纯 UDP: Hysteria2 直听), 跳过大陆 tcping 被墙检测',
               'tcping 只能测 TCP; UDP 端口的封锁需用户侧实测/抓包判断 (probeTask.sh 采集方向)')
        return

    tgt = f'[{host}]:{node_port}' if ':' in host else f'{host}:{node_port}'

    # 主测: 原端口一轮完整探测
    r = pe_probe(tgt, '原端口')
    if r is None:
        return
    t, cnok, cnfail, ok, fail, avg, segs = (r['t'], r['cnok'], r['cnfail'],
                                            r['ok'], r['fail'], r['avg'], r['segs'])
    cn_cnt = cnok + cnfail
    ost = ok + fail
    car_s = _pe_carrier_compact(segs)
    dead_main = _pe_dead_nets(segs)

    if t == 0:
        result('WARN', 'CN_TCPING_PARSE_EMPTY', 'tcp.ping.pe 未返回任何探测结果, 跳过被墙判定',
               f'人工在 https://tcp.ping.pe/{tgt} 复核')
        return
    if cn_cnt == 0:
        result('WARN', 'CN_TCPING_NO_CN_NODE',
               f'tcp.ping.pe 本次无大陆探测点回报 (全球共 {t} 点), 无法判定被墙',
               f'大陆探测点可能临时下线, 稍后重跑; 人工在 https://tcp.ping.pe/{tgt} 复核')
        return

    # 5) 判定 — 逐网展示阻断状态, 不笼统汇总
    if ost > 0 and ok == 0:
        lvl, code = 'WARN', 'CN_TCPING_PORT_UNREACHABLE'
        title = f'{tgt} 端口本身不可达: 全球 {t} 个探测点全部失败'
        detail = '全球 (含海外) 全断不是被墙的特征 → 先看 NW9 NODE_PORT_NOT_LISTENING / 云安全组 / 本机防火墙'
    elif cnok == 0:
        lvl, code = 'FAIL', 'NODE_PORT_CN_BLOCKED'
        title = (f'NODE_PORT={node_port} 疑似被墙: 三网+云厂全断 (大陆 {cnfail}/{cn_cnt}), '
                 f'海外 {ok}/{ost} 正常')
        detail = (f'本机监听/证书/海外访问全正常, 唯独大陆不通 = 典型 IP/端口被墙特征。'
                  f'处置: ① https://tcp.ping.pe/{tgt} 多时段人工复核 ② 换端口 (重跑 proxyInstall.sh) '
                  f'③ 套 CDN/中转 ④ 联系机房换 IP')
    elif cnfail > 0:
        lvl, code = 'WARN', 'NODE_PORT_CN_PARTIAL'
        dead = ' '.join(dead_main)
        if dead_main:
            dead_slash = '/'.join(dead_main)
            title = (f'NODE_PORT={node_port} 部分被墙: {dead_slash} 全断, 其余网可达 '
                     f'(大陆 {cnok}/{cn_cnt} 通, 平均 {avg}ms)')
            detail = (f'疑似【单网被墙/干扰】(仅 {dead_slash} 断, 其余网正常): 受影响用户换接入网/套 CDN 可绕, '
                      f'无需整机换 IP; 持续恶化会演变为三网全断 (NODE_PORT_CN_BLOCKED)')
        else:
            title = (f'NODE_PORT={node_port} 部分线路抖动: 各网均有通有断 '
                     f'(大陆 {cnok}/{cn_cnt} 通, 平均 {avg}ms)')
            detail = '无整网全断, 多为部分探测点/线路抖动丢包而非封锁; 用户单线路不通可复测确认'
    else:
        lvl, code = 'PASS', 'NODE_PORT_CN_OK'
        title = f'NODE_PORT={node_port} 未被墙: 三网+云厂全通 (大陆 {cn_cnt}/{cn_cnt}, 平均 {avg}ms)'
        detail = '大陆方向未被墙; 海外为对照 (海外正常 + 大陆全断 = 被墙特征)'

    if not JSON_OUTPUT and (not QUIET or lvl != 'PASS'):
        print(f'{C_DIM}    ┌─ NODE_PORT={node_port} 分网 tcping 阻断明细 (状态 成功/总数){C_RESET}')
        print(_pe_table(segs), end='')
        print(f'{C_DIM}    └─ 海外为对照: 海外通 + 大陆断 = 被墙特征{C_RESET}')
    if car_s:
        title += f' [{car_s}]'
    result(lvl, code, title, detail)

    # 6) 交叉验证 — 随机开临时新端口再测一轮
    if ENV.get('NODE_CN_TCPING_XCHECK', '1') == '0':
        return
    if not is_local:
        note(f'远程目标模式: 跳过随机端口交叉验证 (临时监听需开在目标机; '
             f'完整验证用 --host {ENV.get("NODE_TARGET_IP") or host} 在节点上跑)')
        return
    okmain = 0
    if code == 'NODE_PORT_CN_BLOCKED':
        pass
    elif code == 'NODE_PORT_CN_PARTIAL':
        if not dead_main:
            return
    elif code == 'NODE_PORT_CN_OK':
        okmain = 1  # 自检模式: 原端口通, 仍测新端口验证测试逻辑
    else:
        return

    # 选随机临时端口 (20000-60000): 避开 NODE_PORT 与当前已监听端口
    xc_port = int(time.time()) % 40000 + 20000
    for _ in range(20):
        if str(xc_port) != node_port and not port_listening(xc_port, tcp_only=True):
            break
        xc_port += 1
        if xc_port > 60000:
            xc_port = 20000

    # 起临时监听: 进程内 daemon 线程 (原为 timeout+python3/socat 子进程; 同步 bind,
    # 失败即知 — 原"等就绪"轮询与 CN_XCHECK_NO_LISTENER 分支随之取消)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(('0.0.0.0', xc_port))
        srv.listen(16)
    except OSError:
        result('WARN', 'CN_XCHECK_LISTEN_FAIL', f'临时端口 {xc_port} 监听启动失败, 跳过交叉验证',
               '可能端口被占/权限不足; 重跑或人工验证')
        return

    def _accept_loop():
        try:
            while True:
                conn, _ = srv.accept()
                conn.close()
        except OSError:
            pass

    threading.Thread(target=_accept_loop, daemon=True).start()
    try:
        time.sleep(4)  # 与主测间隔, 避免限流
        xc_tgt = f'[{host}]:{xc_port}' if ':' in host else f'{host}:{xc_port}'
        r2 = pe_probe(xc_tgt, '验证新端口')
    finally:
        srv.close()
    if r2 is None:
        return

    segs2 = r2['segs']
    car2 = _pe_carrier_compact(segs2)
    dead_new = _pe_dead_nets(segs2)
    xc_sum = f'交叉验证新端口 {xc_port} 分网: [{car2 or "无数据"}]'

    # 无有效数据 / 新端口全球全断 → 无法判定 (防火墙/安全组拦临时端口, 不误报)
    if r2['t'] == 0 or (r2['cnok'] + r2['cnfail']) == 0 \
       or (r2['ok'] == 0 and r2['fail'] > 0):
        xc_lvl, xc_code = 'WARN', 'CN_XCHECK_INCONCLUSIVE'
        xc_title = (f'交叉验证无法判定: 新端口 {xc_port} 全球 {r2["fail"]}/{r2["t"]} 全部失败 '
                    f'→ 疑似本机防火墙/云安全组未放行临时端口')
        xc_detail = (f'云安全组默认只放行业务端口, 临时端口全球不通属预期, 不能据此判 IP 被墙。'
                     f'想精确验证: 控制台临时放行 {xc_port}/tcp 后重跑, 或人工 https://tcp.ping.pe/{xc_tgt} 复核')
    elif okmain:
        # 场景 B 自检 (原端口大陆全通): 新开随机端口理应同样可达
        if r2['cnfail'] == 0:
            xc_lvl, xc_code = 'PASS', 'CN_XCHECK_SELFTEST_OK'
            xc_title = (f'交叉验证自检通过: 原端口 {node_port} 与随机新端口 {xc_port} 大陆均可达 '
                        f'(大陆 {r2["cnok"]}/{r2["cnok"]}, 海外 {r2["ok"]}/{r2["ok"] + r2["fail"]}) '
                        f'→ 新端口被墙测试逻辑可信')
            xc_detail = (f'新开端口与原端口结论一致, 「新端口测试是否被墙」的代码在本节点工作正常。{xc_sum}')
        else:
            dead_part = f' (整网全断: {" ".join(dead_new)})' if dead_new else ''
            xc_lvl, xc_code = 'WARN', 'CN_XCHECK_SELFTEST_CONFLICT'
            xc_title = (f'交叉验证自相矛盾: 原端口 {node_port} 大陆全通, 新开随机端口 {xc_port} 却大陆 '
                        f'{r2["cnfail"]}/{r2["cnok"] + r2["cnfail"]} 失败 (海外 {r2["ok"]} 正常){dead_part}')
            xc_detail = (f'新开端口未被任何业务使用, 理论上不会被针对性封锁 → 两种可能: ① 随机高端口段恰被 '
                         f'IDC/防火墙/中间设备拦截, 或 ping.pe 大陆探测点抖动误报 ② 【新端口被墙测试】代码本身'
                         f'存在 bug。建议: 换个时段重跑交叉验证, 并人工 https://tcp.ping.pe/{xc_tgt} 复核对照。{xc_sum}')
    else:
        # 逐网对照: 主测全断的网在新端口的表现 → 恢复 / 仍断
        still = [n for n in dead_main if n in dead_new]
        rec = [n for n in dead_main if n not in dead_new]
        still_s, rec_s = ' '.join(still), ' '.join(rec)
        if rec and not still:
            xc_lvl, xc_code = 'PASS', 'NODE_PORT_CN_XCHECK_PORT'
            xc_title = (f'交叉验证: 属【端口级被墙】— 新端口 {xc_port} 大陆可达 (原全断的 {rec_s} 均恢复) '
                        f'→ 仅 NODE_PORT={node_port} 被封, IP 未整段被墙')
            xc_detail = f'换端口即可恢复: 面板改配/重跑 proxyInstall.sh 换 node_port, 无需换 IP。{xc_sum}'
        elif still and not rec:
            if r2['cnok'] == 0:
                xc_lvl, xc_code = 'FAIL', 'NODE_PORT_CN_IP_BLOCKED'
                xc_title = (f'交叉验证: 属【IP 级被墙】— 新端口 {xc_port} 大陆亦全断 ({still_s}), '
                            f'而海外 {r2["ok"]}/{r2["fail"]} 正常 → 整个 IP 的大陆方向被封')
                xc_detail = (f'换端口无效。处置: ① 套 CDN/中转 ② 联系机房换 IP ③ 多时段人工复核 '
                             f'https://tcp.ping.pe/{xc_tgt}。{xc_sum}')
            else:
                xc_lvl, xc_code = 'WARN', 'NODE_PORT_CN_XCHECK_IP'
                xc_title = f'交叉验证: {still_s} 对新旧端口均全断 → 该网封锁针对整个 IP (网级), 其余网正常'
                xc_detail = f'受影响网用户需 CDN/中转或换 IP; 其余网不受影响。{xc_sum}'
        elif still:
            xc_lvl, xc_code = 'WARN', 'NODE_PORT_CN_XCHECK_MIXED'
            xc_title = (f'交叉验证: 混合封锁 — {still_s} 新端口仍全断 (IP级/网级), '
                        f'{rec_s} 新端口恢复 (端口级)')
            xc_detail = f'部分网仅封原端口 (换端口可救), 部分网封整个 IP (需 CDN/中转或换 IP)。{xc_sum}'
        else:
            xc_lvl, xc_code = 'WARN', 'CN_XCHECK_INCONCLUSIVE'
            xc_title = '交叉验证结果异常 (主测全断网在新端口无对照数据), 无法判定端口级/IP级'
            xc_detail = f'人工在 https://tcp.ping.pe/{xc_tgt} 复核'

    if not JSON_OUTPUT and (not QUIET or xc_lvl != 'PASS'):
        print(f'{C_DIM}    ┌─ 交叉验证: 随机新端口 {xc_port} 分网 tcping 明细 (状态 成功/总数){C_RESET}')
        print(_pe_table(segs2), end='')
        if okmain:
            print(f'{C_DIM}    └─ 自检: 新端口理应与原端口同样大陆可达; 若新端口断而原端口通 → 测试结果存疑{C_RESET}')
        else:
            print(f'{C_DIM}    └─ 对照上表: 新端口通 → 端口级封锁 (换端口可救); 新端口大陆也断 → IP 级封锁{C_RESET}')
    result(xc_lvl, xc_code, xc_title, xc_detail)


# ============================================================
# 出站连通性 (outbound) — 2026-08-05, 38.45.72.223 核心经验
#
# 真实故障: 代理"完全无法使用", 但常规检查全部 PASS (服务 active / 端口监听 /
#   TLS 握手+认证 accepted / 证书有效 / ping·traceroute·curl(默认IPv6)·DNS 全正常)。
# 根因: 服务器【出站 IPv4 TCP 的 80/443】被上游精准封锁 (IPv6·ICMP·DNS 全正常 →
#   极度隐蔽), 而 xray freedom domainStrategy=UseIPv4v6 强制优先 IPv4 → 所有网页
#   拨号超时 → 代理 accept 连接但无法回传任何数据。
# 教训: "端口在监听 + TLS 握手成功" ≠ "代理可用"。必须主动测出站 IPv4 web 端口,
#   且必须强制 IPv4 (否则 Happy Eyeballs 自动走 IPv6 把故障完全掩盖)。
#   (curl 的 -4/-6 强制地址族无 urllib 等价物, 此处保留 curl 子进程)
# ============================================================
def check_outbound():
    say('出站连通性 (IPv4/IPv6 web 端口 + freedom domainStrategy)')

    if not has('curl'):
        result('WARN', 'OUTBOUND_NO_CURL', '无 curl, 跳过出站连通性测试')
        return

    def curl_code(family, url):
        rc, out, _ = run(['curl', family, '-k', '--connect-timeout', '6', '--max-time', '10',
                          '-s', '-o', '/dev/null', '-w', '%{http_code}', url], timeout=20)
        return out.strip() or '000'

    v4 = curl_code('-4', 'https://1.1.1.1')
    v6 = curl_code('-6', 'https://[2606:4700:4700::1111]')

    # 读 freedom 出站 domainStrategy (原生 json, 免 jq)
    ds = ''
    cfg = load_json_file(XRAY_CONF)
    if isinstance(cfg, dict) and isinstance(cfg.get('outbounds'), list):
        for ob in cfg['outbounds']:
            if isinstance(ob, dict) and ob.get('protocol') == 'freedom':
                v = ((ob.get('settings') or {}).get('domainStrategy')) if isinstance(ob.get('settings'), dict) else ''
                if v:
                    ds = v
                    break

    if v4 != '000':
        result('PASS', 'OUTBOUND_V4_OK', f'IPv4 出站 web(443) 可达 (http_code={v4})')
    if v6 != '000':
        result('PASS', 'OUTBOUND_V6_OK', f'IPv6 出站 web(443) 可达 (http_code={v6})')

    if v4 == '000' and v6 != '000':
        # IPv4 web 被封但 IPv6 正常 (38.45.72.223 精确症状)
        if ds in ('UseIPv4', 'UseIPv4v6'):
            result('FAIL', 'OUTBOUND_V4_BLOCKED_XRAY_FORCES_V4',
                   f'出站 IPv4 web(80/443) 被封锁, 但 freedom domainStrategy={ds} 强制用 IPv4 → 代理无法转发任何数据',
                   '现象: 服务/端口/TLS握手/认证全 PASS, 唯独客户端收不到响应数据; curl 默认走 IPv6 故巡检看似正常(极具迷惑性)。修复: domainStrategy 改 UseIPv6 (本次已验证可恢复), 并联系机房查 IPv4 出站 80/443 为何被封')
        else:
            result('WARN', 'OUTBOUND_V4_BLOCKED',
                   f'出站 IPv4 web(80/443) 被封锁, IPv6 正常 (domainStrategy={ds or "未知"})',
                   '若代理异常, 把 freedom domainStrategy 改 UseIPv6 可绕过; 联系机房查 IPv4 出站封禁')
    elif v4 == '000' and v6 == '000':
        result('FAIL', 'OUTBOUND_ALL_BLOCKED', 'IPv4 与 IPv6 出站 web 端口均不通',
               '代理完全无法转发数据。检查本机网络/上游路由/机房封禁/iptables OUTPUT')

    if ds:
        result('PASS', 'OUTBOUND_DS_READ', f'freedom domainStrategy = {ds}')


# ============================================================
# 本周期流量 (traffic) — vnstat tx × NODE_TRAFFIC_RESETDAY
#   定义: 从【上一个 NODE_TRAFFIC_RESETDAY】(含当天) 到今天的 tx 出站流量。
#   原生 datetime/calendar 取代原手写月份/闰年整数运算; 只累加 tx (与面板计费口径
#   一致), 多网卡求和; 配 NODE_TRAFFIC_LIMIT (GB, 1000 进制) 时限额对比。
# ============================================================
def check_traffic():
    say('本周期流量 (vnstat tx, 自上一个 NODE_TRAFFIC_RESETDAY 起)')

    # T1. 前置依赖: vnstat (jq 依赖已由原生 json 取代)
    if not has('vnstat'):
        result('WARN', 'TRAFFIC_VNSTAT_MISSING', '未安装 vnstat, 无法统计本周期流量',
               '安装: apt install -y vnstat && systemctl enable --now vnstat (运行一段时间后才有数据)')
        return

    env_home = os.path.join(HOME, '.env')

    # T2. 解析 NODE_TRAFFIC_RESETDAY (~/.env 最后一行优先, 同面板后写覆盖语义)
    rd_raw = env_file_read(env_home, 'NODE_TRAFFIC_RESETDAY') \
        or (ENV.get('NODE_TRAFFIC_RESETDAY') or '')
    rd_raw = rd_raw.lstrip('0')
    rd = to_int(rd_raw if rd_raw else '0', 0)
    if not 1 <= rd <= 31:
        result('WARN', 'TRAFFIC_RESETDAY_INVALID',
               f"~/.env 未配置有效的 NODE_TRAFFIC_RESETDAY (当前: '{ENV.get('NODE_TRAFFIC_RESETDAY') or '未设置'}', 需 1-31)",
               '在 ~/.env 写入 NODE_TRAFFIC_RESETDAY=<1-31> (每月流量重置日) 后重跑')
        return

    # T3. 周期起点 = 上一个重置日 (datetime/calendar, 免 GNU date)
    today = datetime.date.today()
    y, m = today.year, today.month
    if today.day < rd:
        m -= 1
        if m == 0:
            m, y = 12, y - 1
    sd = min(rd, calendar.monthrange(y, m)[1])  # 重置日 31 遇 2 月 → 28/29
    start = datetime.date(y, m, sd)
    start_ymd = f'{y:04d}-{m:02d}-{sd:02d}'
    start_cn = f'{m}月{sd}号'

    # T4. vnstat 每日库求和: 只取 tx, 日期 ≥ 周期起点, 多网卡求和
    vn_raw = run_out(['vnstat', '--json', 'd'])
    vn = None
    try:
        vn = json.loads(vn_raw) if vn_raw.strip() else None
    except ValueError:
        vn = None
    if not isinstance(vn, dict) or not isinstance(vn.get('interfaces'), list):
        result('WARN', 'TRAFFIC_VNSTAT_NOJSON', 'vnstat --json d 无有效输出',
               '检查 vnstat 数据库 (ls /var/lib/vnstat/) 与服务: systemctl status vnstat')
        return
    sum_tx = 0
    names, min_day = [], None
    for itf in vn['interfaces']:
        if not isinstance(itf, dict):
            continue
        names.append(str(itf.get('name') or ''))
        traffic = itf.get('traffic')
        for day in (traffic or {}).get('day') or []:
            if not isinstance(day, dict):
                continue
            d = day.get('date') or {}
            ymd = f"{to_int(d.get('year'), 0):04d}-{to_int(d.get('month'), 0):02d}-{to_int(d.get('day'), 0):02d}"
            if ymd >= start_ymd:
                sum_tx += to_int(day.get('tx'), 0)
            if min_day is None or ymd < min_day:
                min_day = ymd

    # T5. 可读化 + 周期天数/日均
    gib = sum_tx / 1073741824
    gb = sum_tx / 1000000000
    days = (today - start).days
    if days < 0:
        days = 0

    # T6. 主结论 (信息性 → PASS; 重置日几月几号必列)
    detail = (f'只统计 tx 出站, rx 不计入; 周期 = 上一个 NODE_TRAFFIC_RESETDAY ({rd} 号) '
              f'{start_ymd} (含当天) → 今天')
    if days > 0:
        detail += f', 已 {days} 天, 日均 tx {gib / days:.2f} GiB'
    detail += f"; vnstat 网卡[{','.join(names)}], 原始值 {sum_tx} B"
    result('PASS', 'TRAFFIC_TX_CYCLE',
           f'本周期 tx 出站流量: {gib:.2f} GiB (上次重置日: {start_cn}, {start_ymd})', detail)

    # T7. 覆盖完整性 — 每日库最早记录晚于周期起点 → 统计偏小
    if min_day and min_day > start_ymd:
        result('WARN', 'TRAFFIC_DAILY_COVERAGE',
               f'vnstat 每日库最早仅到 {min_day}, 晚于周期起点 {start_ymd} → 上述 tx 偏小',
               'vnstat 只保留最近若干天明细, 周期前段已被滚动清理。调大 /etc/vnstat.conf 的 DailyDays 后 systemctl restart vnstat (更早的历史已不可恢复)')

    # T8. 数据新鲜度 — vnstatd 超 1 天未写库 → 统计失真
    upd = 0
    for itf in vn['interfaces']:
        if isinstance(itf, dict):
            u = ((itf.get('updated') or {}).get('timestamp'))
            if isinstance(u, int) and u > upd:
                upd = u
    if upd:
        age = int(time.time()) - upd
        if age > 86400:
            last = datetime.datetime.fromtimestamp(upd).strftime('%F %T')
            result('WARN', 'TRAFFIC_VNSTAT_STALE',
                   f'vnstat 数据已 {age // 3600} 小时未刷新 (最后: {last})',
                   'vnstatd 可能已停: systemctl status vnstat; systemctl restart vnstat')

    # T9. 限额对比 — NODE_TRAFFIC_LIMIT (GB, 1000 进制); ≥80% 提醒, ≥100% 告警
    lim_raw = env_file_read(env_home, 'NODE_TRAFFIC_LIMIT') or (ENV.get('NODE_TRAFFIC_LIMIT') or '')
    lim_raw = lim_raw.lstrip('0')
    lim = to_int(lim_raw if lim_raw else '0', 0)
    if lim > 0:
        pct = sum_tx / (lim * 1000000000) * 100
        if sum_tx >= lim * 1000000000:
            result('WARN', 'TRAFFIC_LIMIT_EXCEEDED',
                   f'本周期 tx {gb:.2f} GB 已达限额 NODE_TRAFFIC_LIMIT={lim} GB 的 {pct:.1f}%',
                   f'超限节点可能被面板停机/额外计费; 控制用户量或升级套餐; 下次重置: 下月 {rd} 号')
        elif sum_tx >= lim * 1000000000 * 0.8:
            result('WARN', 'TRAFFIC_LIMIT_NEAR',
                   f'本周期 tx 已用限额 {pct:.1f}% ({gb:.2f}/{lim} GB)',
                   '用量超八成, 提前规划 (控制用户/升级套餐)')


# ============================================================
# TLS 证书专项 (cert) — 只检查【在用】证书, 不做全盘扫描:
#   1. ~/node.json 中 root_domain 对应的证书 (按 CN/SAN 匹配定位)
#   2. nginx *.conf 声明 ssl_certificate 引用的证书
# ============================================================
def check_cert():
    say('TLS 证书专项 (root_domain + nginx .conf 引用证书)')

    rd = ''
    nj = load_json_file(os.path.join(HOME, 'node.json'))
    if isinstance(nj, dict) and nj.get('root_domain'):
        rd = str(nj['root_domain'])
    if not rd:
        result('WARN', 'CERT_NO_ROOT_DOMAIN', f'{HOME}/node.json 无 root_domain, 跳过主域证书检查',
               f'确认 {HOME}/node.json 是否存在且含 root_domain 字段; 或手动 openssl x509 -checkend 0 -noout -in <cert>')
    else:
        hit = False
        patterns = (f'CN={rd}', f'CN = {rd}', f'DNS:{rd}', f'DNS:*.{rd}',
                    f'CN=*.{rd}', f'CN = *.{rd}')
        for d in ('/etc/letsencrypt/live', '/root/.acme.sh', '/etc/nginx/ssl',
                  '/etc/ssl', '/usr/local/etc/xray', XRAY_DIR):
            if not os.path.isdir(d):
                continue
            for c in find_files(d, ('*.pem', '*.crt', '*.cer'), maxdepth=3):
                if c.startswith('/etc/ssl/certs/'):  # CA 信任库, 非本站证书
                    continue
                try:
                    with open(c, 'r', errors='replace') as fh:
                        if 'BEGIN CERTIFICATE' not in fh.read():
                            continue
                except OSError:
                    continue
                ident = run_out(['openssl', 'x509', '-in', c, '-noout', '-subject']).strip()
                text = run_out(['openssl', 'x509', '-in', c, '-noout', '-text'])
                text_lines = text.splitlines()
                for idx, line in enumerate(text_lines):
                    if 'Subject Alternative Name' in line:
                        ident += ' ' + ' '.join(text_lines[idx:idx + 2])
                        break
                if any(p in ident for p in patterns):
                    hit = True
                    check_cert_file(c, 'CERT_ROOT_DOMAIN')
        if not hit:
            result('WARN', 'CERT_ROOT_DOMAIN_NOT_FOUND', f'未找到 root_domain={rd} 的本地证书',
                   '若证书在其它路径, 手动 openssl x509 -checkend 0 -noout -in <cert>; 若节点未用本地证书 (如 reality/自签) 可忽略')

    # C2. nginx *.conf 引用的证书 (与 N5 共用, 按路径去重)
    check_nginx_certs()


# ============================================================
# 汇总输出
# ============================================================
def summary():
    if JSON_OUTPUT:
        obj = {
            'target': TARGET,
            'totals': {'pass': _counts['PASS'], 'warn': _counts['WARN'], 'fail': _counts['FAIL']},
            'results': RESULTS,
        }
        print(json.dumps(obj, ensure_ascii=False, separators=(',', ':')))
    else:
        say('诊断汇总')
        print(f"  通过 {C_GREEN}{_counts['PASS']}{C_RESET}   "
              f"警告 {C_YELLOW}{_counts['WARN']}{C_RESET}   "
              f"失败 {C_RED}{_counts['FAIL']}{C_RESET}")
        if _counts['FAIL'] > 0:
            print(f"{C_RED}  → 有 {_counts['FAIL']} 项故障, 优先处理 FAIL 项{C_RESET}")
        else:
            print(f"{C_GREEN}  → 未发现阻断性故障{C_RESET}")


# ============================================================
# 主流程 — 按目标分发; 每项检查独立 (内部异常 → INTERNAL_* 结果, 绝不中断其它检查)
# ============================================================
def main():
    checks = {
        'env': check_env,
        'xray': check_xray,
        'nginx': check_nginx,
        'cert': check_cert,
        'net': check_net,
        'outbound': check_outbound,
        'traffic': check_traffic,
    }
    order = ('env', 'xray', 'nginx', 'cert', 'net', 'outbound', 'traffic') \
        if TARGET == 'all' else (TARGET,)
    for key in order:
        try:
            checks[key]()
        except Exception as e:  # noqa: BLE001 — 诊断脚本必须每项独立
            result('WARN', f'INTERNAL_{key.upper()}',
                   f'检查项 {key} 内部异常 (诊断工具自身问题, 其余检查不受影响)', repr(e))
    summary()
    notify_tg()


if __name__ == '__main__':
    main()
    # 退出码 = 失败数 (上限 99), 便于上层脚本/监控判断
    sys.exit(min(_counts['FAIL'], 99))
