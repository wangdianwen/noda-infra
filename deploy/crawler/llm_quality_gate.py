#!/usr/bin/env python3
"""
llm_quality_gate.py - 入库前质量关卡模块
在 Phase 105 提取后、db_import 前执行二次过滤：
  1. 联系方式硬性校验（微信和电话都为空直接过滤）
  2. LLM 二次判断（Haiku 快速确认是否为课程帖）

CLI:
  python3 scripts/llm_quality_gate.py (不直接使用，由 crawl-skykiwi.py 调用)

导出:
  - quality_gate_filter: 入库前二次过滤主入口
  - write_quality_log: 写入质量关卡日志
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

# 失败原因常量
REASON_NO_CONTACT = "NO_CONTACT"
REASON_LLM_REJECTED = "LLM_REJECTED"

# Tool Use schema 定义（per D-01 二次判断）
_QUALITY_CHECK_TOOL = {
    "name": "quality_check",
    "description": "对经过初步提取的课程数据进行二次确认，判断是否为真正的课程/辅导帖",
    "input_schema": {
        "type": "object",
        "properties": {
            "judgments": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "index": {
                            "type": "integer",
                            "description": "课程编号（从1开始）",
                        },
                        "is_course": {
                            "type": "boolean",
                            "description": "是否为真正的课程/辅导帖",
                        },
                        "reason": {
                            "type": "string",
                            "description": "判断原因（简短中文）",
                        },
                    },
                    "required": ["index", "is_course", "reason"],
                },
            }
        },
        "required": ["judgments"],
    },
}

# 系统提示词 — 二次确认（per D-01）
_SYSTEM_PROMPT = """你已经看到经过初步过滤和提取的课程数据。请再次确认这些数据是否为真正的课程/辅导帖。

通过的类型（is_course = true）：
- 明确的课程/辅导/培训班帖
- 教育培训机构广告
- 家教/私教招生帖
- 兴趣班/特长班招生帖

拒绝的类型（is_course = false）：
- 租房/招租
- 二手交易/物品买卖
- 求职/招聘（非教育类）
- 教材出售（非课程）
- 其他非教育类帖子
- 数据内容空洞、无实质课程信息"""


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


def _call_llm_with_retry(client, courses):
    """带重试的 Haiku 二次判断调用（per D-01）

    仅传入每条课程的 title + description + subject，不传入联系方式等敏感数据（per T-106-01）。

    Args:
        client: Anthropic 客户端实例
        courses: 通过联系方式校验的课程列表

    Returns:
        判断结果列表，每条包含 index/is_course/reason

    Raises:
        RuntimeError: 超过最大重试次数
    """
    items_text = "\n".join(
        f"{i + 1}. 标题: {c.get('title', '')} | "
        f"科目: {c.get('subject', '')} | "
        f"描述: {(c.get('description', '') or '')[:200]}"
        for i, c in enumerate(courses)
    )

    for attempt in range(MAX_RETRIES):
        try:
            # 先尝试 tool_use 模式
            try:
                response = client.messages.create(
                    model=MODEL_NAME,
                    max_tokens=min(4096, len(courses) * 150),
                    system=_SYSTEM_PROMPT,
                    tools=[_QUALITY_CHECK_TOOL],
                    tool_choice={"type": "any"},
                    messages=[
                        {
                            "role": "user",
                            "content": (
                                f"请判断以下 {len(courses)} 条数据是否为真正的课程/辅导帖：\n"
                                f"{items_text}"
                            ),
                        }
                    ],
                )
                result = _parse_json_response(response)
                if result and "judgments" in result:
                    return result["judgments"]
            except (anthropic.BadRequestError, anthropic.APIError):
                pass

            # 纯文本 JSON 模式
            response = client.messages.create(
                model=MODEL_NAME,
                max_tokens=min(4096, len(courses) * 150),
                system=_SYSTEM_PROMPT,
                messages=[
                    {
                        "role": "user",
                        "content": (
                            f"请判断以下 {len(courses)} 条数据是否为真正的课程/辅导帖。\n"
                            f"严格以 JSON 格式输出：{{\"judgments\": [{{\"index\": 1, \"is_course\": true/false, \"reason\": \"原因\"}}]}}\n\n"
                            f"{items_text}"
                        ),
                    }
                ],
            )
            result = _parse_json_response(response)
            if result and "judgments" in result:
                return result["judgments"]

            raise ValueError("LLM 未返回有效 JSON 响应")

        except anthropic.RateLimitError:
            delay = BASE_DELAY * (2 ** attempt)
            sys.stderr.write(
                f"[quality_gate] 限流，等待 {delay}s 后重试 "
                f"({attempt + 1}/{MAX_RETRIES})\n"
            )
            time.sleep(delay)
        except anthropic.APIConnectionError as e:
            delay = BASE_DELAY * (2 ** attempt)
            sys.stderr.write(
                f"[quality_gate] 连接失败: {e}，重试 "
                f"({attempt + 1}/{MAX_RETRIES})\n"
            )
            time.sleep(delay)
        except (anthropic.InternalServerError, ValueError) as e:
            delay = BASE_DELAY * (2 ** attempt)
            sys.stderr.write(
                f"[quality_gate] 错误: {e}，重试 "
                f"({attempt + 1}/{MAX_RETRIES})\n"
            )
            time.sleep(delay)

    raise RuntimeError(f"质量关卡 LLM 调用失败，已重试 {MAX_RETRIES} 次")


def quality_gate_filter(courses):
    """入库前二次过滤主入口（per D-01, D-02）

    第一步：联系方式硬性校验 — 微信和电话都为空直接过滤（per D-02）
    第二步：LLM 二次判断 — Haiku 快速确认是否为课程帖（per D-01）

    Args:
        courses: Phase 105 提取后的课程列表

    Returns:
        (filtered_courses, stats) 元组
        - filtered_courses: 通过所有关卡的课程列表
        - stats: {total, passed, llm_rejected, no_contact, failures}
          - failures: 每条失败记录包含 {sourceUrl, reason, detail}
    """
    if not courses:
        return [], {
            "total": 0,
            "passed": 0,
            "llm_rejected": 0,
            "no_contact": 0,
            "failures": [],
        }

    failures = []

    # 第一步：联系方式硬性校验（per D-02）
    contact_passed = []
    for course in courses:
        wechat = (course.get("contactWechat") or "").strip()
        phone = (course.get("contactPhone") or "").strip()
        if not wechat and not phone:
            failures.append({
                "sourceUrl": course.get("sourceUrl", ""),
                "title": course.get("title", ""),
                "reason": REASON_NO_CONTACT,
                "detail": "微信和电话都为空",
            })
        else:
            contact_passed.append(course)

    no_contact_count = len(courses) - len(contact_passed)

    if not contact_passed:
        return [], {
            "total": len(courses),
            "passed": 0,
            "llm_rejected": 0,
            "no_contact": no_contact_count,
            "failures": failures,
        }

    # 第二步：LLM 二次判断（per D-01）
    try:
        client = _get_client()
        judgments = _call_llm_with_retry(client, contact_passed)
    except RuntimeError:
        # LLM 调用完全失败，放行所有通过联系方式校验的课程（per T-106-02）
        sys.stderr.write(
            "[quality_gate] LLM 二次判断失败，放行所有通过联系方式校验的课程\n"
        )
        return contact_passed, {
            "total": len(courses),
            "passed": len(contact_passed),
            "llm_rejected": 0,
            "no_contact": no_contact_count,
            "failures": failures,
        }

    # 按 index 建立判断映射（index 从 1 开始，转为 0-based）
    index_to_judgment = {}
    for j in judgments:
        idx = j.get("index", 0) - 1
        if 0 <= idx < len(contact_passed):
            index_to_judgment[idx] = j

    # 过滤通过的课程
    filtered_courses = []
    llm_rejected_count = 0
    for i, course in enumerate(contact_passed):
        judgment = index_to_judgment.get(
            i, {"is_course": True, "reason": "未判断，默认通过"}
        )
        if judgment.get("is_course", True):
            filtered_courses.append(course)
        else:
            llm_rejected_count += 1
            failures.append({
                "sourceUrl": course.get("sourceUrl", ""),
                "title": course.get("title", ""),
                "reason": REASON_LLM_REJECTED,
                "detail": judgment.get("reason", "LLM 判断非课程帖"),
            })

    return filtered_courses, {
        "total": len(courses),
        "passed": len(filtered_courses),
        "llm_rejected": llm_rejected_count,
        "no_contact": no_contact_count,
        "failures": failures,
    }


def write_quality_log(results, stats, board, log_dir=None):
    """写入质量关卡日志（per D-03）

    Args:
        results: 通过质量关卡的课程列表
        stats: quality_gate_filter 返回的统计信息
        board: 板块名称
        log_dir: 可选日志目录路径（用于测试）
    """
    if log_dir is None:
        log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    os.makedirs(log_dir, exist_ok=True)
    date_str = time.strftime("%Y-%m-%d")
    log_path = os.path.join(log_dir, f"quality_log_{date_str}.json")

    # 仅记录失败条目（per D-03: 每条失败帖子记录 sourceUrl + 原因）
    log_entries = []
    for failure in stats.get("failures", []):
        log_entries.append({
            "sourceUrl": failure.get("sourceUrl", ""),
            "title": failure.get("title", ""),
            "reason": failure.get("reason", ""),
            "detail": failure.get("detail", ""),
            "board": board,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })

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

    sys.stderr.write(
        f"[quality_gate] 日志已写入: {log_path} ({len(log_entries)} 条)\n"
    )
