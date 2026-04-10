-- ============================================
-- 生产环境数据库初始化
-- ============================================
-- 在 postgres 容器首次启动时自动执行
-- 创建应用所需的数据库

-- Keycloak 独立数据库（Keycloak 自动管理 schema）
CREATE DATABASE keycloak
  WITH OWNER = postgres
  ENCODING = 'UTF8'
  LC_COLLATE = 'en_US.utf8'
  LC_CTYPE = 'en_US.utf8'
  TEMPLATE = template0;
