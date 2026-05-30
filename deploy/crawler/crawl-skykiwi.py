#!/usr/bin/env python3
"""
crawl-skykiwi.py - Skykiwi 论坛课程数据爬虫
使用 httpx + Scrapling Adaptor 抓取课外辅导和兴趣爱好板块

CLI:
  python3 scripts/crawl-skykiwi.py --board tutoring [--incremental]
  python3 scripts/crawl-skykiwi.py --board hobby [--incremental]
  python3 scripts/crawl-skykiwi.py --re-analyze <url>

输出: JSON 数组到 stdout，调试信息到 stderr
"""

import sys
import json
import re
import argparse
import time
import os
import httpx
import unicodedata
from scrapling.parser import Adaptor


def clean_title(text):
    """移除标题中的装饰符号（█★●◆⭐🎨等），保留中文/英文/数字/基本标点"""
    if not text:
        return text
    # 1. 移除装饰性 Unicode 符号和 emoji
    text = re.sub(r'[─-╿▀-▟■-◿☀-⛿✀-➿⭐⭕⬛⬜®©™　]+', ' ', text)
    # 2. 移除 emoji（杂项符号、表情符号等 Unicode 块）
    text = re.sub(r'[\U0001F300-\U0001F9FF\U00002600-\U000027BF\U0000FE00-\U0000FE0F\U0000200D\U00002764\U00002B50]+', ' ', text)
    # 3. 清理多余空格
    text = re.sub(r'\s{2,}', ' ', text)
    return text.strip()

# 性能监控（D-18）
start_time = time.time()

# 板块 URL 映射（D-04）
BOARDS = {
    'tutoring': 'https://bbs.skykiwi.com/forum.php?mod=forumdisplay&fid=254&filter=typeid&typeid=333',
    'hobby': 'https://bbs.skykiwi.com/forum.php?mod=forumdisplay&fid=205&filter=typeid&typeid=259',
}

# HTML 缓存目录（Phase 118）
CACHE_BASE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cache')

# HTTP 客户端（复用连接池）
_http_client = None


def _get_http_client():
    """获取或创建 httpx 客户端（支持代理）"""
    global _http_client
    if _http_client is None:
        proxy_url = get_proxy_url()
        kwargs = {
            'timeout': 30.0,
            'follow_redirects': True,
            'headers': {
                'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            },
        }
        if proxy_url:
            kwargs['proxy'] = proxy_url
        _http_client = httpx.Client(**kwargs)
    return _http_client


def fetch_page(url):
    """抓取 URL 并返回 Adaptor 解析对象（替代 Fetcher.get()）"""
    client = _get_http_client()
    resp = client.get(url)
    resp.raise_for_status()
    return Adaptor(resp.text)


def save_cache(board, filename, content):
    """保存 HTML 到缓存目录"""
    date_str = time.strftime('%Y-%m-%d')
    cache_dir = os.path.join(CACHE_BASE_DIR, date_str, board)
    os.makedirs(cache_dir, exist_ok=True)
    filepath = os.path.join(cache_dir, filename)
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)
    sys.stderr.write(f"[cache] 已缓存: {filepath}\n")


def load_cache(date_str, board, filename):
    """从缓存目录加载 HTML，失败返回 None"""
    filepath = os.path.join(CACHE_BASE_DIR, date_str, board, filename)
    if os.path.exists(filepath):
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        sys.stderr.write(f"[cache] 命中缓存: {filepath} ({len(content)} bytes)\n")
        return content
    return None


# 价格验证常量（D-12, D-13, D-14，复制自 price-validator.ts）
MIN_PRICE = 7
MAX_PRICE = 500
DEFAULT_PRICE = 50
PLACEHOLDER_PRICES = [0, 1, 10, 100]


def get_proxy_url():
    """从环境变量读取代理 URL（D-03, NET-02）
    优先 HTTPS_PROXY，回退 HTTP_PROXY
    仅支持 http:// 和 https:// 协议（D-04）
    """
    proxy_url = os.environ.get('HTTPS_PROXY') or os.environ.get('HTTP_PROXY') or None
    if proxy_url:
        # 校验 URL 格式，拒绝非 http/https 协议（T-100-01）
        if not (proxy_url.startswith('http://') or proxy_url.startswith('https://')):
            sys.stderr.write(f"代理 URL 协议不支持: {proxy_url}（仅 http/https）\n")
            return None
    return proxy_url


def sanitize_proxy_url(url):
    """脱敏代理 URL 中的凭据（T-100-02）
    将 http://user:pass@host:port 转换为 http://***@host:port
    """
    if not url:
        return None
    # 匹配 user:pass@ 模式
    match = re.match(r'(https?://)([^:]+):([^@]+)@(.+)', url)
    if match:
        return f"{match.group(1)}***:***@{match.group(4)}"
    return url


def create_stealthy_session(proxy=None, timeout_ms=60000, retries=3):
    """创建 httpx 客户端实例（兼容旧接口，用于 --re-analyze 模式）

    注意：原 StealthySession/playwright 方案因 Alpine/ARM 平台不支持已替换为 httpx。
    返回上下文管理器，支持 with 语法。
    """
    kwargs = {
        'timeout': timeout_ms / 1000.0,
        'follow_redirects': True,
        'headers': {
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
    }
    if proxy:
        kwargs['proxy'] = proxy
    return httpx.Client(**kwargs)


def classify_error(error, url):
    """分类连接错误为 DNS/TCP/HTTP 层级（D-05, NET-03）
    返回结构化 JSON:
    { errorLevel: 'DNS'|'TCP'|'HTTP'|'UNKNOWN',
      errorType: str,
      message: str,
      url: str,
      timestamp: str }
    """
    error_msg = str(error).lower()
    timestamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

    # DNS 解析失败模式
    dns_patterns = [
        'net::err_name_not_resolved',
        'could not resolve',
        'getaddrinfo failed',
        'name resolution',
        'dns',
    ]

    # TCP 连接失败模式
    tcp_patterns = [
        'net::err_connection_timed_out',
        'net::err_connection_refused',
        'net::err_connection_reset',
        'net::err_timed_out',
        'connection timed out',
        'failed to connect',
        'timeout',
    ]

    # HTTP 错误模式（状态码、SSL、重定向）
    http_patterns = [
        'net::err_http',
        'net::err_too_many_redirects',
        'net::err_ssl',
        'http/1.1 4',
        'http/1.1 5',
        'status code',
    ]

    if any(p in error_msg for p in dns_patterns):
        return {
            'errorLevel': 'DNS',
            'errorType': 'RESOLUTION_FAILED',
            'message': f'DNS 解析失败: {url}',
            'url': url,
            'timestamp': timestamp,
        }
    elif any(p in error_msg for p in tcp_patterns):
        return {
            'errorLevel': 'TCP',
            'errorType': 'CONNECTION_TIMEOUT',
            'message': f'TCP 连接超时: {url}',
            'url': url,
            'timestamp': timestamp,
        }
    elif any(p in error_msg for p in http_patterns):
        return {
            'errorLevel': 'HTTP',
            'errorType': 'STATUS_ERROR',
            'message': f'HTTP 状态码错误: {error}',
            'url': url,
            'timestamp': timestamp,
        }
    else:
        return {
            'errorLevel': 'UNKNOWN',
            'errorType': type(error).__name__,
            'message': str(error),
            'url': url,
            'timestamp': timestamp,
        }


def validate_price(price, unit, has_price_note=False):
    """
    验证价格合理性 — 缺失返回 None，不使用默认值
    规则复制自 TypeScript 端 price-validator.ts
    """
    issues = []
    confidence = 1.0

    if price is None:
        return {
            'valid': False,
            'quality': 'missing',
            'issues': ['价格缺失'],
            'confidence': 0,
        }

    if price in PLACEHOLDER_PRICES:
        issues.append('占位符')
        confidence *= 0.5

    if price == DEFAULT_PRICE and unit == '小时':
        issues.append('可能是默认值 $50/小时')
        confidence = 0.4 if has_price_note else 0.2
        return {
            'valid': has_price_note,
            'quality': 'suspicious',
            'issues': issues,
            'confidence': confidence,
        }

    if price < MIN_PRICE:
        issues.append('价格低于合理范围')
        confidence *= 0.6
    if price > MAX_PRICE:
        issues.append('价格高于合理范围')
        confidence *= 0.6

    if price > 20 and price % 10 == 0:
        issues.append('圆整数字')
        confidence *= 0.9 if has_price_note else 0.85

    quality = 'suspicious' if issues else 'verified'
    confidence = max(0, min(1, confidence))
    return {
        'valid': confidence >= 0.5,
        'quality': quality,
        'issues': issues,
        'confidence': confidence,
    }


def extract_price(text):
    """从文本中提取价格"""
    if not text:
        return None, '小时'
    patterns = [
        r'\$\s*(\d+\.?\d*)\s*/?\s*(半小时|小时|节|次|堂|lesson|hour)',
        r'(?:每小时|每堂|每节)\s*\$?\s*(\d+\.?\d*)',
        r'(\d+\.?\d*)\s*/\s*(小时|半小时|节|次|堂|lesson|hour)',
    ]
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            price = float(match.group(1))
            unit = match.group(2) if len(match.groups()) > 1 else '小时'
            return price, unit
    return None, '小时'


def extract_post_data(post_element, board_name):
    """
    从帖子元素提取结构化数据
    输出字段匹配 Prisma Course 模型:
    { title, price, priceUnit, contactWechat, contactPhone, subject,
      region, sourceUrl, sourcePlatform, originalContent,
      crawlMetadata: { crawledAt, board, confidence, errors } }
    """
    # 提取标题和链接
    title_els = post_element.css('a.xst') or post_element.css('th a[href*="viewthread"]')
    title_el = title_els[0] if title_els else None
    if not title_el:
        return None

    title = clean_title(title_el.text.strip()) if title_el.text else ''

    # 拼接完整 URL
    if href.startswith('http'):
        source_url = href
    elif 'tid=' in href:
        tid = re.search(r'tid=(\d+)', href)
        source_url = f"https://bbs.skykiwi.com/forum.php?mod=viewthread&tid={tid.group(1)}" if tid else href
    else:
        source_url = f"https://bbs.skykiwi.com/{href}" if href else ''

    # 提取帖子内容文本（用于价格和联系方式提取）
    content_text = ''
    content_els = post_element.css('.t_f')
    content_el = content_els[0] if content_els else post_element
    if content_el:
        content_text = content_el.text.strip() if content_el.text else ''

    # 清理论坛元数据
    content_text = clean_forum_metadata(content_text)

    # 如果帖子内容不够（列表页通常没有正文），用标题来提取价格
    combined_text = f"{title} {content_text}"

    # 价格提取和验证
    raw_price, price_unit = extract_price(combined_text)
    price_validation = validate_price(raw_price, price_unit)
    price_value = int(raw_price) if raw_price is not None else None

    # 联系方式提取
    contact_wechat = None
    wechat_match = re.search(
        r'(?:微信|wechat|WeChat|wx)[:\s：]*([a-zA-Z0-9_-]{5,20})',
        combined_text,
        re.IGNORECASE,
    )
    if wechat_match:
        contact_wechat = wechat_match.group(1)

    contact_phone = None
    phone_match = re.search(r'(0[2-9](?:[-\s–]?\d){7,8})', combined_text)
    if phone_match:
        contact_phone = phone_match.group(1)
    else:
        phone_match = re.search(r'(\+?64[-\s–]?[2-9](?:[-\s–]?\d){7,8})', combined_text)
        if phone_match:
            contact_phone = phone_match.group(1)

    # 科目推断
    subject = None
    subject_keywords = {
        '数学': ['数学', 'math', 'mathematics'],
        '英语': ['英语', 'english', 'ESOL', '雅思', 'IELTS'],
        '钢琴': ['钢琴', 'piano', 'keyboard'],
        '小提琴': ['小提琴', 'violin'],
        '吉他': ['吉他', 'guitar'],
        '绘画': ['绘画', '画画', 'art', 'drawing'],
        '书法': ['书法', 'calligraphy'],
        '舞蹈': ['舞蹈', 'dance', 'ballet', '芭蕾'],
        '游泳': ['游泳', 'swimming'],
        '武术': ['武术', 'martial arts', 'kung fu', '功夫'],
        '中文': ['中文', 'chinese', '汉语', 'mandarin'],
        '科学': ['科学', 'science'],
        'NCEA': ['NCEA'],
        '剑桥': ['cambridge', '剑桥'],
    }
    title_lower = title.lower()
    for subj, keywords in subject_keywords.items():
        for kw in keywords:
            if kw.lower() in title_lower:
                subject = subj
                break
        if subject:
            break

    # 地区（默认奥克兰）
    region = '奥克兰'
    region_keywords = ['北岸', '中区', '东区', '西区', '南区', '市中心']
    for r in region_keywords:
        if r in combined_text:
            region = r
            break

    crawled_at = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

    return {
        'title': title,
        'price': price_value,
        'priceUnit': price_unit,
        'contactWechat': contact_wechat,
        'contactPhone': contact_phone,
        'subject': subject,
        'region': region,
        'sourceUrl': source_url,
        'sourcePlatform': 'skykiwi',
        'originalContent': content_text[:8000] if content_text else '',
        'crawlMetadata': {
            'crawledAt': crawled_at,
            'board': board_name,
            'confidence': price_validation['confidence'],
            'errors': [],
        },
    }


def clean_forum_metadata(text):
    """清理论坛元数据（编辑信息、附件信息、上传时间等）"""
    if not text:
        return text

    # 移除 Discuz 论坛编辑信息
    text = re.sub(r'本帖最后由\s*\S+\s*于\s*[\d\-]+\s*[\d:]+\s*编辑\s*', '', text)

    # 移除附件上传信息
    text = re.sub(r'\d{4}-\d{1,2}-\d{1,2}\s*\d{2}:\d{2}:\d{2}\s*上传\s*', '', text)

    # 移除下载附件信息
    text = re.sub(r'下载附件\s*\([^)]*\)\s*', '', text)

    # 移除图片尺寸信息
    text = re.sub(r'\(\d+\.\d+\s*(?:KB|MB|bytes)\)', '', text)

    # 移除 Discuz 评分/签名等
    text = re.sub(r'---+\s*来自.*?---+', '', text)

    # 移除多余的空行（清洗后可能产生）
    text = re.sub(r'\n{3,}', '\n\n', text)

    # 移除 Unicode 替换字符（源站编码错误导致的乱码）
    text = text.replace('�', '')

    return text.strip()


def extract_post_data_from_page(page, url):
    """从帖子详情页提取数据（--re-analyze 模式）"""
    content_text = ''
    # 合并主帖 + 前 2 条回复（回复可能包含联系方式和补充信息）
    all_post_els = page.css('.t_f') or page.css('#postmessage') or [page]
    text_parts = []
    for el in all_post_els[:3]:
        raw = el.get_all_text() if hasattr(el, 'get_all_text') else (el.text or '')
        if raw and raw.strip():
            text_parts.append(raw.strip())
    content_text = '\n'.join(text_parts)

    # 清理论坛元数据
    content_text = clean_forum_metadata(content_text)

    title_els = page.css('#thread_subject') or page.css('h1')
    title_el = title_els[0] if title_els else None
    title = clean_title(title_el.text.strip()) if title_el and title_el.text else ''

    combined_text = f"{title} {content_text}"

    raw_price, price_unit = extract_price(combined_text)
    price_validation = validate_price(raw_price, price_unit)
    price_value = int(raw_price) if raw_price is not None else None

    contact_wechat = None
    wechat_match = re.search(
        r'(?:微信|wechat|WeChat|wx)[:\s：]*([a-zA-Z0-9_-]{5,20})',
        combined_text,
        re.IGNORECASE,
    )
    if wechat_match:
        contact_wechat = wechat_match.group(1)

    contact_phone = None
    phone_match = re.search(r'(0[2-9](?:[-\s–]?\d){7,8})', combined_text)
    if phone_match:
        contact_phone = phone_match.group(1)
    else:
        phone_match = re.search(r'(\+?64[-\s–]?[2-9](?:[-\s–]?\d){7,8})', combined_text)
        if phone_match:
            contact_phone = phone_match.group(1)

    subject = None
    subject_keywords = {
        '数学': ['数学', 'math', 'mathematics'],
        '英语': ['英语', 'english', 'ESOL', '雅思', 'IELTS'],
        '钢琴': ['钢琴', 'piano', 'keyboard'],
        '小提琴': ['小提琴', 'violin'],
        '吉他': ['吉他', 'guitar'],
        '绘画': ['绘画', '画画', 'art', 'drawing'],
        '书法': ['书法', 'calligraphy'],
        '舞蹈': ['舞蹈', 'dance', 'ballet', '芭蕾'],
        '游泳': ['游泳', 'swimming'],
        '武术': ['武术', 'martial arts', 'kung fu', '功夫'],
        '中文': ['中文', 'chinese', '汉语', 'mandarin'],
        '科学': ['科学', 'science'],
        'NCEA': ['NCEA'],
        '剑桥': ['cambridge', '剑桥'],
    }
    title_lower = title.lower()
    for subj, keywords in subject_keywords.items():
        for kw in keywords:
            if kw.lower() in title_lower:
                subject = subj
                break
        if subject:
            break

    region = '奥克兰'
    region_keywords = ['北岸', '中区', '东区', '西区', '南区', '市中心']
    for r in region_keywords:
        if r in combined_text:
            region = r
            break

    crawled_at = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

    return {
        'title': title,
        'price': price_value,
        'priceUnit': price_unit,
        'contactWechat': contact_wechat,
        'contactPhone': contact_phone,
        'subject': subject,
        'region': region,
        'sourceUrl': url,
        'sourcePlatform': 'skykiwi',
        'originalContent': content_text[:8000] if content_text else '',
        'crawlMetadata': {
            'crawledAt': crawled_at,
            'board': 're-analyze',
            'confidence': price_validation['confidence'],
            'errors': [],
        },
    }


def crawl_board(board_url, board_name, max_pages=1, max_posts=0, use_cache=False, cache_date=None):
    """抓取指定板块，直连优先+代理回退（D-01, D-02, NET-01）"""
    results = []
    connected_via = 'direct'

    # 使用 httpx + Adaptor 直连（skykiwi 不需要浏览器模式）
    sys.stderr.write(f"直连尝试 (1/2): {board_url}\n")
    try:
        test_page = fetch_page(board_url)
        sys.stderr.write("直连成功\n")
    except Exception as e:
        sys.stderr.write(f"直连失败: {e}\n")
        # 阶段 2: 代理回退 — 重置客户端以使用代理
        proxy_url = get_proxy_url()
        if proxy_url:
            global _http_client
            _http_client = None  # 重置以便 fetch_page 创建带代理的客户端
            sys.stderr.write(f"切换代理: {sanitize_proxy_url(proxy_url)}\n")
        else:
            sys.stderr.write("直连失败且未配置代理\n")
            return results
        connected_via = 'proxy'

    try:
        for page_num in range(1, max_pages + 1):
            page_url = board_url
            if page_num > 1:
                page_url = f"{board_url}&page={page_num}"

            sys.stderr.write(f"抓取第 {page_num} 页: {page_url} (via {connected_via})\n")
            page = fetch_page(page_url)

            # 保存列表页缓存
            try:
                page_html = str(page)
                save_cache(board_name, f"list_p{page_num}.html", page_html)
            except Exception:
                pass  # 缓存失败不影响抓取

            posts = page.css('tbody[id^="normalthread"]')
            if not posts:
                posts = page.css('.bm_c tbody[id]')

            sys.stderr.write(f"找到 {len(posts)} 条帖子\n")

            # 从列表页提取帖子链接，然后逐条访问详情页
            for i, post in enumerate(posts):
                if max_posts > 0 and len(results) >= max_posts:
                    break
                t0 = time.time()
                try:
                    link_els = post.css('a.xst') or post.css('th a[href*="viewthread"]')
                    if not link_els:
                        continue
                    link_el = link_els[0]
                    href = link_el.attrib.get('href', '')
                    if not href:
                        continue
                    title = link_el.text.strip() if link_el.text else ''

                    # 拼接详情页 URL
                    if href.startswith('http'):
                        detail_url = href
                    elif 'tid=' in href:
                        tid = re.search(r'tid=(\d+)', href)
                        detail_url = f"https://bbs.skykiwi.com/forum.php?mod=viewthread&tid={tid.group(1)}" if tid else ''
                    else:
                        detail_url = f"https://bbs.skykiwi.com/{href}"

                    if not detail_url:
                        continue

                    # 访问详情页提取完整数据
                    try:
                        t_fetch = time.time()
                        detail_page = fetch_page(detail_url)
                        fetch_ms = (time.time() - t_fetch) * 1000

                        # 保存详情页缓存
                        try:
                            detail_html = str(detail_page)
                            tid_match_cache = re.search(r'tid=(\d+)', detail_url)
                            cache_filename = f"detail_{tid_match_cache.group(1)}.html" if tid_match_cache else f"detail_{i}.html"
                            save_cache(board_name, cache_filename, detail_html)
                        except Exception:
                            pass

                        t_extract = time.time()
                        result = extract_post_data_from_page(detail_page, detail_url)
                        extract_ms = (time.time() - t_extract) * 1000

                        if result:
                            result['title'] = title
                            result['sourceUrl'] = detail_url
                            results.append(result)
                        total_ms = (time.time() - t0) * 1000
                        sys.stderr.write(f"[{i+1}/{len(posts)}] fetch={fetch_ms:.0f}ms extract={extract_ms:.0f}ms total={total_ms:.0f}ms — {title[:30]}\n")
                    except Exception as e:
                        total_ms = (time.time() - t0) * 1000
                        sys.stderr.write(f"[{i+1}/{len(posts)}] FAIL {total_ms:.0f}ms — {detail_url}: {e}\n")
                except Exception as e:
                    sys.stderr.write(f"[{i+1}/{len(posts)}] 解析失败: {e}\n")
    except Exception as e:
        error_info = classify_error(e, board_url)
        sys.stderr.write(json.dumps(error_info, ensure_ascii=False) + "\n")
    finally:
        pass  # httpx 客户端在 fetch_page 中复用，无需手动关闭
    return results


def crawl_board_from_cache(board_name, cache_date, max_posts=0):
    """从缓存加载 HTML 并提取帖子数据（不访问网络）"""
    results = []
    cache_dir = os.path.join(CACHE_BASE_DIR, cache_date, board_name)
    if not os.path.exists(cache_dir):
        sys.stderr.write(f"[cache] 缓存目录不存在: {cache_dir}\n")
        return results

    # 查找所有详情页缓存
    detail_files = sorted([f for f in os.listdir(cache_dir) if f.startswith('detail_') and f.endswith('.html')])
    sys.stderr.write(f"[cache] 找到 {len(detail_files)} 个详情页缓存\n")

    for detail_file in detail_files:
        if max_posts > 0 and len(results) >= max_posts:
            break
        filepath = os.path.join(cache_dir, detail_file)
        with open(filepath, 'r', encoding='utf-8') as f:
            html_content = f.read()

        # 用 scrapling 解析缓存 HTML
        from scrapling.parser import Adaptor
        page = Adaptor(html_content)

        # 从文件名提取 tid 构建 URL
        tid_match = re.search(r'detail_(\d+)', detail_file)
        detail_url = f"https://bbs.skykiwi.com/forum.php?mod=viewthread&tid={tid_match.group(1)}" if tid_match else ''

        result = extract_post_data_from_page(page, detail_url)
        if result:
            results.append(result)

    sys.stderr.write(f"[cache] 从缓存提取 {len(results)} 条帖子\n")
    return results


# ============================================================
# 失败率熔断机制（Phase 106, per D-08）
# ============================================================

CIRCUIT_BREAKER_THRESHOLD = 0.15  # 15% 失败率阈值（per D-08）


def check_circuit_breaker(combined_stats):
    """检查累计失败率是否超过阈值（per D-08）

    Args:
        combined_stats: dict with keys: total, failed, filtered, llm_rejected,
                        no_contact, duplicates, discarded

    Returns:
        True if failure rate > 15%, triggers sys.exit(1) in caller
    """
    total = combined_stats.get('total', 0)
    if total == 0:
        return False

    failures = (
        combined_stats.get('failed', 0)
        + combined_stats.get('llm_rejected', 0)
    )
    # filtered/duplicates/no_contact/discarded 是正常业务情况，不计入失败率
    rate = failures / total
    if rate > CIRCUIT_BREAKER_THRESHOLD:
        sys.stderr.write(
            f"[CIRCUIT_BREAKER] 失败率 {rate:.1%} 超过阈值 "
            f"{CIRCUIT_BREAKER_THRESHOLD:.0%}，终止执行\n"
        )
        sys.stderr.write(
            f"[CIRCUIT_BREAKER] 统计: {total} 处理 / "
            f"{failures} 失败\n"
        )
        return True
    return False


def main():
    parser = argparse.ArgumentParser(description='Skykiwi 论坛课程数据爬虫')
    parser.add_argument('--board', default='tutoring', help='板块名称 (tutoring/hobby)')
    parser.add_argument('--incremental', action='store_true', help='仅抓取最新 1 页')
    parser.add_argument('--re-analyze', type=str, help='重新分析单个 URL')
    parser.add_argument('--limit', type=int, default=0, help='最多抓取条数（0=不限制）')
    parser.add_argument('--from-cache', type=str, help='从缓存加载 HTML（格式：YYYY-MM-DD）')
    args = parser.parse_args()

    results = []

    # 跨阶段统计累计（Phase 106, per D-09）
    combined_stats = {
        'total': 0, 'failed': 0, 'filtered': 0,
        'llm_rejected': 0, 'no_contact': 0,
        'duplicates': 0, 'discarded': 0,
    }

    if args.re_analyze:
        last_error = None
        page = None
        # 直连尝试
        for attempt in range(2):
            try:
                sys.stderr.write(f"直连尝试 ({attempt + 1}/2): {args.re_analyze}\n")
                page = fetch_page(args.re_analyze)
                sys.stderr.write("直连成功\n")
                break
            except Exception as e:
                last_error = e
                error_info = classify_error(e, args.re_analyze)
                sys.stderr.write(json.dumps(error_info, ensure_ascii=False) + "\n")
        else:
            # 代理回退
            proxy_url = get_proxy_url()
            if proxy_url:
                global _http_client
                _http_client = None  # 重置以便 fetch_page 创建带代理的客户端
                sys.stderr.write(f"切换代理: {sanitize_proxy_url(proxy_url)}\n")
                try:
                    page = fetch_page(args.re_analyze)
                    sys.stderr.write("代理连接成功\n")
                except Exception as e:
                    error_info = classify_error(e, args.re_analyze)
                    sys.stderr.write(json.dumps(error_info, ensure_ascii=False) + "\n")
                    page = None
            else:
                if last_error:
                    error_info = classify_error(last_error, args.re_analyze)
                    sys.stderr.write(json.dumps(error_info, ensure_ascii=False) + "\n")
        if page:
            result = extract_post_data_from_page(page, args.re_analyze)
            results = [result] if result else []
    else:
        board_name = args.board
        board_url = BOARDS.get(board_name)
        if not board_url:
            sys.stderr.write(f"未知板块: {board_name}\n")
            sys.exit(1)

        max_pages = 1
        if args.from_cache:
            # 从缓存加载，不访问网络
            results = crawl_board_from_cache(board_name, args.from_cache, max_posts=args.limit)
        else:
            results = crawl_board(board_url, board_name, max_pages, max_posts=args.limit)

        # === LLM 过滤（Phase 104）===
        if results:
            try:
                from llm_filter import filter_course_posts, write_filter_log
                original_results = results  # 保留原始结果用于日志
                results, filter_stats = filter_course_posts(results, board_name)
                sys.stderr.write(
                    f"[llm_filter] 过滤完成: "
                    f"{filter_stats['course']} 课程 / "
                    f"{filter_stats['filtered']} 过滤 / "
                    f"{filter_stats['total']} 总计\n"
                )
                # 写过滤日志（使用原始结果 + 分类结果）
                try:
                    write_filter_log(
                        original_results,
                        filter_stats.get('classifications', []),
                        board_name,
                    )
                except OSError:
                    pass  # 日志目录不可写，跳过
            except Exception as e:
                sys.stderr.write(f"[llm_filter] 过滤失败（继续使用未过滤结果）: {e}\n")

            # 累计 Phase 104 统计
            if 'filter_stats' in dir():
                combined_stats['total'] += filter_stats.get('total', 0)
                combined_stats['filtered'] += filter_stats.get('filtered', 0)

    # === LLM 详情提取（Phase 105）===
    if results:
        try:
            from llm_extract import extract_course_details, write_extract_log
            extract_stats = {'success': 0, 'discarded': 0, 'failed': 0}
            extracted_results = []
            for course in results:
                try:
                    enriched = extract_course_details(course)
                    if enriched is not None:
                        extracted_results.append(enriched)
                        extract_stats['success'] += 1
                    else:
                        extract_stats['discarded'] += 1
                        sys.stderr.write(
                            f"[llm_extract] 抛弃（LLM+regex 均未提取到有效信息）: {course.get('sourceUrl', '?')}\n"
                        )
                except Exception as e:
                    extract_stats['failed'] += 1
                    sys.stderr.write(
                        f"[llm_extract] 提取失败 [{course.get('sourceUrl', '?')}]: {e}\n"
                    )
                    extracted_results.append(course)  # 失败时保留原始数据
                time.sleep(1)  # 请求间延迟，避免代理限流

            results = extracted_results
            sys.stderr.write(
                f"[llm_extract] 提取完成: "
                f"{extract_stats['success']} 成功 / "
                f"{extract_stats['discarded']} 抛弃 / "
                f"{extract_stats['failed']} 失败\n"
            )
            # 写提取日志
            try:
                write_extract_log(results, board_name if not args.re_analyze else 're-analyze')
            except OSError:
                pass  # 日志目录不可写，跳过
        except Exception as e:
            sys.stderr.write(f"[llm_extract] 提取模块失败（继续使用未提取结果）: {e}\n")

    # 累计 Phase 105 统计
    if 'extract_stats' in dir():
        combined_stats['total'] += extract_stats.get('success', 0) + extract_stats.get('discarded', 0)
        combined_stats['failed'] += extract_stats.get('failed', 0)
        combined_stats['discarded'] += extract_stats.get('discarded', 0)

    # === 质量关卡（Phase 106）===
    if results:
        try:
            from llm_quality_gate import quality_gate_filter, write_quality_log
            results, gate_stats = quality_gate_filter(results)
            sys.stderr.write(
                f"[quality_gate] 质量关卡完成: "
                f"{gate_stats['passed']} 通过 / "
                f"{gate_stats['llm_rejected']} LLM拒绝 / "
                f"{gate_stats['no_contact']} 无联系方式 / "
                f"{gate_stats['total']} 总计\n"
            )
            write_quality_log(
                results, gate_stats,
                board_name if not args.re_analyze else 're-analyze'
            )
        except Exception as e:
            sys.stderr.write(f"[quality_gate] 质量关卡失败（继续使用未过滤结果）: {e}\n")

    # 累计 Phase 106 质量关卡统计
    if 'gate_stats' in dir():
        combined_stats['total'] += gate_stats.get('total', 0)
        combined_stats['llm_rejected'] += gate_stats.get('llm_rejected', 0)
        combined_stats['no_contact'] += gate_stats.get('no_contact', 0)

    elapsed = time.time() - start_time
    sys.stderr.write(f"抓取耗时: {elapsed:.2f}s\n")

    # 唯一的 stdout 输出 — JSON 数组（D-08）
    print(json.dumps(results, ensure_ascii=False, indent=2))

    sys.stderr.write("[crawl] 数据库入库已移至 TypeScript pipeline，Python 仅输出 JSON\n")

    # === 失败率熔断 + 批次统计日志（Phase 106, per D-08, D-09）===
    # 写入批次日志
    batch_log = {
        'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'board': board_name if not args.re_analyze else 're-analyze',
        'stats': combined_stats,
    }
    log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logs')
    try:
        os.makedirs(log_dir, exist_ok=True)
        log_file = os.path.join(log_dir, f"batch_{time.strftime('%Y%m%d')}.json")
        with open(log_file, 'a') as f:
            f.write(json.dumps(batch_log, ensure_ascii=False) + '\n')
        sys.stderr.write(
            f"[batch] 批次日志写入: {log_file} "
            f"({json.dumps(combined_stats, ensure_ascii=False)})\n"
        )
    except OSError:
        sys.stderr.write("[batch] 日志目录不可写，跳过批次日志\n")

    # 熔断检查（per D-08）
    if check_circuit_breaker(combined_stats):
        sys.exit(1)


if __name__ == '__main__':
    main()
