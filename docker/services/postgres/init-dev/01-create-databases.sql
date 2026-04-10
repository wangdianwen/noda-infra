-- ============================================
-- 开发环境数据库初始化
-- ============================================
-- 仅在 postgres-dev 容器首次启动时执行
-- 创建开发所需的数据库和用户

-- 创建开发数据库
CREATE DATABASE noda_dev;
CREATE DATABASE keycloak_dev;
CREATE DATABASE findclass_dev;

-- 创建开发专用用户（可选，与生产隔离）
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dev_user') THEN
    CREATE ROLE dev_user WITH LOGIN PASSWORD 'dev_password';
  END IF;
END
$$;

-- 授权
GRANT ALL PRIVILEGES ON DATABASE noda_dev TO dev_user;
GRANT ALL PRIVILEGES ON DATABASE keycloak_dev TO dev_user;
GRANT ALL PRIVILEGES ON DATABASE findclass_dev TO dev_user;

-- 为默认用户也授权
GRANT ALL PRIVILEGES ON DATABASE noda_dev TO postgres;
GRANT ALL PRIVILEGES ON DATABASE keycloak_dev TO postgres;
GRANT ALL PRIVILEGES ON DATABASE findclass_dev TO postgres;
