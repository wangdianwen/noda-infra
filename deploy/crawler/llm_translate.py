"""
llm_translate.py - 课程字段英文翻译模块（Phase 108）

在入库前将中文自由文本字段翻译为英文，供 /en 语言版本展示与搜索。
增量抓取（crawl-skykiwi.py）与历史回填（backfill_translations.py）共用本模块。

对外接口：
- translate_courses(courses, batch_size): 批量翻译，逐条合并 *En 字段。
  失败降级：*En = None，不阻塞管线。
"""

import json
import sys
import time

import anthropic

TRANSLATE_MODEL = "claude-haiku-4-5-20251001"
DEFAULT_BATCH_SIZE = 10
MAX_RETRIES = 3
RETRY_BASE_DELAY = 5

# 需要翻译的 JSON 键（camelCase，与 crawl 输出一致）
TRANSLATABLE_FIELDS = [
    "title", "subject", "gradeLevel", "description",
    "teacherInfo", "address", "scheduleInfo", "priceNote",
]

_TRANSLATE_TOOL = {
    "name": "translate_course_fields",
    "description": "将课程的中文字段翻译为英文（简洁忠实，不扩写）",
    "input_schema": {
        "type": "object",
        "properties": {
            "translations": {
                "type": "array",
                "description": "与输入条目按 index 一一对应的翻译结果",
                "items": {
                    "type": "object",
                    "properties": {
                        "index": {"type": "integer"},
                        "titleEn": {"type": "string"},
                        "subjectEn": {"type": "string"},
                        "gradeLevelEn": {"type": "string"},
                        "descriptionEn": {"type": "string"},
                        "teacherInfoEn": {"type": "string"},
                        "addressEn": {"type": "string"},
                        "scheduleInfoEn": {"type": "string"},
                        "priceNoteEn": {"type": "string"},
                    },
                    "required": ["index", "titleEn"],
                },
            }
        },
        "required": ["translations"],
    },
}

TRANSLATE_SYSTEM_PROMPT = """你是课程信息的中文到英文翻译器。规则：
1. 忠实翻译，简洁自然，面向新西兰家长，不扩写、不添加原文没有的信息
2. 数字、价格、URL、品牌名（NCEA/Cambridge/IB）保持原样
3. 年龄/年级表达本地化：4-8岁 → Age 4-8，Year7-13 → Year 7-13
4. 源字段为空或已是英文时，对应输出字段返回空字符串
5. 地址保留街道名原文（如 Albany Mall 不翻译），仅意译通用词"""


def _get_client():
    """创建 Anthropic 客户端（与 llm_extract 相同的环境变量约定）"""
    return anthropic.Anthropic()


def _sleep(seconds):
    time.sleep(seconds)


def _parse_json_response(response):
    """从 tool use 响应中提取 JSON 字典"""
    for block in response.content:
        if block.type == "tool_use":
            return block.input
    raise RuntimeError("响应中无 tool_use 块")


def _call_llm_with_retry(client, model, max_tokens, system, tools,
                         tool_choice, messages):
    """带限速重试的 LLM 调用（仿 llm_extract）"""
    last_error = None
    for attempt in range(MAX_RETRIES):
        try:
            response = client.messages.create(
                model=model,
                max_tokens=max_tokens,
                system=system,
                tools=tools,
                tool_choice=tool_choice,
                messages=messages,
            )
            return _parse_json_response(response)
        except (anthropic.BadRequestError, anthropic.APIError) as e:
            last_error = e
            _sleep(RETRY_BASE_DELAY * (2 ** attempt))
        except anthropic.RateLimitError:
            _sleep(RETRY_BASE_DELAY * (2 ** attempt))
            last_error = RuntimeError("Rate limit")
    raise RuntimeError(f"翻译调用超过最大重试次数: {last_error}")


def _build_batch_messages(batch):
    """构造批次消息：仅发送非空字段，减少 token"""
    items = []
    for i, course in enumerate(batch):
        item = {"index": i}
        for field in TRANSLATABLE_FIELDS:
            value = course.get(field)
            if isinstance(value, str) and value.strip():
                item[field] = value
        items.append(item)
    return [{"role": "user",
             "content": json.dumps({"items": items}, ensure_ascii=False)}]


def translate_batch(batch, client=None):
    """翻译单个批次，返回 index → 翻译 dict 的映射；失败抛异常"""
    if client is None:
        client = _get_client()
    result = _call_llm_with_retry(
        client=client,
        model=TRANSLATE_MODEL,
        max_tokens=8192,
        system=TRANSLATE_SYSTEM_PROMPT,
        tools=[_TRANSLATE_TOOL],
        tool_choice={"type": "tool", "name": "translate_course_fields"},
        messages=_build_batch_messages(batch),
    )
    translations = result.get("translations", [])
    return {t.get("index"): t for t in translations}


def translate_courses(courses, batch_size=DEFAULT_BATCH_SIZE):
    """批量翻译课程列表，逐条合并 *En 字段（失败为 None）"""
    client = None
    try:
        client = _get_client()
    except Exception as e:
        sys.stderr.write(f"[llm_translate] 客户端创建失败: {e}\n")

    for start in range(0, len(courses), batch_size):
        batch = courses[start:start + batch_size]
        try:
            if client is None:
                raise RuntimeError("无可用客户端")
            index_map = translate_batch(batch, client)
        except Exception as e:
            sys.stderr.write(
                f"[llm_translate] 批次 {start // batch_size} 翻译失败"
                f"（{len(batch)} 条置 None）: {e}\n")
            index_map = {}

        for i, course in enumerate(batch):
            t = index_map.get(i, {})
            for field in TRANSLATABLE_FIELDS:
                value = t.get(f"{field}En")
                course[f"{field}En"] = value if isinstance(value, str) and value.strip() else None

    return courses
