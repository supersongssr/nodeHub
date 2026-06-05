#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Google Scholar Access Checker
用于检测当前IP是否能访问Google Scholar的独立脚本（仅使用Python标准库）
"""

import json
import os
import random
import re
import socket
import sys
import time
from datetime import datetime
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

# 配置常量
SCHOLAR_URLS = {
    "main_page": "https://scholar.google.com",
    "search_page": "https://scholar.google.com/scholar?q=test+query",
    "citations_page": "https://scholar.google.com/citations",
}

# IP检测服务
IP_DETECTION_SERVICES = [
    "https://api.ipify.org?format=json",
    "https://httpbin.org/ip",
    "https://api.ip.sb/ip",
]

# 请求配置
REQUEST_TIMEOUT = 10
REQUEST_DELAY = (1, 3)  # 随机延迟1-3秒

# User-Agent列表
USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:121.0) Gecko/20100101 Firefox/121.0",
]

# CAPTCHA检测关键词
CAPTCHA_KEYWORDS = [
    "captcha",
    "unusual traffic",
    "automated requests",
    "prove you are human",
    "recaptcha",
    "g-recaptcha",
]

# 错误页面关键词
BLOCK_KEYWORDS = [
    "blocked",
    "access denied",
    "forbidden",
    "service unavailable",
    "rate limit",
    "too many requests",
]


def get_random_user_agent():
    """获取随机User-Agent"""
    return random.choice(USER_AGENTS)


def get_current_ip():
    """获取当前IP地址和基本信息"""
    ip_info = {
        "ip": None,
        "country": "Unknown",
        "city": "Unknown",
        "org": "Unknown",
        "is_proxy": False,
        "error": None,
    }

    for service in IP_DETECTION_SERVICES:
        try:
            req = Request(service, headers={"User-Agent": get_random_user_agent()})
            with urlopen(req, timeout=REQUEST_TIMEOUT) as response:
                if response.status == 200:
                    content = response.read().decode("utf-8")
                    if "json" in response.headers.get("content-type", ""):
                        # JSON响应
                        data = json.loads(content)
                        ip_info["ip"] = data.get("ip", data.get("origin", None))
                    else:
                        # 纯文本IP
                        ip_info["ip"] = content.strip()

                    if ip_info["ip"]:
                        break
        except Exception as e:
            continue

    if not ip_info["ip"]:
        ip_info["error"] = "Unable to detect IP address"
        return ip_info

    # 获取IP地理位置信息（使用免费的ipapi.co）
    try:
        geo_url = f"https://ipapi.co/{ip_info['ip']}/json/"
        req = Request(geo_url, headers={"User-Agent": get_random_user_agent()})
        with urlopen(req, timeout=REQUEST_TIMEOUT) as response:
            if response.status == 200:
                content = response.read().decode("utf-8")
                geo_data = json.loads(content)
                ip_info["country"] = geo_data.get("country_name", "Unknown")
                ip_info["city"] = geo_data.get("city", "Unknown")
                ip_info["org"] = geo_data.get("org", "Unknown")
    except:
        pass

    return ip_info


def detect_captcha(content):
    """检测是否包含CAPTCHA"""
    if not content:
        return False

    content_lower = content.lower()
    for keyword in CAPTCHA_KEYWORDS:
        if keyword in content_lower:
            return True

    # 检测CAPTCHA相关的HTML元素
    captcha_patterns = [
        r'<form[^>]*action="[^"]*captcha[^"]*"',
        r'class="[^"]*captcha[^"]*"',
        r'id="[^"]*captcha[^"]*"',
        r'src="[^"]*recaptcha[^"]*"',
    ]

    for pattern in captcha_patterns:
        if re.search(pattern, content, re.IGNORECASE):
            return True

    return False


def detect_block(content):
    """检测是否被阻止"""
    if not content:
        return False

    content_lower = content.lower()
    for keyword in BLOCK_KEYWORDS:
        if keyword in content_lower:
            return True

    # 检测错误页面标题
    title_patterns = [
        r"<title>[^<]*(?:access denied|blocked|forbidden|error)[^<]*</title>",
        r"<h1>[^<]*(?:access denied|blocked|forbidden)[^<]*</h1>",
    ]

    for pattern in title_patterns:
        if re.search(pattern, content, re.IGNORECASE):
            return True

    return False


def test_scholar_page(url):
    """测试单个Google Scholar页面"""
    result = {
        "url": url,
        "status_code": None,
        "accessible": False,
        "captcha_required": False,
        "blocked": False,
        "response_time_ms": None,
        "error": None,
        "title": None,
        "redirected": False,
        "final_url": None,
    }

    try:
        # 设置请求头
        headers = {
            "User-Agent": get_random_user_agent(),
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.5",
            "Accept-Encoding": "gzip, deflate",
            "DNT": "1",
            "Connection": "keep-alive",
            "Upgrade-Insecure-Requests": "1",
            "Cache-Control": "max-age=0",
        }

        req = Request(url, headers=headers)

        start_time = time.time()
        with urlopen(req, timeout=REQUEST_TIMEOUT) as response:
            end_time = time.time()

            result["status_code"] = response.status
            result["response_time_ms"] = round((end_time - start_time) * 1000)
            result["final_url"] = response.geturl()

            # 检测重定向
            if response.geturl() != url:
                result["redirected"] = True

            # 读取响应内容
            content = response.read().decode("utf-8", errors="ignore")

            # 获取页面标题
            title_match = re.search(r"<title>([^<]+)</title>", content, re.IGNORECASE)
            if title_match:
                result["title"] = title_match.group(1).strip()

            # 判断访问状态
            if response.status == 200:
                result["accessible"] = True

                # 检测CAPTCHA
                if detect_captcha(content):
                    result["captcha_required"] = True
                    result["accessible"] = False

                # 检测是否被阻止
                if detect_block(content):
                    result["blocked"] = True
                    result["accessible"] = False

            elif response.status in [403, 429, 503]:
                result["accessible"] = False
                if response.status == 429:
                    result["blocked"] = True

    except HTTPError as e:
        result["status_code"] = e.code
        result["accessible"] = False
        if e.code in [403, 429, 503]:
            if e.code == 429:
                result["blocked"] = True
    except URLError as e:
        result["error"] = f"URL Error: {str(e.reason)}"
    except socket.timeout:
        result["error"] = "Request timeout"
    except Exception as e:
        result["error"] = f"Unexpected error: {str(e)}"

    return result


def check_scholar_access():
    """主检测函数"""
    access_status = {
        "overall_status": "unknown",
        "details": {},
        "summary": {
            "total_checks": len(SCHOLAR_URLS),
            "successful_checks": 0,
            "captcha_detected": False,
            "blocked_detected": False,
            "average_response_time_ms": 0,
        },
    }

    response_times = []

    for page_name, url in SCHOLAR_URLS.items():
        print(f"Testing {page_name}...")
        result = test_scholar_page(url)
        access_status["details"][page_name] = result

        # 更新统计信息
        if result["accessible"]:
            access_status["summary"]["successful_checks"] += 1

        if result["captcha_required"]:
            access_status["summary"]["captcha_detected"] = True

        if result["blocked"]:
            access_status["summary"]["blocked_detected"] = True

        if result["response_time_ms"]:
            response_times.append(result["response_time_ms"])

        # 随机延迟
        if page_name != list(SCHOLAR_URLS.keys())[-1]:
            delay = random.uniform(REQUEST_DELAY[0], REQUEST_DELAY[1])
            time.sleep(delay)

    # 计算平均响应时间
    if response_times:
        access_status["summary"]["average_response_time_ms"] = round(
            sum(response_times) / len(response_times)
        )

    # 判断整体状态
    if access_status["summary"]["successful_checks"] == len(SCHOLAR_URLS):
        access_status["overall_status"] = "accessible"
    elif access_status["summary"]["captcha_detected"]:
        access_status["overall_status"] = "captcha"
    elif access_status["summary"]["successful_checks"] > 0:
        access_status["overall_status"] = "partial"
    elif access_status["summary"]["blocked_detected"]:
        access_status["overall_status"] = "blocked"
    else:
        access_status["overall_status"] = "restricted"

    return access_status


def save_results(data, filename="check_google_scholar_unlock.json"):
    """保存结果到JSON文件"""
    try:
        with open(filename, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        print(f"\n结果已保存到: {filename}")
    except Exception as e:
        print(f"保存文件失败: {e}")


def main():
    """主程序入口"""
    print("=" * 50)
    print("Google Scholar Access Checker")
    print("=" * 50)
    print("开始检测Google Scholar访问状态...")
    print()

    # 获取IP信息
    print("1. 获取当前IP信息...")
    ip_info = get_current_ip()
    if ip_info["ip"]:
        print(f"   IP地址: {ip_info['ip']}")
        print(f"   位置: {ip_info['city']}, {ip_info['country']}")
        if ip_info["org"] != "Unknown":
            print(f"   组织: {ip_info['org']}")
    else:
        print(f"   错误: {ip_info.get('error', 'Unknown error')}")

    print("\n2. 检测Google Scholar访问...")
    access_result = check_scholar_access()

    # 整合结果
    result = {
        "timestamp": datetime.now().isoformat() + "Z",
        "ip_info": ip_info,
        "access_status": access_result,
    }

    # 添加状态描述和建议
    status_messages = {
        "accessible": "完全可访问 - Google Scholar在您的网络环境下完全可用",
        "captcha": "需要CAPTCHA验证 - Google检测到了异常流量，需要人工验证",
        "partial": "部分可访问 - 某些功能可能受限",
        "restricted": "访问受限 - Google Scholar对您的网络有限制",
        "blocked": "被阻止 - 无法访问Google Scholar",
        "unknown": "未知状态 - 检测失败",
    }

    result["summary"] = {
        "status": access_result["overall_status"],
        "message": status_messages.get(access_result["overall_status"], "未知状态"),
        "recommendation": "",
    }

    # 添加建议
    if access_result["overall_status"] == "captcha":
        result["summary"]["recommendation"] = "建议稍后重试或更换网络环境"
    elif access_result["overall_status"] in ["partial", "restricted"]:
        result["summary"]["recommendation"] = "部分功能可用，可能需要使用学术机构网络"
    elif access_result["overall_status"] == "blocked":
        result["summary"]["recommendation"] = (
            "当前网络无法访问Google Scholar，请尝试使用VPN或代理"
        )
    elif access_result["overall_status"] == "accessible":
        result["summary"]["recommendation"] = (
            "当前网络环境良好，可以直接使用Google Scholar"
        )

    # 保存结果
    save_results(result)

    # 打印结果摘要
    print("\n" + "=" * 50)
    print("检测结果摘要:")
    print("=" * 50)
    print(f"状态: {result['summary']['status'].upper()}")
    print(f"描述: {result['summary']['message']}")
    print(f"建议: {result['summary']['recommendation']}")
    print()
    print("详细信息:")
    print(
        f"  - 成功检查: {access_result['summary']['successful_checks']}/{access_result['summary']['total_checks']}"
    )
    print(f"  - 平均响应时间: {access_result['summary']['average_response_time_ms']}ms")
    if access_result["summary"]["captcha_detected"]:
        print("  - 检测到CAPTCHA验证要求")
    if access_result["summary"]["blocked_detected"]:
        print("  - 检测到访问阻止")

    # 打印完整JSON（可选）
    print("\n" + "=" * 50)
    print("完整JSON结果:")
    print("=" * 50)
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
