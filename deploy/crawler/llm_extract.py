#!/usr/bin/env python3
"""
llm_extract.py - LLM 详情提取核心模块
使用 Anthropic SDK 两步 Tool Use 提取课程结构化数据、生成改写描述、分类和标签

架构（per D-02）：
  第一步（Sonnet）：详情页全文 → 结构化字段 + 改写描述
  第二步（Haiku）：提取结果 → 分类 slug + 亮点标签
  审核（Haiku）：低置信度条目 → 四维度审核 + 自动修正

CLI:
  python3 scripts/llm_extract.py (不直接使用，由 crawl-skykiwi.py 调用)

导出:
  - extract_course_details: 单条课程完整提取入口
  - extract_single_post: 单条帖子提取（测试用）
  - classify_and_tag: 第二步分类+标签
  - fallback_classify: 关键词回退分类
  - audit_extraction: 低置信度审核
  - needs_audit: 判断是否需要审核
  - normalize_price: 价格缺失处理
"""

import sys
import os
import re
import json
import time

import anthropic

# 从 category_mapping 导入关键词回退分类
from category_mapping import map_subject_to_categories

# ============================================================
# 常量定义（per D-01, D-04）
# ============================================================

EXTRACT_MODEL = "claude-haiku-4-5-20251001"  # Haiku 提取（Sonnet 代理限流严重）
HAIKU_MODEL = "claude-haiku-4-5-20251001"    # 分类/标签/审核用 Haiku
MAX_RETRIES = 2  # Haiku 更便宜，多试一次
BASE_DELAY = 0.5  # 缩短基础延迟
CONFIDENCE_THRESHOLD = 0.7  # 低置信度阈值（Claude's Discretion）

# 28 个标准分类 slug（per D-08，来自 db_import.py CATEGORY_KEYWORDS + other-other 兜底）
VALID_CATEGORY_SLUGS = [
    "music-piano", "music-instruments", "music-vocal",
    "academic-math", "academic-english", "academic-science", "academic-business",
    "arts-painting", "arts-digital-art", "arts-calligraphy",
    "language-chinese", "language-other-languages",
    "sports-fitness", "sports-swimming", "sports-ball-games",
    "dance-dance", "dance-ballet", "dance-street-dance",
    "skills-driving", "skills-vocational", "skills-life-skills",
    "other-other",
]

# 预定义标签池（per D-09, D-10）
TAG_POOL = [
    "免费试听", "小班教学", "一对一", "华人老师", "周末班",
    "NCEA 辅导", "剑桥辅导", "在线授课", "上门服务", "双语教学",
    "考级辅导", "作业辅导", "经验丰富", "认证教师", "中英双语",
    "名师授课", "精品课程", "入门友好", "进阶提升", "成人可学",
]


# ============================================================
# Tool Use Schema 定义
# ============================================================

# 第一步：结构化字段提取 + 改写描述
_EXTRACT_TOOL = {
    "name": "extract_course_details",
    "description": "从课程帖子详情中提取结构化信息并生成面向家长的改写描述",
    "input_schema": {
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "description": "课程标题（如原文标题不准确可修正）",
            },
            "subject": {
                "type": "string",
                "description": "科目名称（如数学、英语、钢琴等）",
            },
            "gradeLevel": {
                "type": "string",
                "description": "年级范围（如 Year7-10、4-6岁等），无法确定则为空",
            },
            "price": {
                "type": "integer",
                "description": "每小时/每节课价格（纽币），无法确定则为 null",
            },
            "priceUnit": {
                "type": "string",
                "description": "价格单位（小时/节/次），默认'小时'",
            },
            "region": {
                "type": "string",
                "description": "地区（奥克兰/北岸/中区/东区/西区/南区/市中心）",
            },
            "contactWechat": {
                "type": "string",
                "description": "微信号，无法提取则为空字符串",
            },
            "contactPhone": {
                "type": "string",
                "description": "电话号码，无法提取则为空字符串",
            },
            "teacherInfo": {
                "type": "string",
                "description": "师资信息摘要（如教师资质、经验等）",
            },
            "locationType": {
                "type": "string",
                "enum": ["线上", "线下", "上门", "线上线下结合"],
                "description": "上课方式",
            },
            "trialLesson": {
                "type": "boolean",
                "description": "是否提供免费试听",
            },
            "description": {
                "type": "string",
                "description": "面向家长的改写描述，150-300字，专业、清晰、有说服力",
            },
            "confidence": {
                "type": "number",
                "description": "提取置信度 0-1，综合评估字段完整性和准确性",
            },
        },
        "required": [
            "title", "subject", "gradeLevel", "price", "priceUnit",
            "region", "contactWechat", "contactPhone", "description", "confidence"
        ],
    },
}

# 第二步：分类 + 标签
_CLASSIFY_TOOL = {
    "name": "classify_and_tag",
    "description": "基于提取的课程信息进行分类和生成亮点标签",
    "input_schema": {
        "type": "object",
        "properties": {
            "categorySlug": {
                "type": "string",
                "enum": VALID_CATEGORY_SLUGS,
                "description": "最匹配的标准分类 slug",
            },
            "categoryConfidence": {
                "type": "number",
                "description": "分类置信度 0-1",
            },
            "tags": {
                "type": "array",
                "items": {
                    "type": "string",
                    "enum": TAG_POOL,
                },
                "minItems": 3,
                "maxItems": 5,
                "description": "3-5 个亮点标签，从预定义标签池中选择",
            },
        },
        "required": ["categorySlug", "categoryConfidence", "tags"],
    },
}

# 审核：四维度检查
_AUDIT_TOOL = {
    "name": "audit_extraction",
    "description": "审核课程提取结果的完整性和准确性，输出结构化修正建议",
    "input_schema": {
        "type": "object",
        "properties": {
            "passed": {
                "type": "boolean",
                "description": "是否通过审核",
            },
            "fieldCompleteness": {
                "type": "object",
                "properties": {
                    "passed": {"type": "boolean"},
                    "missingFields": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "缺失的必填字段列表",
                    },
                },
            },
            "descriptionQuality": {
                "type": "object",
                "properties": {
                    "passed": {"type": "boolean"},
                    "issue": {"type": "string", "description": "问题描述"},
                    "suggestedFix": {"type": "string", "description": "建议的修正描述"},
                },
            },
            "classificationAccuracy": {
                "type": "object",
                "properties": {
                    "passed": {"type": "boolean"},
                    "suggestedSlug": {
                        "type": "string",
                        "description": "建议修正的分类 slug（仅当不通过时）",
                    },
                },
            },
            "tagAccuracy": {
                "type": "object",
                "properties": {
                    "passed": {"type": "boolean"},
                    "suggestedTags": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "建议修正的标签列表（仅当不通过时）",
                    },
                },
            },
        },
        "required": [
            "passed", "fieldCompleteness", "descriptionQuality",
            "classificationAccuracy", "tagAccuracy"
        ],
    },
}


# ============================================================
# 系统提示词（per D-05, D-06, D-09, D-10, D-13）
# ============================================================

EXTRACT_SYSTEM_PROMPT = """你是一个课外课程信息提取专家。从论坛帖子中提取课程相关的结构化信息。

提取规则：
- 标题：可适当修正原文标题，使其更准确反映课程内容
- 科目：提取主要教学科目（如数学、英语、钢琴等）
- 年级范围：如 Year7-10、4-6岁 等，无法确定则留空
- 价格：提取纽币价格（整数），如含"$"符号则提取数字部分，无法确定则为 null
- 价格单位：默认"小时"，如有明确标注则提取实际单位
- 地区：映射到奥克兰/北岸/中区/东区/西区/南区/市中心
- 联系方式：仔细提取微信（支持微信/WeChat/V/wx/Wechat等多种格式，只保留微信号本身）和电话号码
- 师资信息：提取教师资质、教学经验等信息摘要
- 上课方式：从线上/线下/上门/线上线下结合中选择
- 免费试听：判断是否提供免费试听/体验课

改写描述要求（per D-05, D-06）：
- 面向家长，专业、清晰、有说服力
- 150-300字
- 突出课程特色、师资亮点、教学优势
- 不添加原文中没有的信息"""

CLASSIFY_SYSTEM_PROMPT = f"""你是一个课程分类专家。根据提取的课程信息，将课程映射到最匹配的标准分类 slug，并从预定义标签池中选择 3-5 个亮点标签。

标准分类列表：{', '.join(VALID_CATEGORY_SLUGS)}

预定义标签池：{', '.join(TAG_POOL)}

分类规则：
- 选择最匹配的标准分类 slug
- 从标签池中选择 3-5 个最能代表课程特征的标签（per D-09, D-10）
- 如果课程不属于任何明确分类，使用 other-other"""

AUDIT_SYSTEM_PROMPT = """你是一个课程数据质量审核员。检查提取结果的完整性和准确性。

审核四个维度（per D-13）：
1. 字段完整性：必填字段（title, subject, region, contactWechat/contactPhone）是否齐全
2. 描述质量：改写描述是否通顺、有说服力、150-300字
3. 分类准确性：分类是否与科目/内容匹配
4. 标签准确性：标签是否反映课程特征

如发现问题，在对应维度提供具体修正建议。审核目的是确保数据质量，修正建议应当具体可执行。"""


# ============================================================
# 核心函数
# ============================================================


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
            # 尝试提取 markdown code block 中的 JSON
            cb = re.search(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```', text)
            if cb:
                try:
                    return json.loads(cb.group(1))
                except json.JSONDecodeError:
                    pass
            # 尝试提取最后一个完整的 JSON 对象（贪心匹配到最外层 { }）
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


def _call_llm_with_retry(client, model, max_tokens, system, tools, tool_choice, messages):
    """通用 LLM 调用 + 指数退避重试（兼容 tool_use 和纯文本 JSON 模式）

    Args:
        client: Anthropic 客户端实例
        model: 模型名称
        max_tokens: 最大 token 数
        system: 系统提示词
        tools: Tool Use schema 列表（用于提取输出格式描述）
        tool_choice: Tool 选择策略
        messages: 消息列表

    Returns:
        解析后的 JSON 字典

    Raises:
        RuntimeError: 超过最大重试次数
    """
    # 从 tool schema 提取输出格式描述
    tool = tools[0] if tools else None
    schema_desc = ""
    if tool and "input_schema" in tool:
        schema_desc = f"\n\n请严格以 JSON 格式输出，schema 如下：\n{json.dumps(tool['input_schema'], ensure_ascii=False, indent=2)}"

    for attempt in range(MAX_RETRIES):
        try:
            # 先尝试 tool_use 模式
            try:
                response = client.messages.create(
                    model=model,
                    max_tokens=max_tokens,
                    system=system,
                    tools=tools,
                    tool_choice=tool_choice,
                    messages=messages,
                )
                result = _parse_json_response(response)
                if result:
                    return result
            except (anthropic.BadRequestError, anthropic.APIError):
                pass

            # 纯文本 JSON 模式
            response = client.messages.create(
                model=model,
                max_tokens=max_tokens,
                system=system,
                messages=messages,
            )
            result = _parse_json_response(response)
            if result:
                return result

            raise ValueError("LLM 未返回有效 JSON 响应")

        except anthropic.RateLimitError:
            delay = BASE_DELAY * (2 ** attempt)
            sys.stderr.write(
                f"[llm_extract] 限流，等待 {delay}s 后重试 ({attempt + 1}/{MAX_RETRIES})\n"
            )
            time.sleep(delay)
        except anthropic.APIConnectionError as e:
            delay = BASE_DELAY * (2 ** attempt)
            sys.stderr.write(
                f"[llm_extract] 连接失败: {e}，重试 ({attempt + 1}/{MAX_RETRIES})\n"
            )
            time.sleep(delay)
        except (anthropic.InternalServerError, ValueError) as e:
            delay = BASE_DELAY * (2 ** attempt)
            sys.stderr.write(
                f"[llm_extract] 错误: {e}，重试 ({attempt + 1}/{MAX_RETRIES})\n"
            )
            time.sleep(delay)

    raise RuntimeError(f"LLM 调用失败，已重试 {MAX_RETRIES} 次")


def _clean_text(text, max_length=3000):
    """清洗详情页文本

    去除 HTML 标签、图片链接、连续空行，截断到 max_length。
    """
    if not text:
        return ""

    # 去除 HTML 标签
    cleaned = re.sub(r'<[^>]+>', '', text)

    # 去除图片链接
    cleaned = re.sub(
        r'https?://\S+\.(?:jpg|jpeg|png|gif|webp|bmp|svg)(?:\?\S*)?',
        '', cleaned, flags=re.IGNORECASE
    )

    # 清理论坛元数据（Discuz 编辑信息、附件信息等）
    cleaned = re.sub(r'本帖最后由\s*\S+\s*于\s*[\d\-]+\s*[\d:]+\s*编辑\s*', '', cleaned)
    cleaned = re.sub(r'\d{4}-\d{1,2}-\d{1,2}\s*\d{2}:\d{2}:\d{2}\s*上传\s*', '', cleaned)
    cleaned = re.sub(r'下载附件\s*\([^)]*\)\s*', '', cleaned)
    cleaned = re.sub(r'\(\d+\.\d+\s*(?:KB|MB|bytes)\)', '', cleaned)

    # 去除连续空行（保留单个换行）
    cleaned = re.sub(r'\n{3,}', '\n\n', cleaned)

    # 去除首尾空白
    cleaned = cleaned.strip()

    # 截断到最大长度
    if len(cleaned) > max_length:
        cleaned = cleaned[:max_length]

    return cleaned


def _step1_extract(client, detail_text):
    """第一步 Haiku 提取结构化字段 + 改写描述（per D-02）

    Args:
        client: Anthropic 客户端实例
        detail_text: 详情页原始文本

    Returns:
        提取结果字典，失败返回 None
    """
    cleaned_text = _clean_text(detail_text)
    if not cleaned_text.strip():
        return None

    try:
        result = _call_llm_with_retry(
            client=client,
            model=EXTRACT_MODEL,
            max_tokens=2048,  # 降低以减少限流风险
            system=EXTRACT_SYSTEM_PROMPT,
            tools=[_EXTRACT_TOOL],
            tool_choice={"type": "any"},
            messages=[{
                "role": "user",
                "content": f"请从以下课程帖子中提取结构化信息并生成改写描述：\n{cleaned_text}",
            }],
        )
        return result
    except RuntimeError:
        return None


def _step2_classify(client, step1_result):
    """第二步 Haiku 分类 + 标签生成（per D-02）

    Args:
        client: Anthropic 客户端实例
        step1_result: 第一步提取结果字典

    Returns:
        分类标签结果字典，失败返回 None
    """
    try:
        result = _call_llm_with_retry(
            client=client,
            model=HAIKU_MODEL,
            max_tokens=1024,  # 分类输出很短
            system=CLASSIFY_SYSTEM_PROMPT,
            tools=[_CLASSIFY_TOOL],
            tool_choice={"type": "any"},
            messages=[{
                "role": "user",
                "content": f"基于以下提取结果进行分类和标签生成：\n{json.dumps(step1_result, ensure_ascii=False)}",
            }],
        )
        return result
    except RuntimeError:
        return None


def _call_classify_llm(client, step1_result):
    """内部调用：第二步 LLM 分类（供测试 mock 使用）

    Args:
        client: Anthropic 客户端实例
        step1_result: 第一步提取结果

    Returns:
        分类结果字典
    """
    return _step2_classify(client, step1_result)


def _audit_and_fix(client, step1_result, step2_result):
    """低置信度审核 + 自动修正（per D-11, D-12, D-13, D-14）

    Args:
        client: Anthropic 客户端实例
        step1_result: 第一步提取结果
        step2_result: 第二步分类结果

    Returns:
        合并后的结果字典（包含审核修正）
    """
    # 合并两步结果作为审核输入
    combined = {**step1_result, **step2_result}

    try:
        audit_result = _call_llm_with_retry(
            client=client,
            model=HAIKU_MODEL,
            max_tokens=1024,  # 审核输出较短
            system=AUDIT_SYSTEM_PROMPT,
            tools=[_AUDIT_TOOL],
            tool_choice={"type": "any"},
            messages=[{
                "role": "user",
                "content": f"请审核以下课程提取结果的完整性和准确性：\n{json.dumps(combined, ensure_ascii=False)}",
            }],
        )
    except RuntimeError:
        # 审核失败，返回原始合并结果
        return combined

    # 自动应用修正（per D-14）
    result = {**combined}

    # 修正描述
    desc_quality = audit_result.get("descriptionQuality", {})
    if not desc_quality.get("passed", True) and desc_quality.get("suggestedFix"):
        result["description"] = desc_quality["suggestedFix"]

    # 修正分类
    cls_accuracy = audit_result.get("classificationAccuracy", {})
    if not cls_accuracy.get("passed", True) and cls_accuracy.get("suggestedSlug"):
        result["categorySlug"] = cls_accuracy["suggestedSlug"]

    # 修正标签
    tag_accuracy = audit_result.get("tagAccuracy", {})
    if not tag_accuracy.get("passed", True) and tag_accuracy.get("suggestedTags"):
        result["tags"] = tag_accuracy["suggestedTags"]

    result["llmAuditPassed"] = audit_result.get("passed", False)
    return result


def _fallback_classify(step1_result):
    """关键词回退分类（per D-08）

    Args:
        step1_result: 第一步提取结果

    Returns:
        回退分类结果字典 {categorySlug, categoryConfidence, tags}
    """
    subject = step1_result.get("subject", "")
    slugs = map_subject_to_categories(subject)

    return {
        "categorySlug": slugs[0] if slugs else "other-other",
        "categoryConfidence": 0.3,  # 回退分类置信度低
        "tags": [],
    }


def needs_audit(result):
    """判断是否需要审核（per D-11）

    仅根据置信度判断。置信度由第一步 Sonnet 综合评估字段完整性和准确性，
    已内含描述质量、字段缺失等因素。

    Args:
        result: 提取结果字典

    Returns:
        True 表示需要审核
    """
    confidence = result.get("confidence", 0)
    return confidence < CONFIDENCE_THRESHOLD


def normalize_price(result):
    """价格缺失处理（per D-16）

    Args:
        result: 提取结果字典

    Returns:
        处理后的结果字典（新增 priceNote 字段）
    """
    normalized = {**result}
    price = normalized.get("price")

    if price is None:
        normalized["priceNote"] = "面议"
        normalized["priceUnit"] = "面议"

    return normalized


def classify_and_tag(extract_result):
    """第二步分类+标签入口（供测试直接调用）

    Args:
        extract_result: 第一步提取结果

    Returns:
        分类标签结果字典
    """
    client = _get_client()
    return _step2_classify(client, extract_result)


def fallback_classify(extract_result):
    """关键词回退分类入口（供测试直接调用）

    Args:
        extract_result: 第一步提取结果

    Returns:
        回退分类结果
    """
    return _fallback_classify(extract_result)


def audit_extraction(result):
    """审核低置信度条目（供测试直接调用）

    Args:
        result: 低置信度提取结果

    Returns:
        审核修正后的结果
    """
    client = _get_client()
    step2_result = {
        "categorySlug": result.get("categorySlug", "other-other"),
        "tags": result.get("tags", []),
    }
    return _audit_and_fix(client, result, step2_result)


def _regex_extract_contacts(text):
    """当 LLM 失败时，用正则从原文提取联系方式

    Returns:
        dict with contactWechat, contactPhone, or None if nothing found
    """
    if not text:
        return None

    wechat = ""
    phone = ""

    # 微信号：支持 微信/WeChat/V/wx/Wechat/微信号 等前缀
    wx_patterns = [
        r'(?:微信|WeChat|Wechat|wechat|V|v|wx|WX|Wx|微信号|加微信|联系微信)\s*[:：]?\s*([A-Za-z0-9_-]{5,20})',
        r'(?:微信|WeChat|Wechat|wechat|V|v|wx|WX|Wx)\s*[:：]?\s*([A-Za-z][A-Za-z0-9_-]{4,19})',
    ]
    for pat in wx_patterns:
        m = re.search(pat, text)
        if m:
            wechat = m.group(1)
            break

    # 电话号码：新西兰格式 (02x xxx xxxx) 或中国格式
    phone_patterns = [
        r'(?:电话|手机|联系|phone|tel|call)\s*[:：]?\s*(0[2-9](?:[\s-]?\d){7,8})',
        r'(?:电话|手机|联系|phone|tel|call)\s*[:：]?\s*(\+?64[\s-]?[2-9](?:[\s-]?\d){7,8})',
        r'(021[\s-]?\d{3,4}[\s-]?\d{3,4})',
        r'(022[\s-]?\d{3,4}[\s-]?\d{3,4})',
        r'(027[\s-]?\d{3,4}[\s-]?\d{3,4})',
        r'(028[\s-]?\d{3,4}[\s-]?\d{3,4})',
        r'(020[\s-]?\d{3,4}[\s-]?\d{4})',
    ]
    for pat in phone_patterns:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            phone = m.group(1).strip()
            break

    if wechat or phone:
        return {"contactWechat": wechat, "contactPhone": phone}
    return None


def extract_single_post(post):
    """单条帖子提取（per D-03 逐条处理）

    Args:
        post: 帖子数据字典

    Returns:
        提取结果字典，不符合条件返回 None
    """
    # 1. 获取原文内容
    original_content = post.get("originalContent", "")
    if not original_content or not original_content.strip():
        # 没有原文但有标题，用标题作为输入
        title = post.get("title", "")
        if not title:
            return None
        original_content = title

    # 2. 第一步 Sonnet 提取
    client = _get_client()
    step1_result = _step1_extract(client, original_content)
    if step1_result is None:
        # LLM 失败，使用 regex 回退提取联系方式
        contacts = _regex_extract_contacts(original_content)
        if contacts is None:
            sys.stderr.write(
                f"[llm_extract] LLM+regex 均未提取到联系方式: "
                f"{post.get('sourceUrl', '?')}\n"
            )
            return None
        sys.stderr.write(
            f"[llm_extract] regex 回退提取成功: "
            f"{post.get('sourceUrl', '?')}\n"
        )
        step1_result = {
            "subject": post.get("title", ""),
            "description": post.get("title", ""),
            "contactWechat": contacts["contactWechat"],
            "contactPhone": contacts["contactPhone"],
            "confidence": 0.3,
        }

    # 3. 联系方式硬性检查（per D-15）
    wechat = (step1_result.get("contactWechat") or "").strip()
    phone = (step1_result.get("contactPhone") or "").strip()
    if not wechat and not phone:
        # LLM 提取结果无联系方式，尝试 regex 回退
        contacts = _regex_extract_contacts(original_content)
        if contacts and (contacts["contactWechat"] or contacts["contactPhone"]):
            sys.stderr.write(
                f"[llm_extract] 联系方式 regex 补充: "
                f"{post.get('sourceUrl', '?')}\n"
            )
            step1_result["contactWechat"] = contacts["contactWechat"]
            step1_result["contactPhone"] = contacts["contactPhone"]
            wechat = contacts["contactWechat"]
            phone = contacts["contactPhone"]
        else:
            return None

    # 4. 价格缺失处理（per D-16）
    step1_result = normalize_price(step1_result)

    # 5. 第二步 Haiku 分类，失败回退到关键词分类
    step2_result = _step2_classify(client, step1_result)
    if step2_result is None:
        step2_result = _fallback_classify(step1_result)

    # 6. 合并结果
    merged = {**post, **step1_result}

    # 添加第二步结果
    merged["categorySlug"] = step2_result.get("categorySlug", "other-other")
    merged["tags"] = step2_result.get("tags", [])
    merged["llmCategorySlug"] = step2_result.get("categorySlug", "other-other")
    merged["llmConfidence"] = step1_result.get("confidence", 0)

    # 7. 低置信度审核（per D-11）
    if needs_audit(step1_result):
        merged = _audit_and_fix(client, step1_result, step2_result)
        # 保留原始帖子数据
        merged = {**post, **merged}
        merged["llmAuditPassed"] = merged.get("llmAuditPassed", False)
    else:
        merged["llmAuditPassed"] = True

    return merged


def write_extract_log(results: list, board: str, log_dir=None):
    """写入提取日志到 JSON 文件

    Args:
        results: 提取后的课程列表
        board: 板块名称
        log_dir: 可选日志目录路径（用于测试）
    """
    if log_dir is None:
        log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    os.makedirs(log_dir, exist_ok=True)
    date_str = time.strftime("%Y-%m-%d")
    log_path = os.path.join(log_dir, f"extract_log_{date_str}.json")

    log_entries = []
    for course in results:
        if not course or 'error' in course:
            continue
        log_entries.append({
            "sourceUrl": course.get("sourceUrl", ""),
            "title": course.get("title", ""),
            "subject": course.get("subject", ""),
            "categorySlug": course.get("llmCategorySlug", ""),
            "tags": course.get("tags", []),
            "confidence": course.get("llmConfidence", 0),
            "auditPassed": course.get("llmAuditPassed", None),
            "descriptionLength": len(course.get("description", "") or ""),
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            # 完整提取字段（修复数据丢失问题）
            "contactWechat": course.get("contactWechat", ""),
            "contactPhone": course.get("contactPhone", ""),
            "teacherInfo": course.get("teacherInfo", ""),
            "description": course.get("description", ""),
            "price": course.get("price"),
            "priceNote": course.get("priceNote", ""),
            "priceUnit": course.get("priceUnit", "小时"),
            "gradeLevel": course.get("gradeLevel", ""),
            "region": course.get("region", "奥克兰"),
            "locationType": course.get("locationType", "线下"),
            "trialLesson": course.get("trialLesson", False),
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

    sys.stderr.write(f"[llm_extract] 日志已写入: {log_path} ({len(log_entries)} 条)\n")


def extract_course_details(course):
    """主入口：对单条课程执行完整提取流程（per D-03）

    Args:
        course: 课程数据字典（包含 originalContent 等字段）

    Returns:
        提取后的完整课程数据字典，不符合条件返回 None
    """
    return extract_single_post(course)
