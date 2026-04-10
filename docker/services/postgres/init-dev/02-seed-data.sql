-- ============================================
-- 开发环境种子数据
-- ============================================
-- 仅为开发/测试环境提供示例数据
-- 生产环境永远不执行此脚本
-- 基于 noda-apps Prisma schema 生成

\c noda_dev;

-- UUID 扩展（Prisma 需要）
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- 注意：表结构由 Prisma migration 自动创建
-- 此脚本仅在 migration 执行后插入种子数据
-- 如果表不存在则自动跳过
-- ============================================

DO $$
BEGIN
  -- 插入测试数据源
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'sources') THEN
    INSERT INTO sources (code, name, slug, type, category, icon, color, is_active, total_courses, created_at, updated_at) VALUES
      ('manual', '手动录入', 'manual', 'direct', '平台', 'edit', '#6b7280', true, 0, NOW(), NOW()),
      ('test_source', '测试数据源', 'test-source', 'api', '平台', 'bug', '#ef4444', true, 0, NOW(), NOW())
    ON CONFLICT (code) DO NOTHING;
  END IF;

  -- 插入测试分类（一级分类）
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'categories') THEN
    INSERT INTO categories (id, name, name_en, slug, level, parent_id) VALUES
      ('a0000000-0000-0000-0000-000000000001', '数学', 'Mathematics', 'math', 1, NULL),
      ('a0000000-0000-0000-0000-000000000002', '英语', 'English', 'english', 1, NULL),
      ('a0000000-0000-0000-0000-000000000003', '美术', 'Art', 'art', 1, NULL)
    ON CONFLICT (id) DO NOTHING;
  END IF;

  -- 插入测试教师
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'profiles') THEN
    INSERT INTO profiles (id, name, wechat, phone, email, source, created_at, updated_at) VALUES
      ('b0000000-0000-0000-0000-000000000001', '张老师', 'zhang_teacher', '0210000001', 'zhang@test.com', 'user', NOW(), NOW()),
      ('b0000000-0000-0000-0000-000000000002', '李老师', 'li_teacher', '0210000002', 'li@test.com', 'user', NOW(), NOW())
    ON CONFLICT (id) DO NOTHING;
  END IF;

  -- 插入测试课程
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'courses') THEN
    INSERT INTO courses (id, teacher_id, title, grade_level, city, region, location_type, price, price_unit, category_id, source, is_duplicate, data_quality_score, created_at, updated_at) VALUES
      ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', '高中数学强化班', '高中', '奥克兰', '中区', '线下', 60, '小时', 'a0000000-0000-0000-0000-000000000001', 'user', false, 80, NOW(), NOW()),
      ('c0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000002', '雅思口语精品课', '成人', '奥克兰', '北岸', '线上', 80, '小时', 'a0000000-0000-0000-0000-000000000002', 'user', false, 90, NOW(), NOW()),
      ('c0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000001', '儿童创意美术', '小学', '奥克兰', '东区', '线下', 45, '小时', 'a0000000-0000-0000-0000-000000000003', 'user', false, 70, NOW(), NOW())
    ON CONFLICT (id) DO NOTHING;
  END IF;

  RAISE NOTICE '种子数据插入完成';
END
$$;

\c keycloak_dev;

-- Keycloak 开发数据库由 Keycloak 自动初始化 schema

\c findclass_dev;

-- findclass_dev 预留空库
