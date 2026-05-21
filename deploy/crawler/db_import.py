#!/usr/bin/env python3
"""
db_import.py - 数据库导入模块

将爬虫 JSON 数据写入 PostgreSQL，包含：
- 分类映射（163 种科目 → 28 个标准分类，移植自 category-mapping-rules.ts）
- 8 维度质量评分（移植自 universal-quality-calculator.ts，含热度维度）
- pg_trgm 排重检测（降级 ILIKE）
- Profile 查找/创建
- Course upsert（ON CONFLICT sourceUrl）

使用方式:
  # 被 crawl-skykiwi.py 自动调用（当 DATABASE_URL 环境变量存在时）
  # 或独立使用:
  DATABASE_URL=postgresql://... python3 -c "
    import json, db_import
    courses = json.load(open('data.json'))
    db_import.import_courses(courses)
  "
"""

import sys
import os
import re
import uuid
import math
from datetime import datetime, timezone

# ============================================================
# 分类映射规则（移植自 @noda-apps/shared/utils/category-mapping-rules.ts）
# ============================================================

CATEGORY_KEYWORDS = {
    # 音乐艺术
    'music-piano': ['钢琴', '琴', '键盘'],
    'music-instruments': ['小提琴', '吉他', '古筝', '管乐', '弦乐', '管乐器', '弦乐器', '大提琴', '中提琴', '长笛', '萨克斯', '单簧管'],
    'music-vocal': ['声乐', '歌唱', '合唱', '音乐理论', '乐理', '视唱练耳', '指挥', '音乐', '乐器', '表演'],

    # 学科辅导
    'academic-math': ['数学', '微积分', '统计', '奥数', '心算', '算术', '代数', '几何'],
    'academic-english': ['英语', '英文', '雅思', '托福', 'ESOL', 'PTE', '英文写作', '阅读', '写作'],
    'academic-science': ['物理', '化学', '生物', '科学', '理科', '综合科学'],
    'academic-business': ['商科', '会计', '经济', '金融', 'NCEA商科', '商业', '商法', '信息系统'],

    # 美术设计
    'arts-painting': ['绘画', '素描', '水彩', '油画', '创意画', '美术', '画画', '速写', '艺术'],
    'arts-digital-art': ['平面设计', '插画', '数字艺术', 'UI设计', '设计', 'Photoshop', 'Illustrator', '摄影'],
    'arts-calligraphy': ['书法', '国画', '毛笔', '水墨', '硬笔书法'],

    # 语言学习
    'language-chinese': ['中文', '国语', '国学', '文学', '汉语', '创意写作', '阅读理解', '沟通'],
    'language-other-languages': ['日语', '韩语', '粤语', '西班牙语', '法语', '德语', '外语', '意大利语'],

    # 体育健身
    'sports-fitness': ['瑜伽', '体育健身', '普拉提', '健身', '体能训练', '有氧', '健身房', '体育', '体育培训', '艺术体操'],
    'sports-swimming': ['游泳', '水上运动', '蛙泳', '自由泳', '仰泳', '蝶泳'],
    'sports-ball-games': ['足球', '篮球', '网球', '羽毛球', '乒乓球', '球类', '排球', '橄榄球', '棒球'],

    # 舞蹈表演
    'dance-dance': ['舞蹈', '舞蹈基础', '舞蹈艺术', '形体舞蹈', '中国舞', '当代舞', '民族舞'],
    'dance-ballet': ['芭蕾', '形体训练', '芭蕾舞'],
    'dance-street-dance': ['爵士舞', '韩舞', '街舞', 'Hip-Hop', '流行舞', 'K-Pop', 'Breaking', 'Locking'],

    # 技能培训
    'skills-driving': ['驾照', '驾驶', '驾照考试', '驾驶培训'],
    'skills-vocational': ['叉车', '建筑', '职业', '技能培训', '职业培训', '焊工', '电工', '法律'],
    'skills-life-skills': ['咖啡', '烘焙', '手工', '生活技能', '手工艺术', '烹饪', '厨艺', '美容按摩', '按摩', '语言沟通', '学校事务'],
}


def map_subject_to_categories(subject):
    """将科目字符串映射到分类 slug 列表

    移植自 mapSubjectToCategories()，支持中英文分隔符。
    返回: ['academic-math'] 或 ['other-other']
    """
    if not subject or not subject.strip():
        return ['other-other']

    matched = []
    subject_lower = subject.lower()

    for category_slug, keywords in CATEGORY_KEYWORDS.items():
        for keyword in keywords:
            if keyword.lower() in subject_lower:
                if category_slug not in matched:
                    matched.append(category_slug)
                break

    return matched if matched else ['other-other']


# ============================================================
# 8 维度质量评分（移植自 universal-quality-calculator.ts）
# 各维度满分: completeness=14, price=13, contact=9, description=9,
#             freshness=18, source=9, richness=18, popularity=10
# 总计 = 100
# ============================================================

def calculate_quality_score(course_data):
    """计算课程 8 维度质量评分（总分 0-100）

    维度（与 TS 版本 universal-quality-calculator.ts 严格一致）:
    - 字段齐全度 (14): title3 + categoryId3 + region3 + price3 + description2
    - 价格合理性 (13): 价格在 7-500 范围
    - 联系方式质量 (9): wechat/phone
    - 描述精确度 (9): 长度>50:5 + 关键词密度3+:4
    - 数据新鲜度 (18): ≤30天:18, ≤90天:9
    - 数据来源 (9): user=9, skykiwi=6, other=3
    - 内容丰富度 (18): trialLesson:6, qualifications:7, desc>100:5
    - 热度 (10): log(1+views)*0.6 + log(1+inquiries)*2.0, cap归一化
    """
    scores = {
        'completeness': _score_completeness(course_data),
        'price_reasonability': _score_price(course_data),
        'contact_quality': _score_contact(course_data),
        'description_accuracy': _score_description(course_data),
        'freshness': _score_freshness(course_data),
        'source': _score_source(course_data),
        'richness': _score_richness(course_data),
        'popularity': _score_popularity(course_data),
    }
    total = sum(scores.values())
    return min(100, max(0, total))


def _score_completeness(c):
    """字段齐全度 (14 分) — 与 TS calculateCompleteness 严格一致

    title:3, categoryId:3, region:3, price:3, description:2
    """
    score = 0
    if c.get('title', '').strip():
        score += 3
    if c.get('categoryId'):
        score += 3
    if c.get('region', '').strip():
        score += 3
    if c.get('price') is not None:
        score += 3
    if c.get('description', '').strip():
        score += 2
    return score


def _score_price(c):
    """价格合理性 (13 分) — 与 TS calculatePriceReasonability 严格一致

    价格在 7-500 范围即满分 13
    """
    price = c.get('price')
    if price is None:
        return 0
    if 7 <= price <= 500:
        return 13
    return 0


def _score_contact(c):
    """联系方式质量 (9 分) — 与 TS calculateContactQuality 严格一致

    wechat 或 phone 非空: 9 分
    """
    if c.get('contactWechat') or c.get('contactPhone'):
        return 9
    return 0


def _score_description(c):
    """描述精确度 (9 分) — 与 TS calculateDescriptionAccuracy 严格一致

    评分规则（per 141-01-SUMMARY.md）:
    - 长度 > 50 字符: 5 分
    - 包含 3+ 个关键词: 4 分
    - 包含 1-2 个关键词: 2 分
    """
    llm_desc = c.get('description', '')
    title = c.get('title', '')
    subject = c.get('subject', '')
    score = 0

    # 1. 长度检查（5 分）— 优先使用 LLM description
    check_text = llm_desc if llm_desc else c.get('originalContent', '')
    if check_text and len(check_text) > 50:
        score += 5

    # 2. 关键词密度（4 分）— 与 TS extractKeywords 逻辑一致
    keywords = set()
    title_words = re.findall(r'[一-龥]{2,4}', title)
    stop_words = {'的', '是', '在', '有', '和', '了', '与', '及'}
    keywords.update(w for w in title_words if w not in stop_words)
    if subject and subject.strip():
        keywords.add(subject.strip())

    keyword_count = sum(1 for kw in keywords if kw in check_text)
    if keyword_count >= 3:
        score += 4
    elif keyword_count >= 1:
        score += 2

    return score


def _score_freshness(c):
    """数据新鲜度 (18 分) — 与 TS calculateFreshness 严格一致

    ≤30天: 18, ≤90天: 9, >90天: 0
    无 crawlMetadata 视为最新（18 分）
    """
    crawled_at = c.get('crawlMetadata', {}).get('crawledAt')
    if not crawled_at:
        return 18  # 视为最新
    try:
        created = datetime.fromisoformat(crawled_at.replace('Z', '+00:00'))
        days = (datetime.now(timezone.utc) - created).days
        if days <= 30:
            return 18
        elif days <= 90:
            return 9
        return 0
    except Exception:
        return 18


def _score_source(c):
    """数据来源 (9 分) — 与 TS calculateSourceScore 严格一致

    user=9, skykiwi=6, other=3
    """
    source = c.get('sourcePlatform', 'skykiwi')
    if source == 'user':
        return 9
    elif source == 'skykiwi':
        return 6
    return 3


def _score_richness(c):
    """内容丰富度 (18 分) — 与 TS calculateRichness 严格一致

    评分规则:
    - trialLesson = true: 6 分
    - teacherQualifications 非空: 7 分
    - description 长度 > 100: 5 分
    """
    score = 0

    # trialLesson (6 分)
    if c.get('trialLesson') is True:
        score += 6

    # teacherQualifications (7 分)
    qualifications = c.get('teacherQualifications', '')
    if qualifications and qualifications.strip():
        score += 7

    # description 长度 (5 分)
    desc = c.get('description', '')
    if desc and len(desc) > 100:
        score += 5

    return score


def _score_popularity(c):
    """热度评分 (10 分) — 与 TS calculatePopularity 严格一致

    公式: math.log(1 + statsViews) * 0.6 + math.log(1 + statsInquiries) * 2.0
    归一化: min(10, raw_score / POPULARITY_CAP * 10)
    POPULARITY_CAP = 20（与 TypeScript 版本一致，per D-05, D-06）

    使用 math.log（自然对数）与 TS Math.log 保持一致（per D-16）。
    """
    POPULARITY_CAP = 20
    views = c.get('statsViews') or 0
    inquiries = c.get('statsInquiries') or 0
    raw_score = math.log(1 + views) * 0.6 + math.log(1 + inquiries) * 2.0
    return min(10, raw_score / POPULARITY_CAP * 10)


# ============================================================
# 数据库操作
# ============================================================

def _get_connection():
    """获取数据库连接，DATABASE_URL 不存在时返回 None"""
    db_url = os.environ.get('DATABASE_URL')
    if not db_url:
        return None
    try:
        import psycopg
        # Strip Drizzle/pg-pool params incompatible with psycopg
        from urllib.parse import urlparse, urlunparse, parse_qs, urlencode
        parsed = urlparse(db_url)
        qs = {k: v[0] for k, v in parse_qs(parsed.query).items()
              if k not in ('connection_limit', 'pool_timeout')}
        clean = parsed._replace(query=urlencode(qs))
        conn = psycopg.connect(urlunparse(clean))
        return conn
    except Exception as e:
        sys.stderr.write(f"[db_import] 数据库连接失败: {e}\n")
        return None


def _load_category_map(conn):
    """从 categories 表加载 slug → id 映射"""
    category_map = {}
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id, slug FROM categories")
            for row in cur.fetchall():
                category_map[row[1].lower()] = str(row[0])
    except Exception as e:
        sys.stderr.write(f"[db_import] 加载分类映射失败: {e}\n")
    return category_map


def _match_category_id(subject, category_map):
    """用 subject 匹配分类 slug → 返回 category_id 或 None"""
    slugs = map_subject_to_categories(subject)
    for slug in slugs:
        cat_id = category_map.get(slug)
        if cat_id:
            return cat_id
    return None


def _extract_tid(url):
    """从 skykiwi URL 提取帖子 tid"""
    if not url:
        return None
    m = re.search(r'tid=(\d+)', url)
    if m:
        return m.group(1)
    m = re.search(r'thread-(\d+)', url)
    if m:
        return m.group(1)
    return None


def _check_tid_duplicate(conn, source_url):
    """基于 tid 精确去重 — 同 tid 即同一帖子"""
    tid = _extract_tid(source_url)
    if not tid:
        return None
    try:
        with conn.cursor() as cur:
            # 查找同 tid 且 sourceUrl 不同的已存在课程
            cur.execute("""
                SELECT id FROM courses
                WHERE source_url != %s
                  AND (
                    source_url LIKE %s
                    OR source_url LIKE %s
                  )
                  AND is_duplicate = false
                LIMIT 1
            """, (source_url, f'%tid={tid}%', f'%thread-{tid}%'))
            row = cur.fetchone()
            if row:
                return str(row[0])
    except Exception as e:
        sys.stderr.write(f"[db_import] tid 去重检查失败: {e}\n")
    return None


def _check_duplicate(conn, title, source_platform, city,
                     wechat=None, phone=None, subject=None, threshold=0.8,
                     source_url=None):
    """检查标题相似课程（排重检测）— 三级优先级

    优先级 1: tid 精确去重（同 tid = 同一帖子）
    优先级 2: 标题精确匹配（标题完全一致 = 重复）
    优先级 3: pg_trgm similarity() + 联系方式匹配，不可用时降级 ILIKE
    """
    try:
        with conn.cursor() as cur:
            # 优先级 1: tid 精确去重
            if source_url:
                tid_dup = _check_tid_duplicate(conn, source_url)
                if tid_dup:
                    sys.stderr.write(f"[db_import] tid 去重命中: {source_url}\n")
                    return tid_dup

            # 优先级 2: 标题精确匹配
            cur.execute("""
                SELECT id FROM courses
                WHERE source_platform = %s AND city = %s
                  AND is_duplicate = false
                  AND TRIM(title) = TRIM(%s)
                LIMIT 1
            """, (source_platform, city, title))
            row = cur.fetchone()
            if row:
                return str(row[0])

            # 优先级 3: pg_trgm similarity
            cur.execute("""
                SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'
            """)
            has_pgtrgm = cur.fetchone() is not None

            if has_pgtrgm:
                cur.execute("""
                    SELECT c.id, similarity(c.title, %s) as sim
                    FROM courses c
                    JOIN profiles p ON c.teacher_id = p.id
                    WHERE c.source_platform = %s AND c.city = %s
                      AND c.is_duplicate = false
                      AND (
                        similarity(c.title, %s) > %s
                        OR (%s IS NOT NULL AND p.wechat = %s AND p.wechat IS NOT NULL AND p.wechat != '')
                        OR (%s IS NOT NULL AND p.phone = %s AND p.phone IS NOT NULL AND p.phone != '')
                      )
                    ORDER BY sim DESC LIMIT 1
                """, (title, source_platform, city, title, threshold,
                      wechat, wechat, phone, phone))
                row = cur.fetchone()
                if row:
                    return str(row[0])
            else:
                # 降级 ILIKE：提取关键词
                keywords = re.findall(r'[\u4e00-\u9fa5]{2,4}', title) or [title[:4]]
                conditions = ' OR '.join(["title ILIKE %s"] * min(len(keywords), 3))
                params = [f'%{kw}%' for kw in keywords[:3]] + [source_platform, city]
                cur.execute(f"""
                    SELECT id FROM courses
                    WHERE source_platform = %s AND city = %s
                      AND is_duplicate = false
                      AND ({conditions})
                    LIMIT 1
                """, params)
                row = cur.fetchone()
                if row:
                    return str(row[0])
    except Exception as e:
        sys.stderr.write(f"[db_import] 排重检查失败: {e}\n")
    return None


def find_or_create_profile(conn, wechat=None, phone=None):
    """按联系方式查找/创建 profile，返回 profile id (uuid string)"""
    with conn.cursor() as cur:
        # 按 wechat 查找
        if wechat and wechat.strip():
            cur.execute("SELECT id FROM profiles WHERE wechat = %s LIMIT 1", (wechat.strip(),))
            row = cur.fetchone()
            if row:
                return str(row[0])

        # 按 phone 查找
        if phone and phone.strip():
            cur.execute("SELECT id FROM profiles WHERE phone = %s LIMIT 1", (phone.strip(),))
            row = cur.fetchone()
            if row:
                return str(row[0])

        # 创建新 profile
        new_id = str(uuid.uuid4())
        cur.execute(
            """INSERT INTO profiles (id, name, wechat, phone, source, source_platform)
               VALUES (%s, %s, %s, %s, %s, %s)""",
            (new_id, None, wechat, phone, 'skykiwi', 'skykiwi')
        )
        return new_id


def upsert_course(conn, teacher_id, course_data, category_id=None, is_duplicate=False, duplicate_of=None, quality_score=0):
    """基于 sourceUrl 的 INSERT ON CONFLICT DO UPDATE"""
    # 注意：status、expired_at、archived_at 不在 INSERT 和 ON CONFLICT DO UPDATE 中
    # 原因：爬虫不能覆盖生命周期管理字段（Phase 113 D-05）
    # 注意：is_duplicate、duplicate_of 不在 ON CONFLICT DO UPDATE 中
    # 原因：保留历史排重标记，不再每次 import 全量重置（Phase 119 D-10）
    # 新课程的 status 默认值为 'active'（数据库层 DEFAULT 'active'）
    category_ids = [category_id] if category_id else []

    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO courses (
                id, teacher_id, title, subject, city, region,
                price, price_unit, source_url, source_platform, source,
                original_content, description, tags,
                category_id, category_ids,
                is_duplicate, duplicate_of, data_quality_score, data_quality_scored_at
            ) VALUES (
                gen_random_uuid(), %s, %s, %s, %s, %s,
                %s, %s, %s, %s, %s,
                %s, %s, %s,
                %s, %s,
                %s, %s, %s, NOW()
            )
            ON CONFLICT (source_url) DO UPDATE SET
                title = EXCLUDED.title,
                subject = EXCLUDED.subject,
                price = EXCLUDED.price,
                price_unit = EXCLUDED.price_unit,
                region = EXCLUDED.region,
                original_content = EXCLUDED.original_content,
                description = EXCLUDED.description,
                tags = EXCLUDED.tags,
                category_id = EXCLUDED.category_id,
                category_ids = EXCLUDED.category_ids,
                data_quality_score = EXCLUDED.data_quality_score,
                data_quality_scored_at = EXCLUDED.data_quality_scored_at,
                updated_at = NOW()
            """,
            (
                teacher_id,
                course_data.get('title'),
                course_data.get('subject'),
                '奥克兰',
                course_data.get('region', '中区'),
                course_data.get('price'),
                course_data.get('priceUnit', '小时'),
                course_data.get('sourceUrl'),
                course_data.get('sourcePlatform', 'skykiwi'),
                'skykiwi',
                course_data.get('originalContent'),
                course_data.get('description'),
                course_data.get('tags', []),
                category_id,
                category_ids,
                is_duplicate,
                duplicate_of,
                quality_score,
            )
        )


def import_courses(results):
    """批量导入课程到数据库（仅在 DATABASE_URL 存在时执行）

    返回: dict { imported, duplicates, failed }
    """
    conn = _get_connection()
    if not conn:
        sys.stderr.write("[db_import] DATABASE_URL 未设置，跳过数据库导入\n")
        return {'imported': 0, 'duplicates': 0, 'failed': 0}

    stats = {'imported': 0, 'duplicates': 0, 'failed': 0}

    try:
        # 加载分类映射缓存
        category_map = _load_category_map(conn)
        sys.stderr.write(f"[db_import] 加载 {len(category_map)} 个分类映射\n")

        for course in results:
            if not course or 'error' in course or not course.get('sourceUrl'):
                continue
            try:
                # 1. 查找/创建 profile
                teacher_id = find_or_create_profile(
                    conn,
                    wechat=course.get('contactWechat'),
                    phone=course.get('contactPhone'),
                )

                # 2. 分类映射 — 优先使用 LLM 分类结果（Phase 105, per D-08）
                llm_slug = course.get('llmCategorySlug')
                if llm_slug and llm_slug in category_map:
                    category_id = category_map.get(llm_slug)
                else:
                    category_id = _match_category_id(course.get('subject'), category_map)

                # 3. 排重检测（失败不阻塞，降级为不标记重复）
                is_dup = False
                dup_of = None
                try:
                    dup_of = _check_duplicate(
                        conn,
                        course.get('title', ''),
                        course.get('sourcePlatform', 'skykiwi'),
                        '奥克兰',
                        wechat=course.get('contactWechat'),
                        phone=course.get('contactPhone'),
                        subject=course.get('subject'),
                        source_url=course.get('sourceUrl'),
                    )
                    is_dup = dup_of is not None
                except Exception as e:
                    sys.stderr.write(f"[db_import] 排重跳过: {e}\n")

                if is_dup:
                    stats['duplicates'] += 1

                # 4. 质量评分
                course_enriched = {**course, 'categoryId': category_id}
                quality_score = calculate_quality_score(course_enriched)

                # 5. Upsert
                upsert_course(
                    conn,
                    teacher_id,
                    course,
                    category_id=category_id,
                    is_duplicate=is_dup,
                    duplicate_of=dup_of,
                    quality_score=quality_score,
                )
                stats['imported'] += 1

            except Exception as e:
                stats['failed'] += 1
                sys.stderr.write(f"[db_import] 导入失败 [{course.get('sourceUrl', '?')}]: {e}\n")
                # 回滚当前语句但不回滚整个事务
                conn.rollback()
                # 重新开始新事务，继续后续课程
                continue

        conn.commit()
        sys.stderr.write(f"[db_import] 导入完成: {stats['imported']} 导入, {stats['duplicates']} 重复, {stats['failed']} 失败\n")
    except Exception as e:
        conn.rollback()
        sys.stderr.write(f"[db_import] 导入异常（已回滚）: {e}\n")
    finally:
        conn.close()

    return stats
