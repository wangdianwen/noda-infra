# Codebase Structure

**Analysis Date:** 2026-05-17

## Directory Layout

```
noda-infra/
├── docker/                          # Docker Compose configurations
│   ├── docker-compose.yml          # Base infrastructure config
│   ├── docker-compose.prod.yml      # Production environment overrides
│   ├── docker-compose.r4s.yml       # iStoreOS/r4s specific configuration
│   ├── docker-compose.apps-prod.yml # Production applications (single container)
│   ├── docker-compose.admin.yml     # Admin dashboard service
│   ├── docker-compose.auth.yml      # Authentication application
│   ├── volumes/                     # Docker volumes directory
│   │   ├── backup/                  # PostgreSQL backups
│   │   ├── history/                 # Operational history logs
│   │   └── logs/                    # Service logs
│   └── apps/                       # Application Dockerfiles (mounted externally)
│
├── config/                         # Configuration files
│   ├── environments/               # Environment-specific configs
│   │   ├── prod.env                # Production environment variables
│   │   └── r4s.env                 # r4s environment variables
│   ├── nginx/                      # Nginx configuration
│   │   ├── nginx.conf              # Main Nginx configuration
│   │   ├── conf.d/                 # Site-specific server blocks
│   │   │   └── default.conf        # Main routing configuration
│   │   ├── snippets/               # Reusable Nginx snippets
│   │   │   ├── upstream-findclass.conf
│   │   │   ├── upstream-keycloak.conf
│   │   │   └── proxy-*.conf       # Proxy configuration snippets
│   │   ├── ssl/                    # SSL certificates (development)
│   │   └── errors/                 # Custom error pages
│   ├── logrotate/                  # Log rotation configuration
│   ├── cloudflare/                 # Cloudflare tunnel configuration
│   ├── keys/                       # Service keys and certificates
│   └── postgres/                   # PostgreSQL configuration
│       ├── init/                   # Database initialization scripts
│       ├── conf/                   # PostgreSQL config files
│       └── backup/                 # Backup scripts and archives
│
├── deploy/                         # Deployment scripts and Dockerfiles
│   ├── Dockerfile.noda-ops         # Noda ops container build
│   ├── Dockerfile.noda-apps        # Main applications container build
│   ├── Dockerfile.noda-auth        # Auth application container build
│   ├── nginx/                     # Nginx deployment helpers
│   └── apps/                       # Application-specific deployment configs
│
├── scripts/                        # Operational scripts
│   ├── deploy/                     # Deployment automation scripts
│   │   ├── deploy-infrastructure-prod.sh
│   │   └── deploy-apps-prod.sh
│   ├── lib/                        # Shared utility libraries
│   │   ├── health.sh               # Health check functions
│   │   ├── log.sh                  # Logging utilities
│   │   └── pipeline-stages.sh      # Jenkins pipeline stages
│   ├── backup/                     # Backup and restore scripts
│   ├── jenkins/                    # Jenkins-related scripts
│   ├── r4s/                        # r4s-specific scripts
│   └── pipeline-stages.sh          # Common pipeline logic
│
├── services/                       # Service-specific configurations
│   ├── postgres/                   # PostgreSQL service configuration
│   │   ├── init/                   # Database initialization
│   │   └── conf/                   # PostgreSQL config
│   └── keycloak/                  # Keycloak service configuration
│       └── realm/                  # Keycloak realm configuration
│
├── jenkins/                        # Jenkins pipeline definitions
│   ├── Jenkinsfile.infra          # Infrastructure deployment pipeline
│   ├── Jenkinsfile.apps           # Application deployment pipeline
│   └── config/                    # Jenkins configuration
│
├── workspace/                      # External mounted workspace
│   └── noda-apps/                  # Applications source code
│
├── .planning/                     # Planning documents
│   └── codebase/                  # Codebase analysis documents
│
└── docs/                          # Documentation
    └── superpowers/               # Developer documentation
```

## Directory Purposes

### **docker/**
Purpose: Docker Compose configurations for all environments and services
- Contains overlay files for different environments (base + prod + r4s)
- Houses volume directories for persistent data
- External apps directory mounted from workspace

### **config/**
Purpose: Centralized configuration management
- Environment variables separated by environment
- Nginx configuration with modular design
- Service-specific configurations (PostgreSQL, Keycloak)

### **deploy/**
Purpose: Build and deployment artifacts
- Custom Dockerfiles for each service
- Deployment automation scripts
- Application-specific deployment configs

### **scripts/**
Purpose: Operational automation and utilities
- Shared libraries for common operations
- Environment-specific deployment scripts
- Backup and restore utilities

### **services/**
Purpose: Service-specific configurations
- Database initialization scripts
- Keycloak realm configuration
- Service-specific settings

### **jenkins/**
Purpose: CI/CD pipeline definitions
- Infrastructure deployment pipeline
- Application deployment pipeline
- Jenkins configuration files

## Key File Locations

### **Entry Points**
- `docker/docker-compose.yml`: Main infrastructure configuration
- `jenkins/Jenkinsfile.infra`: Infrastructure deployment automation
- `jenkins/Jenkinsfile.apps`: Application deployment automation

### **Configuration**
- `config/nginx/conf.d/default.conf`: Main routing configuration
- `config/environments/prod.env`: Production environment variables
- `docker/docker-compose.prod.yml`: Production-specific settings

### **Core Logic**
- `scripts/lib/health.sh`: Health check utilities
- `scripts/lib/pipeline-stages.sh`: Pipeline stage definitions
- `deploy/Dockerfile.noda-ops`: Custom build for operational services

### **Testing**
- No dedicated test directory - testing integrated into Jenkins pipelines

## Naming Conventions

### **Files**
- `docker-compose.*.yml`: Docker compose configuration files
- `Dockerfile.*`: Service-specific Docker build files
- `*.env`: Environment variable files
- `*.sh`: Shell scripts for automation

### **Directories**
- `config/`: Configuration files
- `scripts/`: Operational and automation scripts
- `services/`: Service-specific configurations
- `deploy/`: Deployment-related files

### **Services**
- `noda-infra-*`: Infrastructure services (e.g., `noda-infra-postgres-prod`)
- `noda-*`: Application services (e.g., `noda-apps-prod`)
- Container names prefixed with service group for clarity

## Where to Add New Code

### **New Service**
- Infrastructure services: Add to `docker/docker-compose.yml` and overlays
- Application services: Create new compose file (e.g., `docker-compose.newservice.yml`)
- Build files: Add Dockerfile to `deploy/`
- Configuration: Add to `config/` with appropriate environment files

### **New Environment**
- Create overlay file: `docker-compose.newenv.yml`
- Add environment variables: `config/environments/newenv.env`
- Environment-specific scripts: Add to `scripts/newenv/`

### **New Configuration**
- Nginx configuration: Add server block to `config/nginx/conf.d/`
- Service configuration: Add to appropriate `services/` subdirectory
- Environment-specific config: Add to `config/environments/`

### **New Deployment Script**
- Place in `scripts/deploy/`
- Follow naming: `deploy-{service}-{env}.sh`
- Include health checks and rollback logic

## Special Directories

### **docker/volumes/**
- Purpose: Persistent data storage for Docker containers
- Generated: Yes (Docker-managed)
- Committed: No (excluded from .gitignore)

### **workspace/noda-apps/**
- Purpose: External application source code (mounted from separate repo)
- Generated: No
- Committed: Partially (Dockerfiles only in this repo)

### **config/nginx/snippets/**
- Purpose: Reusable Nginx configuration fragments
- Generated: No
- Committed: Yes
- Usage: Included via `include` directives in main config

### **scripts/lib/**
- Purpose: Shared shell libraries for common operations
- Generated: No
- Committed: Yes
- Usage: Sourced by deployment and operational scripts

---

*Structure analysis: 2026-05-17*