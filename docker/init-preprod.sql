-- ============================================
-- Preprod 数据库初始化（仅首次创建时执行）
-- ============================================
-- Drizzle 迁移 0000 需要 courses 表已存在（ALTER TABLE）
-- 全新数据库没有该表，因此在此预创建最小结构

-- uuid-ossp 扩展（迁移 0004 uuid_generate_v4() 依赖）
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- courses 表最小结构（让迁移 0000 ALTER TABLE 通过）
CREATE TABLE IF NOT EXISTS "courses" (
  "id" uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  "title" text,
  "description" text,
  "source" text,
  "category" text,
  "url" text,
  "created_at" timestamptz DEFAULT now(),
  "updated_at" timestamptz DEFAULT now()
);

-- ============================================
-- Keycloak 数据库
-- ============================================
-- 注意：docker-entrypoint 只对 POSTGRES_DB 指定的数据库执行 init SQL
-- 这里用 DO $$ 创建 keycloak 数据库（兼容 docker-entrypoint）
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak') THEN
    -- 在 DO 块中无法直接 CREATE DATABASE，用 dblink 或外部脚本
    -- 改为在 keycloak 启动前由 entrypoint 创建
    RAISE NOTICE 'keycloak database not found — will be created by pipeline';
  END IF;
END $$;
