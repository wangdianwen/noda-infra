-- ============================================
-- Noda Monorepo - PostgreSQL 初始化脚本（修订版）
-- ============================================
-- 架构：独立数据库方案
-- - keycloak_db: Keycloak 认证服务专用
-- - findclass_db: findclass 应用数据库
-- - noda_app_db: noda 主应用数据库（未来）
-- - site_a_db: 站点 A 数据库（未来）

-- ============================================
-- 创建应用数据库
-- ============================================

-- Keycloak 认证服务数据库（统一认证中心）
-- 注意：如果数据库已存在，先删除再创建
DROP DATABASE IF EXISTS keycloak_db;
CREATE DATABASE keycloak_db;

-- findclass 应用数据库（现有应用）
DROP DATABASE IF EXISTS findclass_db;
CREATE DATABASE findclass_db;

-- Noda 主应用数据库（未来）
-- CREATE DATABASE noda_app_db;

-- 站点 A 数据库（未来）
-- CREATE DATABASE site_a_db;

-- ============================================
-- 创建用户和密码
-- ============================================

-- Keycloak 用户（认证服务专用）
CREATE USER keycloak_user WITH PASSWORD 'keycloak_password_change_me';

-- findclass 应用用户
CREATE USER findclass_user WITH PASSWORD 'findclass_password_change_me';

-- Noda 主应用用户（未来）
-- CREATE USER noda_app_user WITH PASSWORD 'noda_app_password_change_me';

-- 站点 A 用户（未来）
-- CREATE USER site_a_user WITH PASSWORD 'site_a_password_change_me';

-- ============================================
-- 授予数据库权限
-- ============================================

-- Keycloak 数据库权限
GRANT ALL PRIVILEGES ON DATABASE keycloak_db TO keycloak_user;

-- findclass 数据库权限
GRANT ALL PRIVILEGES ON DATABASE findclass_db TO findclass_user;

-- Noda 主应用权限（未来）
-- GRANT ALL PRIVILEGES ON DATABASE noda_app_db TO noda_app_user;

-- 站点 A 权限（未来）
-- GRANT ALL PRIVILEGES ON DATABASE site_a_db TO site_a_user;

-- ============================================
-- 创建备份目录
-- ============================================
-- mkdir -p /var/lib/postgresql/backup
-- Note: SQL commands cannot execute shell commands directly

-- ============================================
-- 输出创建结果
-- ============================================
\echo '=========================================='
\echo 'PostgreSQL 初始化完成（独立数据库架构）'
\echo '=========================================='
\echo '数据库列表:'
\echo '  - keycloak_db (Keycloak 认证服务)'
\echo '  - findclass_db (findclass 应用)'
\echo '  - noda_app_db (Noda 主应用，未来)'
\echo '  - site_a_db (站点 A，未来)'
\echo '=========================================='
\echo '用户列表:'
\echo '  - keycloak_user (Keycloak 专用)'
\echo '  - findclass_user (findclass 应用)'
\echo '  - noda_app_user (主应用，未来)'
\echo '  - site_a_user (站点 A，未来)'
\echo '=========================================='
\echo '架构优势:'
\echo '  ✅ 职责清晰分离'
\echo '  ✅ 便于多应用扩展'
\echo '  ✅ 独立备份恢复'
\echo '  ✅ 便于微服务演进'
\echo '=========================================='
\echo '⚠️  重要提示:'
\echo '  1. 生产环境请修改默认密码'
\echo '  2. 备份目录: /var/lib/postgresql/backup'
\echo '  3. Keycloak 作为统一认证中心'
\echo '  4. 每个应用独立数据库'
\echo '=========================================='