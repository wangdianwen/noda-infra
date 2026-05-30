#!/usr/bin/env python3
"""
课程入库脚本
读取爬虫 JSON 文件并直接导入 PostgreSQL 数据库
"""
import json
import os
import re
import sys
import subprocess
from datetime import datetime
from pathlib import Path


def clean_decorative_symbols(text):
    """移除装饰符号（█★●◆⭐🎨等），保留中文/英文/数字/基本标点"""
    if not text:
        return text
    text = re.sub(r'[─-╿▀-▟■-◿☀-⛿✀-➿⭐⭕⬛⬜®©™　]+', ' ', text)
    text = re.sub(r'[\U0001F300-\U0001F9FF\U00002600-\U000027BF\U0000FE00-\U0000FE0F\U0000200D\U00002764\U00002B50]+', ' ', text)
    text = re.sub(r'\s{2,}', ' ', text)
    return text.strip()

# 数据库配置
DB_HOST = os.getenv('POSTGRES_HOST', 'noda-infra-postgres-prod')
DB_PORT = os.getenv('POSTGRES_PORT', '5432')
DB_NAME = os.getenv('POSTGRES_DB', 'noda_prod')
DB_USER = os.getenv('POSTGRES_USER', 'postgres')
DB_PASSWORD = os.getenv('POSTGRES_PASSWORD', 'postgres_password_change_me')

# 爬虫日志目录
CRAWLER_LOGS_DIR = Path('/app/crawler/logs')

# subject → categorySlug 映射表
SUBJECT_TO_CATEGORY = {
    # 驾照培训
    '驾驶培训': 'skills-driving',
    '驾照培训': 'skills-driving',
    '大车驾驶培训': 'skills-driving',
    '大车培训': 'skills-driving',
    '叉车培训': 'skills-driving',
    '卡车驾照': 'skills-driving',
    # 学科辅导
    '英语': 'academic-english',
    '雅思': 'academic-english',
    '语言': 'academic-english',
    '数学': 'academic-math',
    '物理': 'academic-science',
    '商科': 'academic-business',
    '会计': 'academic-business',
    '全科辅导': 'academic-english',
    # 音乐
    '钢琴': 'music-piano',
    '声乐': 'music-vocal',
    '古筝': 'music-instruments',
    '琵琶': 'music-instruments',
    # 舞蹈
    '舞蹈': 'dance-dance',
    # 体育
    '健身': 'sports-fitness',
    '高尔夫': 'sports-fitness',
    # 技能
    '咖啡制作': 'skills-vocational',
    '咖啡技能': 'skills-vocational',
    '自媒体营销': 'skills-vocational',
    '创意设计编程': 'skills-vocational',
    '信息技术': 'skills-vocational',
    '个人成长与习惯养成': 'skills-life-skills',
}

def resolve_category_id(category_slug: str, subject: str) -> str:
    """解析 categorySlug 到数据库 category_id

    优先级：
    1. 使用 categorySlug 直接查询
    2. 使用 subject → categorySlug 映射
    3. 返回 None（未分类）
    """
    # 尝试直接查询 categorySlug
    if category_slug:
        check_sql = f"SELECT id FROM categories WHERE slug = '{category_slug}' LIMIT 1;"
        result = psql_command(check_sql)
        if result.stdout.strip():
            lines = result.stdout.strip().split('\n')
            for line in lines:
                if '-' in line and len(line) == 36:
                    return line.strip()

    # 尝试 subject 映射
    if subject in SUBJECT_TO_CATEGORY:
        mapped_slug = SUBJECT_TO_CATEGORY[subject]
        check_sql = f"SELECT id FROM categories WHERE slug = '{mapped_slug}' LIMIT 1;"
        result = psql_command(check_sql)
        if result.stdout.strip():
            lines = result.stdout.strip().split('\n')
            for line in lines:
                if '-' in line and len(line) == 36:
                    return line.strip()

    # 未找到匹配
    return None

def psql_command(sql):
    """执行 psql 命令"""
    cmd = [
        'psql',
        f'-h{DB_HOST}',
        f'-p{DB_PORT}',
        f'-U{DB_USER}',
        f'-d{DB_NAME}',
        '-t',  # 禁用表头和格式化，只输出数据行
        '-c', sql
    ]
    env = os.environ.copy()
    env['PGPASSWORD'] = DB_PASSWORD
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return result

def find_or_create_teacher(contact_wechat, contact_phone, teacher_info):
    """查找或创建教师 profile"""
    # 尝试通过微信号查找
    if contact_wechat:
        check_sql = f"SELECT id FROM profiles WHERE wechat = '{contact_wechat}' LIMIT 1;"
        result = psql_command(check_sql)
        if result.stdout.strip():
            # 提取 UUID
            lines = result.stdout.strip().split('\n')
            for line in lines:
                if '-' in line:  # UUID 格式
                    return line.strip()

    # 尝试通过手机号查找
    if contact_phone:
        # 清理手机号格式
        clean_phone = contact_phone.replace(' ', '').replace('-', '')
        check_sql = f"SELECT id FROM profiles WHERE phone LIKE '%{clean_phone}%' LIMIT 1;"
        result = psql_command(check_sql)
        if result.stdout.strip():
            lines = result.stdout.strip().split('\n')
            for line in lines:
                if '-' in line:
                    return line.strip()

    # 创建新的教师 profile（不使用 teacher_info 作为名字，它应该是 teacher_qualifications）
    teacher_name = '匿名教师'
    create_sql = f"""
    INSERT INTO profiles (name, wechat, phone, source, source_platform, created_at, updated_at)
    VALUES (
        {psql_escape(teacher_name)},
        {psql_escape(contact_wechat)},
        {psql_escape(contact_phone)},
        'crawler',
        'skykiwi',
        NOW(),
        NOW()
    )
    RETURNING id;
    """

    result = psql_command(create_sql)
    if result.returncode == 0 and result.stdout.strip():
        lines = result.stdout.strip().split('\n')
        for line in lines:
            if '-' in line and len(line) == 36:  # UUID
                return line.strip()

    # 如果创建失败，生成一个临时 UUID
    import uuid
    return str(uuid.uuid4())

def import_course(course_data):
    """导入单条课程数据（更新已存在或插入新课程）"""
    # 提取字段（清洗装饰符号）
    title = clean_decorative_symbols(course_data.get('title', ''))
    price_str = course_data.get('price')
    price_note = course_data.get('priceNote', '')
    contact_wechat = course_data.get('contactWechat', '')
    contact_phone = course_data.get('contactPhone', '')
    subject = clean_decorative_symbols(course_data.get('subject', ''))
    region = course_data.get('region', '奥克兰')
    grade_level = course_data.get('gradeLevel', '')
    teacher_info = course_data.get('teacherInfo', '')
    location_type = course_data.get('locationType', '线下')
    trial_lesson = course_data.get('trialLesson', False)
    description = course_data.get('description', '')
    source_url = course_data.get('sourceUrl', '')
    confidence = course_data.get('confidence', 0)
    source_platform = course_data.get('sourcePlatform', 'skykiwi')
    original_content = course_data.get('originalContent', '')
    tags = course_data.get('tags', [])

    # 检查是否已存在
    check_sql = f"SELECT id FROM courses WHERE source_url = '{source_url}' LIMIT 1;"
    result = psql_command(check_sql)

    existing_id = None
    if result.stdout.strip():
        lines = result.stdout.strip().split('\n')
        for line in lines:
            if '-' in line and len(line) == 36:  # UUID
                existing_id = line.strip()
                break

    # 查找或创建教师
    teacher_id = find_or_create_teacher(contact_wechat, contact_phone, teacher_info)

    # 解析分类
    category_slug = course_data.get('categorySlug', '')
    resolved_category_id = resolve_category_id(category_slug, subject)

    # 处理价格
    price = None
    if price_str and price_str not in ['面议', '待定', '']:
        try:
            # 提取数字
            import re
            price_match = re.search(r'[\d,]+', str(price_str).replace(',', ''))
            if price_match:
                price = int(price_match.group())
        except:
            pass

    # 处理标签数组
    tags_array = '{' + ','.join([f'"{tag}"' for tag in tags]) + '}' if tags else '{}'

    # 更新或插入
    if existing_id:
        # 更新已存在的课程
        category_id_value = f"'{resolved_category_id}'" if resolved_category_id else 'NULL'
        category_ids_value = f"ARRAY['{resolved_category_id}']" if resolved_category_id else 'ARRAY[]::text[]'
        update_sql = f"""
        UPDATE courses SET
            teacher_id = '{teacher_id}',
            title = {psql_escape(title)},
            subject = {psql_escape(subject)},
            grade_level = {psql_escape(grade_level)},
            region = {psql_escape(region)},
            location_type = {psql_escape(location_type)},
            price = {price if price else 'NULL'},
            price_note = {psql_escape(price_note)},
            trial_lesson = {trial_lesson},
            description = {psql_escape(description)},
            teacher_qualifications = {psql_escape(teacher_info)},
            category_id = {category_id_value},
            category_ids = {category_ids_value},
            source_platform = {psql_escape(source_platform)},
            original_content = {psql_escape(original_content[:1000])},
            tags = '{tags_array}'::text[],
            source = 'crawler',
            data_quality_score = {int(confidence * 100)},
            updated_at = NOW()
        WHERE id = '{existing_id}'
        """

        result = psql_command(update_sql)

        if result.returncode == 0:
            print(f"  🔄 更新: {title}")
            return 'update'
        else:
            print(f"  ❌ 更新失败: {title} - {result.stderr}")
            return 'error'
    else:
        # 插入新课程
        category_id_value = f"'{resolved_category_id}'" if resolved_category_id else 'NULL'
        category_ids_value = f"ARRAY['{resolved_category_id}']::text[]" if resolved_category_id else "ARRAY[]::text[]"
        insert_sql = f"""
        INSERT INTO courses (
            teacher_id, title, subject, grade_level, region, location_type,
            price, price_unit, price_note, trial_lesson, description,
            teacher_qualifications, category_id, category_ids,
            source_url, source_platform, original_content, tags,
            source, data_quality_score, created_at, updated_at
        ) VALUES (
            '{teacher_id}',
            {psql_escape(title)},
            {psql_escape(subject)},
            {psql_escape(grade_level)},
            {psql_escape(region)},
            {psql_escape(location_type)},
            {price if price else 'NULL'},
            '小时',
            {psql_escape(price_note)},
            {trial_lesson},
            {psql_escape(description)},
            {psql_escape(teacher_info)},
            {category_id_value},
            {category_ids_value},
            {psql_escape(source_url)},
            {psql_escape(source_platform)},
            {psql_escape(original_content[:1000])},
            '{tags_array}'::text[],
            'crawler',
            {int(confidence * 100)},
            NOW(),
            NOW()
        )
        """

        result = psql_command(insert_sql)

        if result.returncode == 0:
            print(f"  ✅ 新增: {title}")
            return 'insert'
        else:
            print(f"  ❌ 插入失败: {title} - {result.stderr}")
            return 'error'

def psql_escape(value):
    """转义 SQL 字符串"""
    if value is None or value == 'NULL':
        return 'NULL'
    # 转义单引号
    escaped = str(value).replace("'", "''")
    return f"'{escaped}'"

def read_crawler_json():
    """读取爬虫输出的 JSON 文件"""
    from datetime import date

    courses = []

    # 1. 优先读取最新的 extract_log（LLM 提取后的完整数据）
    extract_logs = sorted(CRAWLER_LOGS_DIR.glob('extract_log_*.json'), reverse=True)
    if extract_logs:
        latest_extract = extract_logs[0]
        print(f"📄 读取提取日志: {latest_extract}")
        try:
            with open(latest_extract, 'r', encoding='utf-8') as f:
                data = json.load(f)
                if isinstance(data, list):
                    courses.extend(data)
                    print(f"  ✓ 提取日志: {len(data)} 条")
        except Exception as e:
            print(f"  ⚠️ 提取日志读取失败: {e}")

    # 2. 回退到读取 crawl_output_*.json（stdout 输出）
    if not courses:
        today = date.today().strftime('%Y%m%d')
        for board in ['hobby', 'tutoring']:
            output_file = CRAWLER_LOGS_DIR / f'crawl_output_{board}_{today}.json'
            if output_file.exists():
                print(f"📄 读取爬虫输出: {output_file}")
                try:
                    with open(output_file, 'r', encoding='utf-8') as f:
                        data = json.load(f)
                        if isinstance(data, list):
                            courses.extend(data)
                            print(f"  ✓ 爬虫输出: {len(data)} 条")
                except Exception as e:
                    print(f"  ⚠️ 爬虫输出读取失败: {e}")

    if not courses:
        print("❌ 未找到任何课程数据（既无 extract_log 也无 crawl_output）")

    return courses

def main():
    print("=" * 60)
    print("课程入库脚本")
    print(f"时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    # 读取爬虫数据
    courses = read_crawler_json()

    if not courses:
        print("❌ 没有需要导入的课程数据")
        return

    print(f"📊 找到 {len(courses)} 条课程数据")

    # 导入统计
    stats = {'insert': 0, 'skip': 0, 'error': 0}

    # 逐条导入
    for course in courses:
        result = import_course(course)
        stats[result] = stats.get(result, 0) + 1

    # 输出统计
    print("=" * 60)
    print("✅ 导入完成")
    print(f"  新增: {stats.get('insert', 0)} 条")
    print(f"  更新: {stats.get('update', 0)} 条")
    print(f"  失败: {stats.get('error', 0)} 条")
    print("=" * 60)

if __name__ == '__main__':
    main()
