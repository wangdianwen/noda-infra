# Phase 14: Container protection and deployment safety - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-11
**Phase:** 14-container-protection-and-deployment-safety
**Areas discussed:** Container security hardening, Deployment safety (rollback), Nginx resilience

---

## Container security hardening

### Security hardening level

| Option | Description | Selected |
|--------|-------------|----------|
| Full hardening | security_opt, cap_drop, read_only for all production containers | ✓ |
| Moderate hardening | Only no-new-privileges + cap_drop ALL | |
| Selective hardening | Only user-facing services (findclass-ssr, nginx) | |

**User's choice:** Full hardening
**Notes:** All production containers get full security hardening. Only applied in prod overlay (docker-compose.prod.yml), dev stays relaxed.

### Non-root user scope

| Option | Description | Selected |
|--------|-------------|----------|
| All containers | Including noda-ops and backup (handle crontab/rclone permissions) | ✓ |
| New containers only | Only findclass-ssr (already configured) | |

**User's choice:** All containers
**Notes:** noda-ops and backup need special handling for crontab and rclone which currently require root.

### Logging rotation scope

| Option | Description | Selected |
|--------|-------------|----------|
| All services, uniform config | json-file driver + max-size/max-file for every service | ✓ |
| High-volume services only | Only Keycloak, findclass-ssr | |

**User's choice:** All services, uniform config
**Notes:** Prevents any service from filling disk with logs.

### Graceful shutdown timeout

| Option | Description | Selected |
|--------|-------------|----------|
| 30s uniform | Same timeout for all services | ✓ |
| Per-service tuning | DB 60s, App 30s, Infra 15s | |

**User's choice:** 30s uniform

### Security hardening environment scope

| Option | Description | Selected |
|--------|-------------|----------|
| Prod only | Only in docker-compose.prod.yml | ✓ |
| Both dev and prod | Consistent across environments | |

**User's choice:** Prod only
**Notes:** Dev environment stays relaxed for easier debugging.

---

## Deployment safety (rollback)

### Rollback strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Image-tag based rollback | Save current tags before deploy, auto-rollback on failure | ✓ |
| Manual rollback with instructions | Stop new containers and prompt manual action | |
| No rollback | Rely on health checks and human intervention | |

**User's choice:** Image-tag based rollback
**Notes:** Save current image digest/tag before deployment, restore on failure.

### Pre-deploy backup

| Option | Description | Selected |
|--------|-------------|----------|
| Auto backup before deploy | Trigger DB backup, skip if backup exists within 12 hours | ✓ |
| Backup gate check only | Block deploy if no recent backup exists | |
| No pre-deploy backup | Rely on scheduled backups | |

**User's choice:** Auto backup before deploy
**Notes:** Leverage existing backup-postgres.sh script. Skip if recent backup within 12 hours.

---

## Nginx resilience

### Upstream failover strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Upstream with retry | Add upstream block + proxy_next_upstream for 502/503 | ✓ |
| Upstream block only | Add upstream block, no retry config | |
| Keep as-is | No changes to Nginx config | |

**User's choice:** Upstream with retry
**Notes:** Uses Nginx OSS passive health checks (no need for Nginx Plus).

### Custom error page

| Option | Description | Selected |
|--------|-------------|----------|
| Custom error page | Friendly "maintenance in progress" page for 502/503 | ✓ |
| Default error page | Users see standard Nginx 502 Bad Gateway | |

**User's choice:** Custom error page
**Notes:** Show friendly message when backend is unavailable.

---

## Claude's Discretion

- Specific capabilities to add back after cap_drop: ALL (per service)
- Log rotation parameters (max-size, max-file values)
- noda-ops/backup non-root user permission handling approach
- Error page content and design
- Image tag save/restore implementation details

## Deferred Ideas

- Image vulnerability scanning (Trivy/Docker Scout) — needs CI/CD pipeline
- SBOM generation — compliance requirement
- Blue-green deployment — too complex for current infra
- Deployment notifications — needs notification channel integration
