#!/usr/bin/env python3
"""
backfill_translations.py - 历史课程英文回填脚本

为存量课程批量生成英文字段（title_en/subject_en/description_en 等）。
仅在 title_en IS NULL 时处理，确保幂等性。

Usage:
  python3 backfill_translations.py --dry-run --limit 10
  python3 backfill_translations.py --batch-size 20
  /app/crawler-venv/bin/python3 backfill_translations.py --limit 50
  /app/crawler-venv/bin/python3 backfill_translations.py --backup-first

特性：
- 幂等：仅处理 title_en IS NULL 的行，中断重跑无副作用
- 只 UPDATE 8 个 _en 列，不碰中文列
"""
import argparse
import json
import os
import subprocess
import sys

from llm_translate import translate_courses

DB_HOST = os.getenv('POSTGRES_HOST', 'noda-infra-postgres-prod')
DB_PORT = os.getenv('POSTGRES_PORT', '5432')
DB_NAME = os.getenv('POSTGRES_DB', 'noda_prod')
DB_USER = os.getenv('POSTGRES_USER', 'postgres')
DB_PASSWORD = os.getenv('POSTGRES_PASSWORD', 'postgres_password_change_me')

# DB 中文列 → JSON 键（与 llm_translate TRANSLATABLE_FIELDS 对齐）
DB_TO_JSON = {
    'title': 'title',
    'subject': 'subject',
    'grade_level': 'gradeLevel',
    'description': 'description',
    'teacher_qualifications': 'teacherInfo',
    'price_note': 'priceNote',
    'address': 'address',
    'schedule_info': 'scheduleInfo',
}
# JSON En 键 → DB _en 列
JSON_EN_TO_DB = {
    'titleEn': 'title_en',
    'subjectEn': 'subject_en',
    'gradeLevelEn': 'grade_level_en',
    'descriptionEn': 'description_en',
    'teacherInfoEn': 'teacher_qualifications_en',
    'priceNoteEn': 'price_note_en',
    'addressEn': 'address_en',
    'scheduleInfoEn': 'schedule_info_en',
}
# JSON En 键 → 中文源 JSON 键（update 兜底拷源值用：en 列名去 _en 后缀反查 DB_TO_JSON）
EN_KEY_TO_SOURCE = {
    json_en: DB_TO_JSON[db_en[:-3]] for json_en, db_en in JSON_EN_TO_DB.items()
}

# grade_level 枚举脏值静态映射（LLM 对短枚举不翻/不返回键，非 ASCII 源不可拷贝，
# 不映射则这些课堵死 created_at 队头，后续字段永远轮不到）
GRADE_LEVEL_EN_MAP = {
    '不限': 'All ages',
    'Year7-13': 'Year 7-13',
    '中学（IGCSE/AS/A Level/NCEA）': 'Secondary (IGCSE/AS/A Level/NCEA)',
    '儿童/成人全年龄段': 'All ages (children & adults)',
    '儿童、青少年、成人': 'Children, teens & adults',
    '小学三四年级': 'Primary Year 3-4',
    '小学至高中': 'Primary to secondary',
    '成人': 'Adults',
    '成人专业发展': 'Adults (professional development)',
    '成人/无年龄限制': 'Adults / all ages',
    '6-12岁': 'Age 6-12',
    '空': 'N/A',
}


def psql_command(sql):
    """执行 psql 命令（仿 import-courses.py；加 -A 去表格式对齐，因 json_agg 单行输出解析需要）"""
    cmd = [
        'psql', f'-h{DB_HOST}', f'-p{DB_PORT}', f'-U{DB_USER}', f'-d{DB_NAME}',
        '-t', '-A', '-c', sql,
    ]
    env = os.environ.copy()
    env['PGPASSWORD'] = DB_PASSWORD
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def psql_escape(value):
    """转义 SQL 字符串（None → NULL）"""
    if value is None:
        return 'NULL'
    escaped = str(value).replace("'", "''")
    return f"'{escaped}'"


def fetch_batch(limit):
    """取一批有未翻译字段的课程（json_agg 输出防换行断裂）。

    命中条件：任一可翻译字段 en 列缺失且中文源非空 ——
    覆盖部分翻译课（如 title_en 已有但 description_en 缺）。
    """
    # 列名必须别名成 json 键（camelCase）：json_agg 保留 SELECT 别名，
    # 不映射则 gradeLevel/priceNote 等四字段恒 None（snake_case 取不到），
    # update 永不写对应 _en 列 → fetch 永远命中 → 死循环。
    cols = ', '.join(
        [f"id AS \"id\""] + [f"{db} AS \"{json_key}\"" for db, json_key in DB_TO_JSON.items()]
    )
    # 空串源不算「有内容」：爬虫导入的 grade_level/price_note 多为空串，
    # 若不排除，fetch 恒命中但无物可翻、永不写库 → 死循环。
    missing_conditions = [
        f"{col}_en IS NULL AND {col} IS NOT NULL AND {col} <> ''" for col in DB_TO_JSON
    ]
    sql = f"""
    SELECT COALESCE(json_agg(t), '[]'::json) FROM (
        SELECT {cols} FROM courses
        WHERE status = 'active' AND ({' OR '.join(missing_conditions)})
        ORDER BY created_at
        LIMIT {int(limit)}
    ) t;
    """
    result = psql_command(sql)
    if result.returncode != 0:
        raise RuntimeError(f"查询失败: {result.stderr}")
    return json.loads(result.stdout.strip() or '[]')


def update_course(course):
    """写回一条课程的 _en 列（COALESCE 只填空，不覆盖已有翻译）。

    LLM 省略键的字段（tool schema 仅 required index+titleEn，对「无需翻译」
    的字段常不返回键）兜底拷贝源值——否则 fetch 命中字段永不写入，游标停滞
    死循环。fetch 命中条件保证源非空；省略键语义 = 源已是英文/数字，拷贝安全。
    批整体失败（_translate_failed）跳过：中文源此时拷入会污染 en 列。
    """
    if course.get('_translate_failed'):
        return False
    sets = []
    for json_key, db_col in JSON_EN_TO_DB.items():
        value = course.get(json_key)
        if not value:
            src = course.get(EN_KEY_TO_SOURCE.get(json_key))
            # 兜底仅限：grade_level 枚举静态映射，或全 ASCII 源（已是英文/数字）。
            # 含非 ASCII（中文）且无映射不拷——LLM 键缺失的失败场景，拷入即污染 en 列。
            if isinstance(src, str) and src.strip():
                if json_key == 'gradeLevelEn':
                    value = GRADE_LEVEL_EN_MAP.get(src.strip())
                elif src.isascii():
                    value = src
        if value:
            sets.append(f"{db_col} = COALESCE({db_col}, {psql_escape(value)})")
    if not sets:
        return False
    sql = f"UPDATE courses SET {', '.join(sets)}, updated_at = NOW() WHERE id = {psql_escape(course['id'])};"
    result = psql_command(sql)
    return result.returncode == 0


def backup_courses():
    """回填前快照 courses 表（安全垫）"""
    stamp = __import__('time').strftime('%Y%m%d_%H%M%S')
    path = f"/app/crawler/logs/courses_backup_{stamp}.sql"
    env = os.environ.copy()
    env['PGPASSWORD'] = DB_PASSWORD
    result = subprocess.run(
        ['pg_dump', f'-h{DB_HOST}', f'-p{DB_PORT}', f'-U{DB_USER}',
         f'-d{DB_NAME}', '-t', 'courses', '-f', path],
        capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"备份失败: {result.stderr}")
    print(f"📦 已备份 courses 表: {path}")


def main(argv=None):
    parser = argparse.ArgumentParser(description='历史课程英文回填')
    parser.add_argument('--dry-run', action='store_true', help='只翻译不写库')
    parser.add_argument('--limit', type=int, default=0, help='总条数上限（0=不限制）')
    parser.add_argument('--batch-size', type=int, default=10, help='每批条数')
    parser.add_argument('--backup-first', action='store_true', help='先 pg_dump courses 表')
    args = parser.parse_args(argv)

    # 防死循环：dry-run 不写库，游标（任一 _en 列缺失）无法推进，必须带条数上限
    if args.dry_run and args.limit <= 0:
        parser.error('--dry-run 必须配合 --limit N 使用（不写库无法推进游标）')

    if args.backup_first:
        backup_courses()

    total = 0
    while True:
        remaining = args.limit - total if args.limit else args.batch_size
        if args.limit and remaining <= 0:
            break
        rows = fetch_batch(min(args.batch_size, remaining))
        if not rows:
            break

        # DB 键 → JSON 键后送翻译
        for row in rows:
            for db_col, json_key in DB_TO_JSON.items():
                row[json_key] = row.pop(db_col, None)

        translated = translate_courses(rows, batch_size=args.batch_size)

        # 无进展守卫：整批零翻译成功（LLM 持续故障）时中止，
        # 否则本轮未写库 → 下轮 fetch 重取同一批 → 死循环烧 API。
        # 幂等保证中断重跑从断点继续。
        # 判定不能只看 titleEn——title 已是英文的课 LLM 按规则回空串
        # （合并时拷源值），其价值在其他字段；任一 *En 字段有值即算进展。
        def has_any_translation(c):
            return any(c.get(k) for k in JSON_EN_TO_DB)

        if not any(has_any_translation(c) for c in translated):
            print('⚠️ 整批翻译零成功（LLM 故障？），中止以防死循环。重跑将从断点继续。')
            break

        if args.dry_run:
            for c in translated:
                mark = '✓' if has_any_translation(c) else '✗'
                print(f"{mark} {c['id'][:8]} {c.get('title', '')[:30]} → {c.get('titleEn') or has_any_translation(c) and '(仅其他字段)' or '(失败)'}")
        else:
            for c in translated:
                if update_course(c):
                    print(f"✅ {c['id'][:8]} {c.get('title', '')[:30]}")
                else:
                    print(f"❌ {c['id'][:8]} 更新失败")

        total += len(rows)
        print(f"--- 累计 {total} 条 ---")

    print(f"完成: {'dry-run ' if args.dry_run else ''}共处理 {total} 条")


if __name__ == '__main__':
    main()
