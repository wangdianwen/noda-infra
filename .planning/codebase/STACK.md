# Technology Stack

**Analysis Date:** 2026-05-17

## Languages

**Primary:**
- TypeScript ~6.0.2 - Main development language for frontend, backend, and shared packages
- JavaScript 19.2.5 - React runtime and Next.js applications
- Python 3.x - Web scraping scripts and LLM integrations

**Secondary:**
- SQL - PostgreSQL database queries and schema definitions
- HTML/CSS - Frontend markup and styling with Ant Design
- Dockerfile - Container configuration

## Runtime

**Environment:**
- Node.js 22-alpine - Primary runtime for all applications
- Python 3 - Runtime for web scraping scripts
- Alpine Linux 3.21 - Container base image for minimal resource usage

**Package Manager:**
- pnpm 10.29.3 - Main package manager (monorepo)
- npm - Build scripts and individual app commands

## Frameworks

**Core:**
- Next.js 15.5 - Full-stack framework for all web applications
- React 19.2.5 - UI library for all frontend components
- Turborepo 2.9.6 - Monorepo build system
- Hono 4.12.14 - Lightweight web framework for API server

**Testing:**
- Vitest 4.1.4 - Unit testing framework
- Playwright 1.59.1 - End-to-end testing
- @testing-library/react 16.3.2 - React component testing
- @testing-library/jest-dom 6.9.1 - Jest DOM assertions

**Build/Dev:**
- TypeScript 6.0.2 - Type checking and compilation
- Biome 2.1.2 - Linting and formatting
- tsc - TypeScript compiler for packages
- tsx 4.21.0 - TypeScript execution for development

## Key Dependencies

**Critical:**
- PostgreSQL 17.9 - Primary database
- Keycloak 26.2.3 - Authentication service
- Docker Compose - Container orchestration
- Nginx 1.25-alpine - Reverse proxy and load balancer

**Infrastructure:**
- Drizzle ORM 0.45.2 - Database ORM and migrations
- pg 8.20.0 - PostgreSQL client
- rclone - Cloud storage synchronization
- cloudflared - Cloudflare Tunnel client
- doppler - Secret management

**Frontend:**
- Ant Design 6.3.6 - UI component library
- Next.js Internationalization 4.11.0 - i18n support
- @tanstack/react-query 5.99.0 - Data fetching and caching
- Zod 4.3.6 - Schema validation

**AI/LLM Integration:**
- Anthropic API 0.86.0 - AI service integration
- OpenAI API - Alternative AI service support
- Gemini API - Google AI service integration

**Email Services:**
- Resend 6.12.0 - Transactional email service
- React Email 4.0.8 - Email template library

**Monitoring:**
- Sentry 10.48.0 - Error tracking and performance monitoring

## Configuration

**Environment:**
- Docker Compose - Container orchestration
- Docker Compose profiles - Environment-specific configurations
- Environment variables - Runtime configuration
- .env files - Environment variable management

**Build:**
- package.json - Package definitions and scripts
- pnpm-workspace.yaml - Workspace configuration
- turbo.json - Turborepo configuration
- tsconfig.base.json - Base TypeScript configuration
- Dockerfile - Container build configuration

## Platform Requirements

**Development:**
- Node.js 22.0+ or compatible version
- Docker and Docker Compose
- PostgreSQL database (development only)
- pnpm package manager

**Production:**
- Linux server (tested with Alpine)
- Docker and Docker Compose
- PostgreSQL database
- Cloudflare Tunnel for external access
- Backblaze B2 for backups

---

*Stack analysis: 2026-05-17*