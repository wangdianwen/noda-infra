#!/usr/bin/env python3
"""
回填 teacher_qualifications 字段
从 extract_log JSON 文件读取 teacherInfo，更新到数据库已导入课程的 teacher_qualifications
"""
import json
import os
import subprocess
from pathlib import Path

DB_HOST = os.getenv('POSTGRES_HOST', 'noda-infra-postgres-prod')
DB_PORT = os.getenv('POSTGRES_PORT', '5432')
DB_NAME = os.getenv('POSTGRES_DB', 'noda_prod')
DB_USER = os.getenv('POSTGRES_USER', 'postgres')
DB_PASSWORD = os.getenv('POSTGRES_PASSWORD', 'postgres_password_change_me')

CRAWLER_LOGS_DIR = Path('/app/crawler/logs')


def psql_command(sql):
    cmd = [
        'psql',
        f'-h{DB_HOST}', f'-p{DB_PORT}', f'-U{DB_USER}', f'-d{DB_NAME}',
        '-t', '-c', sql
    ]
    env = os.environ.copy()
    env['PGPASSWORD'] = DB_PASSWORD
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def psql_escape(value):
    if value is None or value == 'NULL':
        return 'NULL'
    escaped = str(value).replace("'", "''")
    return f"'{escaped}'"


def main():
    # 读取所有 extract_log 文件
    extract_logs = sorted(CRAWLER_LOGS_DIR.glob('extract_log_*.json'), reverse=True)
    if not extract_logs:
        print("未找到 extract_log 文件")
        return

    all_courses = []
    for log_file in extract_logs:
        with open(log_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
            if isinstance(data, list):
                all_courses.extend(data)

    # 按 sourceUrl 去重（保留最新的）
    seen = {}
    for c in all_courses:
        url = c.get('sourceUrl', '')
        if url:
            seen[url] = c
    courses = list(seen.values())
    print(f"读取 {len(courses)} 条课程（来自 {len(extract_logs)} 个文件）")

    updated = 0
    skipped = 0
    errors = 0

    for c in courses:
        source_url = c.get('sourceUrl', '')
        teacher_info = c.get('teacherInfo', '').strip()
        if not source_url or not teacher_info:
            skipped += 1
            continue

        sql = f"""UPDATE courses
                  SET teacher_qualifications = {psql_escape(teacher_info)},
                      updated_at = NOW()
                  WHERE source_url = {psql_escape(source_url)}
                    AND (teacher_qualifications IS NULL OR teacher_qualifications = '')"""
        result = psql_command(sql)
        if result.returncode == 0:
            # psql -t 会输出影响的行数
            rows = result.stdout.strip()
            if rows:
                updated += 1
                print(f"  更新: {c.get('title', '')[:40]}")
            else:
                skipped += 1
        else:
            errors += 1
            print(f"  错误: {c.get('title', '')[:40]} - {result.stderr[:80]}")

    print(f"\n完成: 更新 {updated}, 跳过 {skipped}, 错误 {errors}")


if __name__ == '__main__':
    main()
