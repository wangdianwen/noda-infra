-- ============================================
-- 开发环境种子数据
-- ============================================
-- 仅为开发/测试环境提供示例数据
-- 生产环境永远不执行此脚本

\c noda_dev;

-- UUID 扩展（Prisma 等框架需要）
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 示例：基础表结构（根据实际应用 schema 调整）
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email VARCHAR(255) UNIQUE NOT NULL,
  name VARCHAR(255),
  role VARCHAR(50) DEFAULT 'user',
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS courses (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  title VARCHAR(255) NOT NULL,
  description TEXT,
  instructor_id UUID REFERENCES users(id),
  created_at TIMESTAMP DEFAULT NOW()
);

-- 插入测试用户
INSERT INTO users (email, name, role) VALUES
  ('dev@test.com', 'Dev User', 'user'),
  ('admin@test.com', 'Admin User', 'admin'),
  ('teacher@test.com', 'Teacher User', 'instructor')
ON CONFLICT (email) DO NOTHING;

-- 插入测试课程
INSERT INTO courses (title, description, instructor_id) VALUES
  ('测试课程 1', '用于开发测试的示例课程', (SELECT id FROM users WHERE email = 'teacher@test.com')),
  ('测试课程 2', '另一个开发测试课程', (SELECT id FROM users WHERE email = 'teacher@test.com'))
ON CONFLICT DO NOTHING;

\c keycloak_dev;

-- Keycloak 开发数据库只需要空库，由 Keycloak 自动初始化 schema

\c findclass_dev;

-- Findclass 开发数据库
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS classes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name VARCHAR(255) NOT NULL,
  description TEXT,
  created_at TIMESTAMP DEFAULT NOW()
);

-- 插入测试班级
INSERT INTO classes (name, description) VALUES
  ('测试班级 A', '2026 第一学期测试班'),
  ('测试班级 B', '2026 第一学期普通班')
ON CONFLICT DO NOTHING;
