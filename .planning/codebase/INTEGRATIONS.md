# External Integrations

**Analysis Date:** 2026-05-17

## APIs & External Services

**Identity & Authentication:**
- Keycloak 26.2.3 - Self-hosted identity and access management
  - SDK/keycloak-js - Client-side authentication
  - Google OAuth integration - Third-party authentication
  - Configuration: Hostname, proxy headers, SMTP
- Google OAuth 2.0 - Social authentication provider
  - Implementation: Keycloak realm configuration
  - Client ID: Environment variable based
  - Scopes: openid, profile, email

**AI & LLM Services:**
- Anthropic Claude API - AI content generation and filtering
  - SDK/Client: anthropic>=0.86.0
  - Auth: ANTHROPIC_AUTH_TOKEN environment variable
  - Use Cases: Content moderation, data quality enhancement
- OpenAI GPT API - Alternative AI service
  - Auth: OPENAI_API_KEY environment variable
  - Use Cases: Content generation, text analysis
- Google Gemini API - Google's AI service
  - Auth: GOOGLE_AI_API_KEY environment variable
  - Use Cases: Content processing, translation

**Email & Communications:**
- Resend - Transactional email service
  - SDK/Client: resend@6.12.0
  - Auth: RESEND_API_KEY environment variable
  - Use Cases: Password reset, notifications, marketing emails
  - Configuration: Custom domain support, email templates
- Custom SMTP Server - For email delivery
  - Implementation: Keycloak password reset emails
  - Configuration: SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD

## Data Storage

**Databases:**
- PostgreSQL 17.9 - Primary relational database
  - Connection: DATABASE_URL environment variable
  - Client: drizzle-orm, pg
  - Schemas: Authentication, application data, migrations
- Redis - Session management and caching (not implemented yet)

**File Storage:**
- Backblaze B2 - Cloud object storage
  - Connection: B2_ACCOUNT_ID, B2_APPLICATION_KEY, B2_BUCKET_NAME
  - Client: rclone
  - Use Cases: Database backups, static file storage
- Local filesystem - Temporary storage for backups
  - Location: /tmp/postgres_backups
  - Persistence: Docker volumes

**Caching:**
- Local memory caching - Application-level caching
- Potential: Redis integration for distributed caching

## Authentication & Identity

**Auth Provider:**
- Keycloak - Self-hosted identity provider
  - Implementation: Keycloak realm configuration with custom theme
  - Features: SSO, OAuth 2.0, OpenID Connect
  - Configuration: KC_HOSTNAME, KC_PROXY, KC_FRONTEND_URL
- Google OAuth - Third-party social login
  - Implementation: Keycloak social provider configuration
  - Callback: auth.noda.co.nz/auth/callback
- Custom authentication - JWT-based auth
  - SDK/jsonwebtoken - JWT generation and verification
  - Implementation: Email service authentication

## Monitoring & Observability

**Error Tracking:**
- Sentry 10.48.0 - Error tracking and performance monitoring
  - SDK/Sentry: @sentry/react
  - Implementation: React frontend integration
  - Configuration: SENTRY_DSN environment variable

**Logs:**
- Docker logging - Container-level logging
  - Driver: json-file with rotation
  - Location: /var/log/docker
- Application logs - Structured logging
  - Implementation: Console logging with timestamps
  - Frameworks: chalk for colored output

**Health Checks:**
- Docker health checks - Container health monitoring
- HTTP endpoints - Application health monitoring
  - URL: /api/health
  - Method: GET

## CI/CD & Deployment

**Hosting:**
- Self-hosted Docker containers - Production deployment
- Nginx reverse proxy - Load balancing and SSL termination
- Cloudflare Tunnel - Secure access to internal services
- Domain: auth.noda.co.nz, class.noda.co.nz

**CI Pipeline:**
- Jenkins Pipeline - Automated deployment pipeline
  - Jobs: apps-deploy, infra-deploy, cleanup
  - Trigger: Manual triggers via Jenkins UI
  - Configuration: Jenkinsfile in repository

**Environment:**
- Multi-stage Docker builds - Production-ready containers
- Environment-specific configurations - dev/prod profiles
- Blue-green deployment - Zero-downtime deployments
- Rollback support - Image-based rollback

## Environment Configuration

**Required env vars:**
- POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB - Database credentials
- KEYCLOAK_ADMIN_USER, KEYCLOAK_ADMIN_PASSWORD - Keycloak admin
- B2_ACCOUNT_ID, B2_APPLICATION_KEY, B2_BUCKET_NAME - Backblaze B2
- RESEND_API_KEY - Resend email service
- ANTHROPIC_AUTH_TOKEN - Anthropic API access
- CLOUDFLARE_TUNNEL_TOKEN - Cloudflare Tunnel access
- DOPPLER_TOKEN - Doppler secret management

**Secrets location:**
- Environment variables - Runtime configuration
- Doppler integration - Secret management
- Separate prod/preprod environments - Isolated configurations

## Webhooks & Callbacks

**Incoming:**
- Google OAuth callback - Authentication flow completion
- URL: https://auth.noda.co.nz/auth/callback
- Method: GET/POST

**Outgoing:**
- Webhook support - Potential for third-party integrations
- Current implementation: Primarily HTTP-based API calls
- Example: AI service calls, email delivery notifications

---

*Integration audit: 2026-05-17*