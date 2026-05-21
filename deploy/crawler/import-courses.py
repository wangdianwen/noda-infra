#!/usr/bin/env python3
"""
课程入库脚本
读取爬虫 JSON 文件并直接导入 PostgreSQL 数据库
"""
import json
import os
import sys
import subprocess
from datetime import datetime
from pathlib import Path

# 数据库配置
DB_HOST = os.getenv('POSTGRES_HOST', 'noda-infra-postgres-prod')
DB_PORT = os.getenv('POSTGRES_PORT', '5432')
DB_NAME = os.getenv('POSTGRES_DB', 'noda_prod')
DB_USER = os.getenv('POSTGRES_USER', 'postgres')
DB_PASSWORD = os.getenv('POSTGRES_PASSWORD', 'postgres_password_change_me')

# 爬虫日志目录
CRAWLER_LOGS_DIR = Path('/app/crawler/logs')

def psql_command(sql):
    """执行 psql 命令"""
    cmd = [
        'psql',
        f'-h{DB_HOST}',
        f'-p{DB_PORT}',
        f'-U{DB_USER}',
        f'-d{DB_NAME}',
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

    # 创建新的教师 profile
    teacher_name = teacher_info[:50] if teacher_info else '爬虫导入教师'
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
    """导入单条课程数据"""
    # 提取字段
    title = course_data.get('title', '')
    price_str = course_data.get('price')
    price_note = course_data.get('priceNote', '')
    contact_wechat = course_data.get('contactWechat', '')
    contact_phone = course_data.get('contactPhone', '')
    subject = course_data.get('subject', '')
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

    if result.stdout.strip():
        print(f"  跳过（已存在）: {title}")
        return 'skip'

    # 查找或创建教师
    teacher_id = find_or_create_teacher(contact_wechat, contact_phone, teacher_info)

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

    # 插入新课程
    insert_sql = f"""
    INSERT INTO courses (
        teacher_id, title, subject, grade_level, region, location_type,
        price, price_unit, price_note, trial_lesson, description,
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
        {psql_escape(source_url)},
        {psql_escape(source_platform)},
        {psql_escape(original_content[:1000])},  -- 限制长度
        '{tags_array}'::text[],
        'crawler',
        {int(confidence * 100)},
        NOW(),
        NOW()
    )
    """

    result = psql_command(insert_sql)

    if result.returncode == 0:
        print(f"  ✅ 导入: {title}")
        return 'insert'
    else:
        print(f"  ❌ 失败: {title} - {result.stderr}")
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
    # 查找最新的批次日志文件
    batch_files = sorted(CRAWLER_LOGS_DIR.glob('batch_*.json'), reverse=True)

    if not batch_files:
        print("❌ 未找到爬虫批次日志文件")
        return []

    # 读取最新的批次日志
    latest_batch = batch_files[0]
    print(f"📄 读取批次日志: {latest_batch}")

    # 读取所有相关的 JSON 文件
    courses = []

    # 读取 extract_log
    extract_log = CRAWLER_LOGS_DIR / 'extract_log_2026-05-21.json'
    if extract_log.exists():
        with open(extract_log, 'r', encoding='utf-8') as f:
            data = json.load(f)
            if isinstance(data, list):
                courses.extend(data)

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
    print(f"  跳过: {stats.get('skip', 0)} 条")
    print(f"  失败: {stats.get('error', 0)} 条")
    print("=" * 60)

if __name__ == '__main__':
    main()
