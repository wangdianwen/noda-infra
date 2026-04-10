-- ============================================
-- 开发环境数据库初始化
-- ============================================
-- 仅在 postgres-dev 容器首次启动时执行
-- 基于 noda-apps 实际使用的数据库

-- 主开发数据库（findclass-ssr / Prisma 使用）
CREATE DATABASE noda_dev;

-- Keycloak 开发数据库（Keycloak 自动管理 schema）
CREATE DATABASE keycloak_dev;
