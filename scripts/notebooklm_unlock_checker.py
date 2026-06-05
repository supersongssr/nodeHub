#!/usr/bin/env python3
"""
NotebookLM Unlock Checker - 深度双栈检测工具（防假阳性版）

功能：
1. 分别检测 IPv4 和 IPv6 对 NotebookLM 的访问权限
2. 收集响应指纹（页面标题、拦截特征）排除假阳性
3. IP 归属地校验
4. 生成详细 JSON 报告

依赖：仅使用 Python 原生库
"""

import urllib.request
import urllib.error
import socket
import http.client
import json
import os
import sys
import re
from html.parser import HTMLParser


class TitleExtractor(HTMLParser):
    """HTML 标题提取器"""

    def __init__(self):
        super().__init__()
        self.title = ""
        self.in_title = False

    def handle_starttag(self, tag, attrs):
        if tag == 'title':
            self.in_title = True

    def handle_data(self, data):
        if self.in_title:
            self.title += data

    def handle_endtag(self, tag):
        if tag == 'title':
            self.in_title = False


class IPv4HTTPConnection(http.client.HTTPConnection):
    """强制使用 IPv4 的 HTTP 连接"""

    def connect(self):
        addr_infos = socket.getaddrinfo(
            self.host, self.port,
            family=socket.AF_INET,
            type=socket.SOCK_STREAM
        )
        if not addr_infos:
            raise OSError("No IPv4 address available")
        af, socktype, proto, canonname, sa = addr_infos[0]
        self.sock = socket.socket(af, socktype, proto)
        if self.timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
            self.sock.settimeout(self.timeout)
        if self.source_address:
            self.sock.bind(self.source_address)
        self.sock.connect(sa)


class IPv6HTTPConnection(http.client.HTTPConnection):
    """强制使用 IPv6 的 HTTP 连接"""

    def connect(self):
        try:
            addr_infos = socket.getaddrinfo(
                self.host, self.port,
                family=socket.AF_INET6,
                type=socket.SOCK_STREAM
            )
        except socket.gaierror as e:
            raise OSError(f"No IPv6 address available: {e}")
        if not addr_infos:
            raise OSError("No IPv6 address available")
        af, socktype, proto, canonname, sa = addr_infos[0]
        self.sock = socket.socket(af, socktype, proto)
        if self.timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
            self.sock.settimeout(self.timeout)
        if self.source_address:
            self.sock.bind(self.source_address)
        self.sock.connect(sa)


class IPv4HTTPSConnection(http.client.HTTPSConnection):
    """强制使用 IPv4 的 HTTPS 连接"""

    def connect(self):
        addr_infos = socket.getaddrinfo(
            self.host, self.port,
            family=socket.AF_INET,
            type=socket.SOCK_STREAM
        )
        if not addr_infos:
            raise OSError("No IPv4 address available")
        af, socktype, proto, canonname, sa = addr_infos[0]
        self.sock = socket.socket(af, socktype, proto)
        if self.timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
            self.sock.settimeout(self.timeout)
        if self.source_address:
            self.sock.bind(self.source_address)
        self.sock.connect(sa)
        if self._tunnel_host:
            self._tunnel()
        context = getattr(self, '_context', None)
        if context is None:
            import ssl
            context = ssl.create_default_context()
        self.sock = context.wrap_socket(self.sock, server_hostname=self.host)


class IPv6HTTPSConnection(http.client.HTTPSConnection):
    """强制使用 IPv6 的 HTTPS 连接"""

    def connect(self):
        try:
            addr_infos = socket.getaddrinfo(
                self.host, self.port,
                family=socket.AF_INET6,
                type=socket.SOCK_STREAM
            )
        except socket.gaierror as e:
            raise OSError(f"No IPv6 address available: {e}")
        if not addr_infos:
            raise OSError("No IPv6 address available")
        af, socktype, proto, canonname, sa = addr_infos[0]
        self.sock = socket.socket(af, socktype, proto)
        if self.timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
            self.sock.settimeout(self.timeout)
        if self.source_address:
            self.sock.bind(self.source_address)
        self.sock.connect(sa)
        if self._tunnel_host:
            self._tunnel()
        context = getattr(self, '_context', None)
        if context is None:
            import ssl
            context = ssl.create_default_context()
        self.sock = context.wrap_socket(self.sock, server_hostname=self.host)


class IPv4HTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(IPv4HTTPConnection, req)


class IPv6HTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(IPv6HTTPConnection, req)


class IPv4HTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(IPv4HTTPSConnection, req)


class IPv6HTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(IPv6HTTPSConnection, req)


def extract_page_title(html_content):
    """
    从 HTML 内容中提取页面标题

    Args:
        html_content: HTML 内容

    Returns:
        str: 页面标题，提取失败返回空字符串
    """
    try:
        parser = TitleExtractor()
        parser.feed(html_content)
        return parser.title.strip()
    except Exception:
        # 如果解析失败，使用正则表达式备用方案
        match = re.search(r'<title[^>]*>(.*?)</title>', html_content, re.IGNORECASE | re.DOTALL)
        if match:
            return match.group(1).strip()
        return ""


def check_google_intercept_features(html_content):
    """
    检查 Google 拦截特征（优化版，排除误报）

    Args:
        html_content: HTML 内容（小写）

    Returns:
        list: 发现的拦截特征列表
    """
    features = []

    # 这些是真正的拦截特征（不包含普通的 recaptcha 脚本引用）
    intercept_patterns = [
        ("google.com/sorry/index", "Google CAPTCHA/Verification page"),
        ("sorry/index", "Google Verification page"),
        ("unusual traffic", "Unusual traffic detected"),
        ("service unavailable", "Service Unavailable"),
        ("403 forbidden", "403 Forbidden"),
        ("access denied", "Access Denied"),
        ("verify you are human", "Human verification required"),
        ("our systems have detected unusual traffic", "Unusual traffic warning"),
        ("please verify you are a human", "Human verification"),
        ("one more step", "One more step verification"),
        ("traffic from your network seems unusual", "Unusual traffic pattern"),
    ]

    for pattern, description in intercept_patterns:
        if pattern in html_content:
            features.append(description)

    # 特殊检查：如果页面主要内容是 captcha 验证（而不是登录页面）
    # 通过检查是否包含大段验证相关的文本
    if "recaptcha" in html_content and "unusual traffic" in html_content:
        features.append("reCAPTCHA challenge with unusual traffic warning")

    return features


def get_ip_location(ip, timeout=10):
    """
    查询 IP 归属地

    Args:
        ip: IP 地址
        timeout: 请求超时时间（秒）

    Returns:
        dict: 包含 country, countryCode 等信息的字典
    """
    # 如果是 IPv6 not available 标记，返回特殊值
    if ip == "IPv6 not available" or ip.startswith("Error:"):
        return {
            "country": "N/A",
            "countryCode": "N/A",
            "status": ip
        }

    url = f"http://ip-api.com/json/{ip}?fields=country,countryCode,status,message"
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    }

    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as response:
            data = json.loads(response.read().decode('utf-8'))

            if data.get('status') == 'success':
                return {
                    "country": data.get('country', 'Unknown'),
                    "countryCode": data.get('countryCode', 'Unknown'),
                    "status": "success"
                }
            else:
                return {
                    "country": "Unknown",
                    "countryCode": "Unknown",
                    "status": f"API Error: {data.get('message', 'Unknown error')}"
                }
    except Exception as e:
        return {
            "country": "Unknown",
            "countryCode": "Unknown",
            "status": f"Error: {str(e)}"
        }


def get_public_ip(ip_version='4', timeout=10):
    """
    获取公网 IP 地址

    Args:
        ip_version: '4' for IPv4, '6' for IPv6
        timeout: 请求超时时间（秒）

    Returns:
        str: IP 地址或错误信息
    """
    url = "https://ifconfig.me/ip"
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }

    try:
        if ip_version == '4':
            opener = urllib.request.build_opener(IPv4HTTPHandler, IPv4HTTPSHandler)
        else:
            opener = urllib.request.build_opener(IPv6HTTPHandler, IPv6HTTPSHandler)

        req = urllib.request.Request(url, headers=headers)
        with opener.open(req, timeout=timeout) as response:
            ip = response.read().decode('utf-8', errors='ignore').strip()
            return ip
    except Exception as e:
        error_msg = str(e)
        # 判断是否为 IPv6 不可用
        if ip_version == '6' and ('No IPv6 address available' in error_msg or
                                   'Address family' in error_msg or
                                   'Network is unreachable' in error_msg or
                                   'EAI_ADDRFAMILY' in error_msg or
                                   'EAI_NONAME' in error_msg or
                                   'gaierror' in error_msg):
            return "IPv6 not available"
        return f"Error: {error_msg}"


def check_notebooklm_access(ip_version='4', timeout=10):
    """
    检测 NotebookLM 访问权限（带证据收集）

    Args:
        ip_version: '4' for IPv4, '6' for IPv6
        timeout: 请求超时时间（秒）

    Returns:
        dict: 包含详细访问状态的字典
    """
    url = "https://notebooklm.google.com/"
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
    }

    result = {
        'status_code': None,
        'access_status': 'unknown',
        'error': None,
        'page_title': None,
        'intercept_features': [],
        'is_fake_positive': False,
        'evidence': {}
    }

    try:
        # 创建指定 IP 版本的 opener
        if ip_version == '4':
            opener = urllib.request.build_opener(IPv4HTTPHandler, IPv4HTTPSHandler)
        else:
            opener = urllib.request.build_opener(IPv6HTTPHandler, IPv6HTTPSHandler)

        req = urllib.request.Request(url, headers=headers)

        with opener.open(req, timeout=timeout) as response:
            result['status_code'] = response.getcode()
            html_content = response.read().decode('utf-8', errors='ignore')

            # 提取页面标题
            result['page_title'] = extract_page_title(html_content)
            result['evidence']['page_title'] = result['page_title']

            # 转为小写用于关键词检测
            html_lower = html_content.lower()

            # 检测 Google 拦截特征
            result['intercept_features'] = check_google_intercept_features(html_lower)
            result['evidence']['intercept_features'] = result['intercept_features']

            # 检测地区限制关键词
            restricted_keywords = [
                "not available in your country",
                "not currently available in your country",
                "notebooklm is not available",
                "notebooklm is not currently available",
                "this service is not available in your country"
            ]

            is_restricted = any(kw in html_lower for kw in restricted_keywords)
            result['evidence']['region_restricted'] = is_restricted

            # 检测是否为假阳性
            # 条件1: 有拦截特征
            if result['intercept_features']:
                result['is_fake_positive'] = True
                result['access_status'] = 'intercepted'
                result['evidence']['fake_positive_reason'] = f"Intercepted by: {', '.join(result['intercept_features'])}"

            # 条件2: 标题包含错误信息
            elif result['page_title'] and any(err in result['page_title'].lower() for err in
                                                ['error', '403', 'forbidden', 'blocked', 'unavailable']):
                result['is_fake_positive'] = True
                result['access_status'] = 'error_page'
                result['evidence']['fake_positive_reason'] = f"Error page detected: {result['page_title']}"

            # 条件3: 地区限制
            elif is_restricted:
                result['access_status'] = 'region_restricted'
                result['evidence']['fake_positive_reason'] = "Region restricted content detected"

            # 条件4: 正常可用
            elif result['status_code'] == 200:
                result['access_status'] = 'available'

                # 二次验证：检查标题是否真的像 NotebookLM
                if result['page_title']:
                    title_lower = result['page_title'].lower()
                    if 'notebooklm' in title_lower or 'notebook' in title_lower:
                        result['evidence']['title_verification'] = "Pass: Title contains NotebookLM"
                    elif 'sign in' in title_lower or 'login' in title_lower:
                        result['evidence']['title_verification'] = "Pass: Google Sign-in page"
                    else:
                        result['evidence']['title_verification'] = f"Warning: Unexpected title '{result['page_title']}'"
            else:
                result['access_status'] = f'abnormal_status_{result["status_code"]}'

    except urllib.error.HTTPError as e:
        result['status_code'] = e.code
        result['access_status'] = f'http_error_{e.code}'
        result['error'] = f'HTTP {e.code}'

        # 尝试读取错误页面内容
        try:
            error_content = e.read().decode('utf-8', errors='ignore')
            result['page_title'] = extract_page_title(error_content)
            result['evidence']['error_page_title'] = result['page_title']
        except:
            pass

    except urllib.error.URLError as e:
        error_msg = str(e.reason)
        # 判断是否为 IPv6 不可用
        if ip_version == '6' and ('No IPv6 address available' in error_msg or
                                   'Address family' in error_msg or
                                   'Network is unreachable' in error_msg or
                                   'gaierror' in str(type(e).__name__)):
            result['access_status'] = 'ipv6_not_available'
            result['error'] = 'IPv6 not available - ' + error_msg
        else:
            result['access_status'] = 'connection_failed'
            result['error'] = f'Network error: {e.reason}'

    except OSError as e:
        error_msg = str(e)
        # 判断是否为 IPv6 不可用
        if ip_version == '6' and ('No IPv6 address available' in error_msg or
                                   'Address family' in error_msg or
                                   'Network is unreachable' in error_msg or
                                   'gaierror' in error_msg):
            result['access_status'] = 'ipv6_not_available'
            result['error'] = f'IPv6 not available - {error_msg}'
        else:
            result['access_status'] = 'system_error'
            result['error'] = f'OSError: {error_msg}'

    except Exception as e:
        result['access_status'] = 'unknown_error'
        result['error'] = f'Unexpected error: {str(e)}'

    return result


def run_checks(timeout=10):
    """
    执行完整的双栈检测（深度版）

    Args:
        timeout: 请求超时时间（秒）

    Returns:
        dict: 包含详细检测结果的字典
    """
    print("NotebookLM Unlock Checker - Deep Dual-Stack Detection")
    print("=" * 70)

    results = {}

    # IPv4 检测
    print("\n[1/6] Checking IPv4 address...")
    ipv4_ip = get_public_ip('4', timeout)
    print(f"  IPv4 Address: {ipv4_ip}")

    print("[2/6] Querying IPv4 location...")
    ipv4_location = get_ip_location(ipv4_ip, timeout)
    print(f"  IPv4 Location: {ipv4_location.get('country', 'Unknown')} ({ipv4_location.get('countryCode', 'Unknown')})")

    print("[3/6] Checking NotebookLM access via IPv4...")
    ipv4_check = check_notebooklm_access('4', timeout)
    print(f"  IPv4 Status: {ipv4_check['access_status']}")
    if ipv4_check.get('page_title'):
        print(f"  Page Title: {ipv4_check['page_title'][:80]}")
    if ipv4_check.get('intercept_features'):
        print(f"  ⚠️  Intercept Features: {', '.join(ipv4_check['intercept_features'])}")

    results['ipv4'] = {
        'ip': ipv4_ip,
        'location': ipv4_location,
        'access_status': ipv4_check['access_status'],
        'status_code': ipv4_check['status_code'],
        'page_title': ipv4_check.get('page_title'),
        'intercept_features': ipv4_check.get('intercept_features', []),
        'is_fake_positive': ipv4_check.get('is_fake_positive', False),
        'error': ipv4_check.get('error'),
        'evidence': ipv4_check.get('evidence', {})
    }

    # IPv6 检测
    print("\n[4/6] Checking IPv6 address...")
    ipv6_ip = get_public_ip('6', timeout)
    print(f"  IPv6 Address: {ipv6_ip}")

    print("[5/6] Querying IPv6 location...")
    ipv6_location = get_ip_location(ipv6_ip, timeout)
    print(f"  IPv6 Location: {ipv6_location.get('country', 'Unknown')} ({ipv6_location.get('countryCode', 'Unknown')})")

    print("[6/6] Checking NotebookLM access via IPv6...")
    ipv6_check = check_notebooklm_access('6', timeout)
    print(f"  IPv6 Status: {ipv6_check['access_status']}")
    if ipv6_check.get('page_title'):
        print(f"  Page Title: {ipv6_check['page_title'][:80]}")
    if ipv6_check.get('intercept_features'):
        print(f"  ⚠️  Intercept Features: {', '.join(ipv6_check['intercept_features'])}")

    results['ipv6'] = {
        'ip': ipv6_ip,
        'location': ipv6_location,
        'access_status': ipv6_check['access_status'],
        'status_code': ipv6_check['status_code'],
        'page_title': ipv6_check.get('page_title'),
        'intercept_features': ipv6_check.get('intercept_features', []),
        'is_fake_positive': ipv6_check.get('is_fake_positive', False),
        'error': ipv6_check.get('error'),
        'evidence': ipv6_check.get('evidence', {})
    }

    # 判断总体状态
    ipv4_available = ipv4_check['access_status'] == 'available' and not ipv4_check.get('is_fake_positive', False)
    ipv6_available = ipv6_check['access_status'] == 'available' and not ipv6_check.get('is_fake_positive', False)

    if ipv4_available and ipv6_available:
        overall_status = 'yes - both IPv4 and IPv6 verified'
    elif ipv4_available:
        overall_status = 'yes - IPv4 available only'
    elif ipv6_available:
        overall_status = 'yes - IPv6 available only'
    else:
        overall_status = 'no - neither IPv4 nor IPv6 available'

    results['access_status'] = {
        'overall_status': overall_status,
        'ipv4_available': ipv4_available,
        'ipv6_available': ipv6_available
    }

    print("\n" + "=" * 70)
    print(f"Overall Status: {overall_status.upper()}")
    print("=" * 70)

    return results


def save_json_results(results, filename='notebooklm_check_result.json'):
    """
    保存检测结果到 JSON 文件

    Args:
        results: 检测结果字典
        filename: 输出文件名
    """
    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        output_path = os.path.join(script_dir, filename)

        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(results, f, indent=2, ensure_ascii=False)

        print(f"\n✅ JSON results saved to: {output_path}")
        return True
    except Exception as e:
        print(f"\n❌ Error saving JSON: {e}")
        return False


def main():
    """主函数"""
    try:
        # 执行检测
        results = run_checks(timeout=10)

        # 保存 JSON 结果
        save_json_results(results)

        # 打印详细总结
        print("\n📊 Detection Summary:")
        print("-" * 70)
        print(f"IPv4: {results['ipv4']['access_status']}")
        print(f"  ├─ IP: {results['ipv4']['ip']}")
        print(f"  ├─ Location: {results['ipv4']['location'].get('country', 'Unknown')}")
        print(f"  ├─ Page Title: {results['ipv4'].get('page_title', 'N/A')[:60]}")
        if results['ipv4'].get('intercept_features'):
            print(f"  └─ ⚠️  Intercepts: {', '.join(results['ipv4']['intercept_features'])}")
        else:
            print(f"  └─ No intercepts detected")

        print(f"\nIPv6: {results['ipv6']['access_status']}")
        print(f"  ├─ IP: {results['ipv6']['ip']}")
        print(f"  ├─ Location: {results['ipv6']['location'].get('country', 'Unknown')}")
        print(f"  ├─ Page Title: {results['ipv6'].get('page_title', 'N/A')[:60]}")
        if results['ipv6'].get('intercept_features'):
            print(f"  └─ ⚠️  Intercepts: {', '.join(results['ipv6']['intercept_features'])}")
        else:
            print(f"  └─ No intercepts detected")

        print("\n" + "=" * 70)
        print(f"NotebookLM Access: {results['access_status']['overall_status'].upper()}")
        print("=" * 70)

        # 返回退出码
        if results['access_status']['overall_status'].startswith('yes'):
            sys.exit(0)
        else:
            sys.exit(1)

    except KeyboardInterrupt:
        print("\n\nDetection interrupted by user.")
        sys.exit(130)
    except Exception as e:
        print(f"\n❌ Fatal error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(2)


if __name__ == "__main__":
    main()
