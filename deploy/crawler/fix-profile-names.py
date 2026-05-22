#!/usr/bin/env python3
"""
修复 profiles 表中的错误名字

将截取 teacher_info 作为名字的 profile 重置为 "匿名教师"
判断标准：名字长度 > 20 且包含教师相关关键词
"""
import subprocess
import os

DB_HOST = os.getenv('POSTGRES_HOST', 'noda-infra-postgres-prod')
DB_PORT = os.getenv('POSTGRES_PORT', '5432')
DB_NAME = os.getenv('POSTGRES_DB', 'noda_prod')
DB_USER = os.getenv('POSTGRES_USER', 'postgres')
DB_PASSWORD = os.getenv('POSTGRES_PASSWORD', 'postgres_password_change_me')

# 教师相关关键词（出现在名字中说明是截取的 teacher_info）
TEACHER_KEYWORDS = [
    '教师', '教练', '老师', '资质', '经验', '专业', '认证',
    '毕业', '教学', '培训', '擅长', '具备', '拥有', '从事'
]

def psql_command(sql):
    cmd = [
        'psql',
        f'-h{DB_HOST}', f'-p{DB_PORT}', f'-U{DB_USER}', f'-d{DB_NAME}',
        '-t', '-c', sql
    ]
    env = os.environ.copy()
    env['PGPASSWORD'] = DB_PASSWORD
    return subprocess.run(cmd, capture_output=True, text=True, env=env)

def main():
    # 1. 查找需要修复的 profile
    check_sql = """
    SELECT id, name, wechat, phone
    FROM profiles
    WHERE source = 'crawler'
      AND LENGTH(name) > 20
      AND (
    """
    check_sql += " OR ".join([f"name LIKE '%{kw}%'" for kw in TEACHER_KEYWORDS])
    check_sql += "\n      )"
    check_sql += "\n    ORDER BY created_at DESC;"

    result = psql_command(check_sql)
    if result.returncode != 0:
        print(f"查询失败: {result.stderr}")
        return

    lines = result.stdout.strip().split('\n')
    if not lines or lines == ['']:
        print("没有需要修复的 profile")
        return

    # 解析结果
    profiles = []
    for line in lines:
        parts = line.split('|')
        if len(parts) >= 4:
            profiles.append({
                'id': parts[0].strip(),
                'name': parts[1].strip(),
                'wechat': parts[2].strip() if len(parts) > 2 else '',
                'phone': parts[3].strip() if len(parts) > 3 else '',
            })

    print(f"找到 {len(profiles)} 个需要修复的 profile:")
    for p in profiles[:5]:
        print(f"  - {p['name'][:40]}...")
    if len(profiles) > 5:
        print(f"  ... 还有 {len(profiles) - 5} 个")

    # 2. 确认后修复
    response = input("\n是否修复这些 profile？(yes/no): ")
    if response.lower() != 'yes':
        print("取消修复")
        return

    fixed = 0
    for p in profiles:
        update_sql = f"""
        UPDATE profiles
        SET name = '匿名教师', updated_at = NOW()
        WHERE id = '{p['id']}';
        """
        result = psql_command(update_sql)
        if result.returncode == 0:
            fixed += 1
            print(f"  修复: {p['name'][:40]}... -> 匿名教师")
        else:
            print(f"  错误: {p['id']} - {result.stderr}")

    print(f"\n完成: 修复 {fixed}/{len(profiles)} 个 profile")

if __name__ == '__main__':
    main()
