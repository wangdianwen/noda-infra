# Architecture

**Analysis Date:** 2026-05-17

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     External Access                            │
├─────────────────────────────────────────────────────────────────┤
│  Cloudflare CDN → Cloudflare Tunnel (noda-ops) → Nginx       │
│  https://class.noda.co.nz    noda-ops:8080   nginx:80/443     │
│  https://auth.noda.co.nz     ↑               upstreams      │
│  https://www.noda.co.nz       └─────────────┐                │
└─────────────────────────────────────────────┼─────────────────┘
                                              │
┌─────────────────────────────────────────────▼─────────────────┐
│                    Internal Services                           │
│      (Docker Network: noda-network)                            │
├───────────┬──────────┬──────────┬──────────┬───────────────────┤
│   RDS     │ Keycloak │ findclass│  admin   │     auth-app      │
│   5432    │   8080   │   3000   │  8001    │       3004        │
│ postgres  │ ← nginx  │   :3001  │  :3011   │     :3004         │
│           │ ← proxy  │   SSR    │  Hono    │     Next.js       │
│           └──────────┼──────────┼──────────┼───────────────────┤
│                       │          │          │                   │
│                       └──────────┼──────────┼───────────────────┤
│                                  │          │                   │
│                                  └──────────┼───────────────────┤
│                                             │                   │
└─────────────────────────────────────────────┼─────────────────┘
                                              │
┌─────────────────────────────────────────────▼─────────────────┐
│                    Shared Infrastructure                        │
│              (PostgreSQL + Jenkins CI/CD)                     │
├──────────┬───────────────────────────────────────────────────────┤
│  Backblaze │ Jenkins Pipeline                                │
│  B2 Storage │ 7-stage deploy flow                          │
│  Backups   │  Backup → Deploy → Health Check → Verify → Cleanup │
└───────────┴─────────────────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| **Nginx** | Single entry point, SSL termination, reverse proxy, load balancing | `config/nginx/conf.d/default.conf` |
| **PostgreSQL** | Centralized database (noda_prod, keycloak separate schemas) | `docker/docker-compose.yml` |
| **Keycloak** | OAuth2/OIDC authentication, Google SSO, user management | `docker/docker-compose.prod.yml` |
| **findclass-ssr** | SSR + API + static files (Next.js multi-app) | `docker/docker-compose.apps-prod.yml` |
| **noda-ops** | Backups (PostgreSQL + B2) + Cloudflare Tunnel | `docker/docker-compose.yml` |
| **Admin Dashboard** | Internal admin interface (localhost:8001) | `docker/docker-compose.admin.yml` |
| **Auth App** | User authentication UI (login/register/forgot-password) | `docker/docker-compose.auth.yml` |
| **Jenkins** | CI/CD pipeline orchestration | `jenkins/Jenkinsfile.infra`, `jenkins/Jenkinsfile.apps` |

## Pattern Overview

**Overall:** Multi-environment Docker Compose overlay architecture

**Key Characteristics:**
- **Overlay pattern**: Base configuration + environment-specific overlays (prod, r4s, dev)
- **Separate compose projects**: Infrastructure (`noda-infra`) vs Applications (`noda-apps-prod`, `noda-auth`)
- **Blue-green deployment**: Jenkins-controlled container replacement for zero-downtime updates
- **Single network**: Shared `noda-network` for internal service communication

## Layers

### **Presentation Layer**
- **Nginx**: Reverse proxy with dynamic upstream configuration
  - Purpose: Single entry point, SSL termination, request routing
  - Location: `config/nginx/conf.d/default.conf`
  - Contains: Server blocks for each domain, proxy configurations
  - Depends on: DNS resolution for container names
  - Used by: External clients via Cloudflare Tunnel

### **Application Layer**
- **findclass-ssr**: SSR + API + static files (port 3000)
  - Purpose: Main application with server-side rendering
  - Location: `docker/docker-compose.apps-prod.yml`
  - Contains: Next.js SSR, API endpoints, static assets
  - Depends on: PostgreSQL, Keycloak
  - Used by: Nginx upstream `$findclass_upstream`

- **noda-auth**: Authentication UI (port 3004)
  - Purpose: User-facing authentication flows
  - Location: `docker/docker-compose.auth.yml`
  - Contains: Next.js app for login/register/forgot-password
  - Depends on: Keycloak, email service
  - Used by: Nginx upstream `$auth_app_upstream`

- **Admin Dashboard**: Internal admin interface (port 8001)
  - Purpose: Administrative tasks and monitoring
  - Location: `docker/docker-compose.admin.yml`
  - Contains: Hono API + Next.js frontend
  - Depends on: PostgreSQL, Keycloak
  - Used by: Internal users via localhost

### **Infrastructure Layer**
- **PostgreSQL**: Central database
  - Purpose: Data persistence for applications and Keycloak
  - Location: `docker/docker-compose.yml`
  - Contains: PostgreSQL instance with separate databases
  - Depends on: Disk storage for volumes
  - Used by: All applications

- **Keycloak**: Identity provider
  - Purpose: OAuth2/OIDC authentication, user management
  - Location: `docker/docker-compose.prod.yml` (profiles: disabled)
  - Contains: Keycloak server with Google SSO
  - Depends on: PostgreSQL, Docker network
  - Used by: All apps for authentication

- **noda-ops**: Operational services
  - Purpose: Backups + Cloudflare Tunnel
  - Location: `docker/docker-compose.yml`
  - Contains: Custom backup scripts, Cloudflared tunnel
  - Depends on: PostgreSQL, B2 API
  - Used by: External access, disaster recovery

### **CI/CD Layer**
- **Jenkins Pipeline**: Deployment automation
  - Purpose: Zero-downtime deployment, health checks, rollbacks
  - Location: `jenkins/Jenkinsfile.infra`, `jenkins/Jenkinsfile.apps`
  - Contains: 7-stage deployment workflow
  - Depends on: Docker CLI, health check scripts
  - Used by: Manual triggers for deployments

## Data Flow

### Primary Request Path

1. **External Request** (Cloudflare → Tunnel → Nginx)
   - Client → Cloudflare CDN → Cloudflare Tunnel → `noda-ops:8080` → `nginx:80`
   - File: `config/nginx/conf.d/default.conf` (server blocks)

2. **Request Routing** (Nginx upstream selection)
   - Nginx resolves dynamic upstream via `/etc/nginx/snippets/upstream-*.conf`
   - Keycloak: `$keycloak_upstream` → `http://noda-infra-keycloak:8080`
   - findclass: `$findclass_upstream` → `http://noda-apps-prod:3000`
   - Auth App: `$auth_app_upstream` → `http://noda-auth:3004`

3. **Application Processing**
   - **SSR Request**: `findclass-ssr` (Next.js SSR) → PostgreSQL
   - **API Request**: Direct to service API endpoints
   - **Auth Flow**: `noda-auth` → Keycloak → Google OAuth

### Backup & Recovery Flow

1. **Scheduled Backup** (noda-ops container)
   - `pg_dump` → B2 cloud storage
   - File: `scripts/backup/postgres-backup.sh`
   - Trigger: Cron job in noda-ops container

2. **Manual Recovery**
   - B2 download → `pg_restore` → PostgreSQL
   - File: `scripts/backup/restore-from-b2.sh`

## Key Abstractions

### **Upstream Configuration**
- Purpose: Dynamic service discovery for Nginx
- Examples: `/etc/nginx/snippets/upstream-findclass.conf`, `/etc/nginx/snippets/upstream-keycloak.conf`
- Pattern: File-based configuration with resolver for DNS updates

### **Environment Overlays**
- Purpose: Configuration inheritance and specialization
- Examples: `docker-compose.prod.yml`, `docker-compose.r4s.yml`
- Pattern: YAML anchors and overrides for environment-specific settings

### **Health Check Pattern**
- Purpose: Service availability monitoring
- Examples: `wait_container_healthy` function in `scripts/lib/health.sh`
- Pattern: HTTP/TCP checks with timeout and retry logic

## Entry Points

### **Infrastructure Deploy**
- Location: `jenkins/Jenkinsfile.infra`
- Triggers: Manual Jenkins trigger
- Responsibilities: Deploy infrastructure services (postgres, nginx, keycloak, noda-ops)
- Pattern: Single container replacement with backup before postgres changes

### **Application Deploy**
- Location: `jenkins/Jenkinsfile.apps`
- Triggers: Manual Jenkins trigger
- Responsibilities: Deploy applications with blue-green deployment
- Pattern: Build → Pre-prod verification → Production switch

### **Direct Docker Access**
- Location: `docker/docker-compose.yml`
- Triggers: Manual `docker compose` commands
- Responsibilities: Container management, troubleshooting
- Pattern: Compose file merging for different environments

## Architectural Constraints

### **Threading**
- Single-threaded event loops for Node.js applications
- PostgreSQL connection pooling in application code
- No explicit threading model enforced at infrastructure level

### **Global State**
- PostgreSQL volumes persist data across container restarts
- Jenkins workspace contains temporary deployment artifacts
- Nginx configuration reloaded on upstream changes

### **Circular Imports**
- None detected - services are loosely coupled via network calls
- Database shared but no direct code dependencies between services

## Anti-Patterns

### **Hardcoded Container Names**
**What happens**: Container names like `noda-infra-postgres-prod` are hardcoded in multiple places
**Why it's wrong**: Makes replacements brittle and requires global updates
**Do this instead**: Use service names and Docker DNS resolution consistently

### **Multiple Compose Projects**
**What happens**: Separate compose files for different services (`noda-infra`, `noda-apps-prod`, `noda-auth`)
**Why it's wrong**: Complicates network setup and service discovery
**Do this instead**: Use docker-compose profiles or a single monorepo compose with service grouping

### **Environment Variables for Build Time**
**What happens**: `VITE_*` variables baked into JS during build, can't be overridden at runtime
**Why it's wrong**: Forces rebuilds for configuration changes
**Do this instead**: Use runtime config where possible or proper config management

## Error Handling

**Strategy**: Health check-based failure detection and automatic rollback

**Patterns**:
- **Container Health**: Docker health checks with automatic restart
- **HTTP Health**: `/health` endpoints checked by Jenkins pipeline
- **Database Health**: `pg_isready` checks with connection retry logic
- **Network Health**: Nginx upstream failover with timeout handling

## Cross-Cutting Concerns

**Logging**: JSON structured logs with max-size/max-file rotation
**Security**: Container security profiles (no-new-privileges, read-only filesystems)
**Monitoring**: Health check endpoints exposed for external monitoring
**Backup**: Automated PostgreSQL backups to B2 cloud storage
**SSL**: Cloudflare terminates SSL at tunnel edge, internal HTTP only

---

*Architecture analysis: 2026-05-17*