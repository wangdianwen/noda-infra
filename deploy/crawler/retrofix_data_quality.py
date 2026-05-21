#!/usr/bin/env python3
"""
retrofix_data_quality.py - 数据质量回溯修复脚本

对数据库中已有课程数据回溯执行清洗和质量评分重算。
脚本必须幂等、可重复运行，支持 dry-run 预览。

执行顺序（per D-13）: 清洗先行 -> 质量评分 -> 排重

阶段说明:
  - clean: 论坛元数据正则清洗（6 种 Discuz 模式）
  - score: 质量评分重算（复用 db_import.calculate_quality_score）
  - dedup-tid: tid 精确排重（Plan 02 实现）
  - dedup-content: 联系方式+内容排重（Plan 02 实现）

使用方式:
  DATABASE_URL=postgresql://... python3 retrofix_data_quality.py --dry-run
  DATABASE_URL=postgresql://... python3 retrofix_data_quality.py --phase clean
  DATABASE_URL=postgresql://... python3 retrofix_data_quality.py --phase all
"""

import sys
import os
import re
import argparse
from datetime import datetime, timezone

from db_import import calculate_quality_score, _get_connection


# ============================================================
# tid 提取（复制自 db_import.py L317-327，文件名含连字符不适合 importlib）
# ============================================================


def _extract_tid(url):
    """从 skykiwi URL 提取帖子 tid

    支持格式: tid=123456 和 thread-123456
    返回: str (tid) 或 None
    """
    if not url:
        return None
    m = re.search(r'tid=(\d+)', url)
    if m:
        return m.group(1)
    m = re.search(r'thread-(\d+)', url)
    if m:
        return m.group(1)
    return None


# ============================================================
# 论坛元数据正则清洗（复制自 crawl-skykiwi.py L370-393）
# 6 种 Discuz 论坛元数据模式
# ============================================================


def clean_forum_metadata(text):
    """清理论坛元数据（编辑信息、附件信息、上传时间等）

    6 种 Discuz 模式:
      1. 编辑信息: "本帖最后由 XXX 于 YYYY-MM-DD HH:MM 编辑 "
      2. 上传时间: "YYYY-MM-DD HH:MM:SS 上传 "
      3. 下载附件: "下载附件 (XXX.XX KB) "
      4. 文件尺寸: "(XXX.XX KB|MB|bytes)"
      5. 签名来源: "--- 来自 XXX ---"
      6. 多余空行: 3+ 连续换行 -> 2 个
    """
    if not text:
        return text

    # 移除 Discuz 论坛编辑信息
    text = re.sub(r'本帖最后由\s*\S+\s*于\s*[\d\-]+\s*[\d:]+\s*编辑\s*', '', text)

    # 移除附件上传信息
    text = re.sub(r'\d{4}-\d{1,2}-\d{1,2}\s*\d{2}:\d{2}:\d{2}\s*上传\s*', '', text)

    # 移除下载附件信息
    text = re.sub(r'下载附件\s*\([^)]*\)\s*', '', text)

    # 移除图片/附件尺寸信息
    text = re.sub(r'\(\d+\.\d+\s*(?:KB|MB|bytes)\)', '', text)

    # 移除 Discuz 签名来源
    text = re.sub(r'---+\s*来自.*?---+', '', text)

    # 移除多余的空行（清洗后可能产生）
    text = re.sub(r'\n{3,}', '\n\n', text)

    return text.strip()


# ============================================================
# 字段映射: 数据库行 -> calculate_quality_score 输入格式
# ============================================================


def _row_to_score_input(course_row, profile_row):
    """映射数据库行（snake_case）到 calculate_quality_score 输入 dict（camelCase）

    Args:
        course_row: courses 表行（dict），含 JOIN 的 profile 联系方式
        profile_row: profiles 表行（dict）或 None，含 wechat/phone

    Returns:
        dict: calculate_quality_score 期望的 camelCase 格式
    """
    return {
        'title': course_row['title'],
        'subject': course_row['subject'],
        'categoryId': str(course_row['category_id']) if course_row['category_id'] else None,
        'region': course_row['region'],
        'price': course_row['price'],
        'priceUnit': course_row['price_unit'],
        'priceNote': course_row.get('price_note'),
        'description': course_row['description'],
        'contactWechat': profile_row['wechat'] if profile_row else None,
        'contactPhone': profile_row['phone'] if profile_row else None,
        'tags': course_row['tags'] or [],
        'originalContent': course_row['original_content'],
        'sourcePlatform': course_row['source_platform'],
        'source': course_row['source'],
        'crawlMetadata': {'crawledAt': str(course_row['created_at'])} if course_row.get('created_at') else {},
    }


# ============================================================
# 阶段 1: 清洗论坛元数据
# ============================================================


def clean_all_courses(conn, dry_run=False):
    """清洗所有非重复课程的论坛元数据

    对每条记录的 original_content 和 description 执行 clean_forum_metadata。
    只在清洗前后文本不同时执行 UPDATE（避免无效更新触发 updated_at 变更）。

    Args:
        conn: psycopg 数据库连接
        dry_run: True 时只输出预览不修改数据库

    Returns:
        dict: {'cleaned': N, 'skipped': N, 'preview': [...]}
    """
    result = {'cleaned': 0, 'skipped': 0, 'preview': []}

    with conn.cursor() as cur:
        # 只处理非重复课程（per D-12 幂等）
        cur.execute("""
            SELECT id, original_content, description
            FROM courses
            WHERE is_duplicate = false
        """)
        rows = cur.fetchall()

        for row in rows:
            course_id, orig_content, orig_desc = row[0], row[1], row[2]

            # 跳过两个字段都为 NULL 的记录
            if not orig_content and not orig_desc:
                result['skipped'] += 1
                continue

            cleaned_content = clean_forum_metadata(orig_content) if orig_content else orig_content
            cleaned_desc = clean_forum_metadata(orig_desc) if orig_desc else orig_desc

            # 只在文本实际变化时才 UPDATE（per RESEARCH Anti-Pattern 1）
            content_changed = (cleaned_content != orig_content) if orig_content else False
            desc_changed = (cleaned_desc != orig_desc) if orig_desc else False

            if not content_changed and not desc_changed:
                result['skipped'] += 1
                continue

            preview_entry = {
                'id': str(course_id),
                'content_changed': content_changed,
                'desc_changed': desc_changed,
            }
            result['preview'].append(preview_entry)

            if dry_run:
                result['cleaned'] += 1
                continue

            # 执行 UPDATE，只更新实际变化的记录
            cur.execute("""
                UPDATE courses
                SET original_content = %s,
                    description = %s
                WHERE id = %s
                  AND (original_content != %s OR description != %s)
            """, (cleaned_content, cleaned_desc, course_id, cleaned_content, cleaned_desc))
            result['cleaned'] += 1

        if not dry_run and result['cleaned'] > 0:
            conn.commit()

    return result


# ============================================================
# 阶段 2: 质量评分重算
# ============================================================


def score_all_courses(conn, dry_run=False):
    """对所有非重复课程重新计算质量评分

    JOIN profiles 表获取联系方式，映射到 calculate_quality_score 输入格式后评分。
    只更新分数实际变化的记录。

    Args:
        conn: psycopg 数据库连接
        dry_run: True 时只输出预览不修改数据库

    Returns:
        dict: {'scored': N, 'unchanged': N, 'preview': [...]}
    """
    result = {'scored': 0, 'unchanged': 0, 'preview': []}

    with conn.cursor() as cur:
        # JOIN profiles 获取联系方式（per D-04: 排重前先评分）
        # 只处理非重复课程（per D-12 幂等）
        cur.execute("""
            SELECT c.*, p.wechat, p.phone
            FROM courses c
            LEFT JOIN profiles p ON c.teacher_id = p.id
            WHERE c.is_duplicate = false
        """)
        rows = cur.fetchall()

        for row in rows:
            # 构造 course_row dict（兼容 dict 行和 tuple 行）
            if isinstance(row, dict):
                row_dict = row
            else:
                columns = [desc[0] for desc in cur.description]
                row_dict = dict(zip(columns, row))

            course_row = row_dict
            profile_row = {
                'wechat': row_dict.get('wechat'),
                'phone': row_dict.get('phone'),
            }

            score_input = _row_to_score_input(course_row, profile_row)
            new_score = calculate_quality_score(score_input)

            preview_entry = {
                'id': str(course_row['id']),
                'title': course_row['title'],
                'new_score': new_score,
            }
            result['preview'].append(preview_entry)

            if dry_run:
                result['scored'] += 1
                continue

            # 只更新分数实际变化的记录（per D-12 幂等）
            cur.execute("""
                UPDATE courses
                SET data_quality_score = %s,
                    data_quality_scored_at = NOW()
                WHERE id = %s
                  AND data_quality_score != %s
            """, (new_score, course_row['id'], new_score))

            if cur.rowcount > 0:
                result['scored'] += 1
            else:
                result['unchanged'] += 1

        if not dry_run and result['scored'] > 0:
            conn.commit()

    return result


# ============================================================
# 阶段 3: tid 精确排重（per D-01）
# ============================================================


def dedup_by_tid(conn, dry_run=False):
    """基于 tid 精确排重 — 相同 tid 只保留质量最高的一条

    per D-01: 复用 _extract_tid() 逻辑
    per D-05: 质量分数最高的保留
    per D-06: 同分时保留最早入库的（created_at 最小的）
    per D-12: 只处理 is_duplicate=false 的课程（幂等）

    Args:
        conn: psycopg 数据库连接
        dry_run: True 时只输出预览不修改数据库

    Returns:
        dict: {'groups_found': N, 'duplicates_marked': N, 'preview': [...]}
    """
    result = {'groups_found': 0, 'duplicates_marked': 0, 'preview': []}

    with conn.cursor() as cur:
        # 只处理非重复课程（per D-12 幂等）
        cur.execute("""
            SELECT c.id, c.source_url, c.data_quality_score, c.created_at
            FROM courses c
            WHERE c.is_duplicate = false
              AND c.source_url IS NOT NULL
        """)
        rows = cur.fetchall()

        # Python 端按 tid 分组
        tid_groups = {}
        for row in rows:
            if isinstance(row, dict):
                row_dict = row
            else:
                columns = [desc[0] for desc in cur.description]
                row_dict = dict(zip(columns, row))

            tid = _extract_tid(row_dict['source_url'])
            if tid:
                if tid not in tid_groups:
                    tid_groups[tid] = []
                tid_groups[tid].append(row_dict)

        # 处理每组 > 1 条的
        for tid, group in tid_groups.items():
            if len(group) <= 1:
                continue

            result['groups_found'] += 1

            # 按 data_quality_score 降序 + created_at 升序排序（per D-05 + D-06）
            group.sort(key=lambda r: (-r['data_quality_score'], r['created_at']))
            keeper = group[0]
            dup_ids = [r['id'] for r in group[1:]]

            preview_entry = {
                'tid': tid,
                'keeper_id': str(keeper['id']),
                'keeper_score': keeper['data_quality_score'],
                'dup_ids': [str(did) for did in dup_ids],
            }
            result['preview'].append(preview_entry)

            if dry_run:
                result['duplicates_marked'] += len(dup_ids)
                continue

            # 标记重复（每 50 条 commit 一次，per T-120-03）
            for i, dup_id in enumerate(dup_ids):
                cur.execute("""
                    UPDATE courses
                    SET is_duplicate = true,
                        duplicate_of = %s
                    WHERE id = %s
                      AND is_duplicate = false
                """, (str(keeper['id']), str(dup_id)))
                result['duplicates_marked'] += 1

                if (i + 1) % 50 == 0:
                    conn.commit()

            if not dry_run and dup_ids:
                conn.commit()

    return result


# ============================================================
# 阶段 4: 联系方式 + 内容排重（per D-02）
# ============================================================


def dedup_by_contact_content(conn, dry_run=False, similarity_threshold=0.7):
    """联系方式匹配 + 内容相似度补充排重

    per D-02: 联系方式匹配（手机号或微信）+ 内容相似度（pg_trgm similarity）
    per D-03: 在 tid 排重后执行（概率性）
    per D-05: 质量分数最高的保留
    per D-06: 同分时保留最早入库的
    per D-12: 只处理 is_duplicate=false 的课程

    Args:
        conn: psycopg 数据库连接
        dry_run: True 时只输出预览不修改数据库
        similarity_threshold: 标题相似度阈值（默认 0.7，低于 db_import 的 0.8）

    Returns:
        dict: {'pairs_compared': N, 'duplicates_marked': N, 'preview': [...]}
    """
    result = {'pairs_compared': 0, 'duplicates_marked': 0, 'preview': []}

    with conn.cursor() as cur:
        # 检查 pg_trgm 是否可用
        cur.execute("SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'")
        has_pgtrgm = cur.fetchone() is not None

        if not has_pgtrgm:
            print("[retrofix] 警告: pg_trgm 扩展不可用，跳过联系方式+内容排重", file=sys.stderr)
            return result

        # 查询同 teacher_id 下有多条非重复课程的教师
        cur.execute("""
            SELECT c.teacher_id, array_agg(c.id) as course_ids
            FROM courses c
            WHERE c.is_duplicate = false
            GROUP BY c.teacher_id
            HAVING COUNT(c.id) > 1
        """)
        teacher_rows = cur.fetchall()

        for teacher_row in teacher_rows:
            if isinstance(teacher_row, dict):
                teacher_id = teacher_row['teacher_id']
                course_ids = teacher_row['course_ids']
            else:
                teacher_id = teacher_row[0]
                course_ids = teacher_row[1]

            # 使用 pg_trgm 两两比较标题相似度
            cur.execute("""
                SELECT c1.id as id1, c2.id as id2,
                       similarity(c1.title, c2.title) as title_sim,
                       c1.data_quality_score as score1, c2.data_quality_score as score2,
                       c1.created_at as created1, c2.created_at as created2
                FROM courses c1, courses c2
                WHERE c1.id = ANY(%s) AND c2.id = ANY(%s)
                  AND c1.id < c2.id
                  AND c1.is_duplicate = false
                  AND c2.is_duplicate = false
                  AND similarity(c1.title, c2.title) > %s
            """, (course_ids, course_ids, similarity_threshold))

            similar_pairs = cur.fetchall()
            result['pairs_compared'] += len(similar_pairs)

            for pair in similar_pairs:
                if isinstance(pair, dict):
                    pair_dict = pair
                else:
                    columns = [desc[0] for desc in cur.description]
                    pair_dict = dict(zip(columns, pair))

                id1 = pair_dict['id1']
                id2 = pair_dict['id2']
                score1 = pair_dict['score1']
                score2 = pair_dict['score2']
                created1 = pair_dict['created1']
                created2 = pair_dict['created2']

                # 决定保留哪条: 质量分高的保留，同分时最早入库的保留（per D-05 + D-06）
                if score1 > score2:
                    keeper_id, dup_id = str(id1), str(id2)
                elif score2 > score1:
                    keeper_id, dup_id = str(id2), str(id1)
                else:
                    # 同分: created_at 早的保留
                    if created1 <= created2:
                        keeper_id, dup_id = str(id1), str(id2)
                    else:
                        keeper_id, dup_id = str(id2), str(id1)

                preview_entry = {
                    'keeper_id': keeper_id,
                    'dup_id': dup_id,
                    'title_sim': float(pair_dict['title_sim']),
                }
                result['preview'].append(preview_entry)

                if dry_run:
                    result['duplicates_marked'] += 1
                    continue

                # 标记重复
                cur.execute("""
                    UPDATE courses
                    SET is_duplicate = true,
                        duplicate_of = %s
                    WHERE id = %s
                      AND is_duplicate = false
                """, (keeper_id, dup_id))
                result['duplicates_marked'] += 1

            # 每个 teacher 的批次提交
            if not dry_run and similar_pairs:
                conn.commit()

    return result


# ============================================================
# CLI 入口
# ============================================================


def main():
    """回溯修复脚本 CLI 入口"""
    parser = argparse.ArgumentParser(
        description='数据质量回溯修复脚本（清洗 + 评分 + 排重）',
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='只输出预览不修改数据库',
    )
    parser.add_argument(
        '--phase',
        choices=['clean', 'score', 'dedup-tid', 'dedup-content', 'all'],
        default='all',
        help='选择执行阶段（默认 all）',
    )

    args = parser.parse_args()

    conn = _get_connection()
    if not conn:
        print("错误: 请设置 DATABASE_URL 环境变量", file=sys.stderr)
        sys.exit(1)

    try:
        phases = [
            ('clean', clean_all_courses),
            ('score', score_all_courses),
            ('dedup-tid', dedup_by_tid),
            ('dedup-content', dedup_by_contact_content),
        ] if args.phase == 'all' else [(args.phase, {
            'clean': clean_all_courses,
            'score': score_all_courses,
            'dedup-tid': dedup_by_tid,
            'dedup-content': dedup_by_contact_content,
        }[args.phase])]

        summary = {'clean': 0, 'score': 0, 'dedup-tid': 0, 'dedup-content': 0}

        for i, (phase_name, phase_fn) in enumerate(phases):
            print(f"\n[retrofix] Phase {i+1}/{len(phases)}: {phase_name} ...")

            if phase_name == 'clean':
                r = phase_fn(conn, dry_run=args.dry_run)
                summary['clean'] = r['cleaned']
                print(f"  清洗完成: {r['cleaned']} 条已清洗, {r['skipped']} 条跳过")
                if args.dry_run and r['preview']:
                    print(f"  预览: {len(r['preview'])} 条将被清洗")

            elif phase_name == 'score':
                r = phase_fn(conn, dry_run=args.dry_run)
                summary['score'] = r['scored']
                print(f"  评分完成: {r['scored']} 条已评分, {r.get('unchanged', 0)} 条无变化")
                if args.dry_run and r['preview']:
                    for p in r['preview'][:5]:
                        print(f"    {p['title']}: {p['new_score']} 分")
                    if len(r['preview']) > 5:
                        print(f"    ... 共 {len(r['preview'])} 条")

            elif phase_name == 'dedup-tid':
                r = phase_fn(conn, dry_run=args.dry_run)
                summary['dedup-tid'] = r['duplicates_marked']
                print(f"  tid 排重完成: {r['groups_found']} 组发现, {r['duplicates_marked']} 条重复标记")
                if r['preview']:
                    for p in r['preview'][:5]:
                        print(f"    tid={p['tid']}: 保留 {p['keeper_id']}, 标记 {len(p['dup_ids'])} 条重复")
                    if len(r['preview']) > 5:
                        print(f"    ... 共 {len(r['preview'])} 组")

            elif phase_name == 'dedup-content':
                r = phase_fn(conn, dry_run=args.dry_run)
                summary['dedup-content'] = r['duplicates_marked']
                print(f"  联系方式+内容排重完成: {r['pairs_compared']} 对比较, {r['duplicates_marked']} 条重复标记")

        if args.dry_run:
            print("\n[dry-run] 以上为预览，未修改数据库")
        else:
            print(f"\n[retrofix] 完成!")
            print(f"  清洗: {summary['clean']} 条记录被清理")
            print(f"  评分: {summary['score']} 条记录重新评分")
            print(f"  tid 排重: {summary['dedup-tid']} 条重复标记")
            print(f"  联系方式排重: {summary['dedup-content']} 条重复标记")

    finally:
        conn.close()


if __name__ == '__main__':
    main()
