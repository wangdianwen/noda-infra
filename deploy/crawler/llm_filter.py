#!/usr/bin/env python3
"""
llm_filter.py - LLM 列表过滤核心模块
使用 Anthropic SDK Tool Use 批量分类帖子标题，过滤非课程帖

CLI:
  python3 scripts/llm_filter.py (不直接使用，由 crawl-skykiwi.py 调用)

导出:
  - filter_course_posts: 过滤课程帖子主入口
  - classify_titles_batch: 批量标题分类
  - write_filter_log: 写入过滤日志
"""

import sys
import os
import json
import re
import time

import anthropic

# 常量定义（per D-01, D-04）
MODEL_NAME = "claude-haiku-4-5-20251001"
MAX_RETRIES = 3
BASE_DELAY = 1.0  # 秒
BATCH_SIZE = 50  # 每批最多处理的标题数

# Tool Use schema 定义（per D-08）
_CLASSIFY_TOOL = {
    "name": "classify_titles",
    "description": "对论坛帖子标题进行分类，判断是否为课程/教育相关帖子",
    "input_schema": {
        "type": "object",
        "properties": {
            "classifications": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "index": {
                            "type": "integer",
                            "description": "帖子编号（从1开始）",
                        },
                        "title": {
                            "type": "string",
                            "description": "原始标题",
                        },
                        "is_course": {
                            "type": "boolean",
                            "description": "是否为课程/教育相关帖子",
                        },
                        "reason": {
                            "type": "string",
                            "description": "判断原因（简短中文）",
                        },
                    },
                    "required": ["index", "title", "is_course", "reason"],
                },
            }
        },
        "required": ["classifications"],
    },
}

# 系统提示词 — 宽泛模式边界（per D-05, D-06, D-07）
_SYSTEM_PROMPT = """你是一个论坛帖子分类器，专门判断帖子是否为课程/教育相关。

通过的类型（is_course = true）：
- 明确的课程/辅导帖（如"数学辅导 Year7-10"）
- 培训机构广告（如"XX教育中心招生"）
- 家长求家教帖（如"求 Year10 数学辅导老师"）

过滤掉的类型（is_course = false）：
- 租房/招租
- 二手交易/物品买卖
- 求职/招聘（非教育类）
- 教材出售
- 学习小组招募
- 其他非教育类帖子"""


def _get_client():
    """获取 Anthropic 客户端（自动读取 ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL）"""
    return anthropic.Anthropic()


def _parse_json_response(response) -> dict | None:
    """从 LLM 响应中解析 JSON（兼容 tool_use、markdown code block、纯文本模式）"""
    for block in response.content:
        if block.type == "tool_use":
            return block.input
    for block in response.content:
        if hasattr(block, "text") and block.text:
            text = block.text
            cb = re.search(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```', text)
            if cb:
                try:
                    return json.loads(cb.group(1))
                except json.JSONDecodeError:
                    pass
            depth = 0
            last_start = -1
            for i, c in enumerate(text):
                if c == '{':
                    if depth == 0:
                        last_start = i
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth == 0 and last_start >= 0:
                        try:
                            return json.loads(text[last_start:i+1])
                        except json.JSONDecodeError:
                            continue
    return None


def _call_llm_with_retry(client, titles: list[str]) -> list[dict]:
    """带重试的 LLM 批量分类调用

    Args:
        client: Anthropic 客户端实例
        titles: 标题列表

    Returns:
        分类结果列表，每条包含 index/title/is_course/reason

    Raises:
        RuntimeError: 超过最大重试次数
    """
    titles_text = "\n".join(f"{i + 1}. {t}" for i, t in enumerate(titles))

    for attempt in range(MAX_RETRIES):
        try:
            # 先尝试 tool_use 模式
            try:
                response = client.messages.create(
                    model=MODEL_NAME,
                    max_tokens=min(8192, len(titles) * 100),
                    system=_SYSTEM_PROMPT + "\n\n请以 JSON 格式输出结果，包含 classifications 数组。",
                    tools=[_CLASSIFY_TOOL],
                    tool_choice={"type": "any"},
                    messages=[
                        {
                            "role": "user",
                            "content": f"请判断以下 {len(titles)} 个帖子标题是否为课程/教育相关帖子：\n{titles_text}",
                        }
                    ],
                )
                result = _parse_json_response(response)
                if result and "classifications" in result:
                    return result["classifications"]
            except (anthropic.BadRequestError, anthropic.APIError):
                pass

            # 纯文本 JSON 模式（兼容不支持 tool_use 的 API 代理）
            response = client.messages.create(
                model=MODEL_NAME,
                max_tokens=min(8192, len(titles) * 100),
                system=_SYSTEM_PROMPT,
                messages=[
                    {
                        "role": "user",
                        "content": (
                            f"请判断以下 {len(titles)} 个帖子标题是否为课程/教育相关帖子。\n"
                            f"严格以 JSON 格式输出：{{\"classifications\": [{{\"index\": 1, \"title\": \"原标题\", \"is_course\": true/false, \"reason\": \"原因\"}}]}}\n\n"
                            f"{titles_text}"
                        ),
                    }
                ],
            )
            result = _parse_json_response(response)
            if result and "classifications" in result:
                return result["classifications"]

            raise ValueError("LLM 未返回有效 JSON 响应")

        except anthropic.RateLimitError:
            delay = BASE_DELAY * (2**attempt)
            sys.stderr.write(
                f"[llm_filter] 限流，等待 {delay}s 后重试 ({attempt + 1}/{MAX_RETRIES})\n"
            )
            time.sleep(delay)
        except anthropic.APIConnectionError as e:
            delay = BASE_DELAY * (2**attempt)
            sys.stderr.write(
                f"[llm_filter] 连接失败: {e}，重试 ({attempt + 1}/{MAX_RETRIES})\n"
            )
            time.sleep(delay)
        except (anthropic.InternalServerError, ValueError) as e:
            delay = BASE_DELAY * (2**attempt)
            sys.stderr.write(
                f"[llm_filter] 错误: {e}，重试 ({attempt + 1}/{MAX_RETRIES})\n"
            )
            time.sleep(delay)

    raise RuntimeError(f"LLM 调用失败，已重试 {MAX_RETRIES} 次")


def classify_titles_batch(titles: list[str]) -> list[dict]:
    """批量分类帖子标题是否为课程相关

    Args:
        titles: 标题字符串列表

    Returns:
        分类结果列表，每条包含 index/title/is_course/reason 字段
    """
    client = _get_client()
    return _call_llm_with_retry(client, titles)


def filter_course_posts(
    posts: list[dict], board_name: str
) -> tuple[list[dict], dict]:
    """过滤课程帖子主入口

    Args:
        posts: crawl_board() 返回的帖子列表
        board_name: 板块名称

    Returns:
        (course_posts, stats) 元组
        - course_posts: 仅包含课程帖的列表
        - stats: 统计信息 {total, course, filtered, classifications}
    """
    if not posts:
        return [], {"total": 0, "course": 0, "filtered": 0, "classifications": []}

    # 提取有效标题（排除 error 条目）
    valid_posts = [p for p in posts if "title" in p and "error" not in p]
    titles = [p["title"] for p in valid_posts]

    if not titles:
        return [], {
            "total": len(posts),
            "course": 0,
            "filtered": 0,
            "classifications": [],
        }

    # LLM 分批分类（避免单次请求标题过多导致 tool_use 失败）
    client = _get_client()
    all_classifications = []
    for i in range(0, len(titles), BATCH_SIZE):
        batch_titles = titles[i:i + BATCH_SIZE]
        try:
            batch_cls = _call_llm_with_retry(client, batch_titles)
            # 修正 batch 内的 index（LLM 返回批内 1-based，转为全局 0-based）
            for cls in batch_cls:
                cls["index"] = cls.get("index", 0) + i
            all_classifications.extend(batch_cls)
        except RuntimeError:
            # 单批失败时，该批全部默认通过（保守策略）
            sys.stderr.write(f"[llm_filter] 第 {i // BATCH_SIZE + 1} 批失败，默认通过\n")
            for j, title in enumerate(batch_titles):
                all_classifications.append({
                    "index": i + j + 1,
                    "title": title,
                    "is_course": True,
                    "reason": "filter 批次失败，默认通过",
                })
        if i + BATCH_SIZE < len(titles):
            time.sleep(2)  # 批次间延迟，避免限流
    classifications = all_classifications

    # 按 index 建立分类映射（index 从 1 开始，转为 0-based）
    index_to_cls = {}
    for cls in classifications:
        idx = cls.get("index", 0) - 1  # 转为 0-based
        if 0 <= idx < len(valid_posts):
            index_to_cls[idx] = cls

    # 过滤课程帖子
    course_posts = []
    for i, post in enumerate(valid_posts):
        cls = index_to_cls.get(i, {"is_course": True, "reason": "未分类，默认通过"})
        if cls.get("is_course", True):
            course_posts.append(post)

    stats = {
        "total": len(posts),
        "course": len(course_posts),
        "filtered": len(valid_posts) - len(course_posts),
        "classifications": classifications,
    }

    return course_posts, stats


def write_filter_log(posts: list[dict], classifications: list[dict], board: str, log_dir=None):
    """写入过滤日志到 JSON 文件

    Args:
        posts: 原始帖子列表（过滤前）
        classifications: LLM 分类结果列表
        board: 板块名称
        log_dir: 可选日志目录路径（用于测试）
    """
    if log_dir is None:
        log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    os.makedirs(log_dir, exist_ok=True)
    date_str = time.strftime("%Y-%m-%d")
    log_path = os.path.join(log_dir, f"filter_log_{date_str}.json")

    # 建立标题到帖子的映射
    valid_posts = [p for p in posts if "title" in p]
    title_to_post = {}
    for p in valid_posts:
        title_to_post[p["title"]] = p

    log_entries = []
    for cls in classifications:
        post = title_to_post.get(cls.get("title", ""), {})
        log_entries.append(
            {
                "title": cls.get("title", ""),
                "url": post.get("sourceUrl", ""),
                "is_course": cls.get("is_course", False),
                "reason": cls.get("reason", ""),
                "board": board,
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
        )

    # 追加写入（如文件已存在则追加）
    existing = []
    if os.path.exists(log_path):
        with open(log_path, "r") as f:
            try:
                existing = json.load(f)
            except json.JSONDecodeError:
                existing = []

    existing.extend(log_entries)
    with open(log_path, "w") as f:
        json.dump(existing, f, ensure_ascii=False, indent=2)

    sys.stderr.write(f"[llm_filter] 日志已写入: {log_path} ({len(log_entries)} 条)\n")
