# Codebase Concerns

**Analysis Date:** 2026-05-18

## Tech Debt

### Monolithic Scripts

**pipeline-stages.sh (1130 lines):**
- Issue: Single file containing all Jenkins Pipeline logic, difficult to maintain and test
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/pipeline-stages.sh`
- Impact: Code duplication, testing challenges, onboarding difficulty
- Fix approach: Split into modular components by functionality (deploy, health-check, cleanup, etc.)

**setup-jenkins.sh (1033 lines):**
- Issue: Monolithic Jenkins installation script with multiple responsibilities
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/setup-jenkins.sh`
- Impact: Hard to modify individual aspects, slow execution, poor error isolation
- Fix approach: Modularize into setup-docker.sh, setup-java.sh, setup-jenkins-core.sh

### Complex Docker Compose Overlay System

**Multiple overlay files:**
- Issue: 7 compose files with complex merging logic, confusing deployment targets
- Files: 
  - `/Users/dianwenwang/Project/noda-infra/docker/docker-compose.yml`
  - `/Users/dianwenwang/Project/noda-infra/docker/docker-compose.prod.yml`
  - `/Users/dianwenwang/Project/noda-infra/docker/docker-compose.r4s.yml`
  - `/Users/dianwenwang/Project/noda-infra/docker/docker-compose.dev.yml`
  - `/Users/dianwenwang/Project/noda-infra/docker/docker-compose.apps-prod.yml`
  - `/Users/dianwenwang/Project/noda-infra/docker/docker-compose.auth.yml`
  - `/Users/dianwenwang/Project/noda-infra/docker/docker-compose.admin.yml`
- Impact: Deployment errors due to file ordering, unclear which configuration takes precedence
- Fix approach: Consolidate into environment-specific compose files with clear inheritance

### Backup System Complexity

**backup/ directory fragmentation:**
- Issue: Backup logic spread across multiple files with tight coupling
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/backup/` (7 files, ~2000 lines total)
- Impact: Testing individual components difficult, circular dependencies between modules
- Fix approach: Create unified backup-engine.sh with plugin architecture for different storage backends

## Known Bugs

### Hard-coded Values in Docker Build

**VITE_* environment variables not runtime configurable:**
- Symptoms: Frontend configuration changes require Docker image rebuild
- Files: `deploy/Dockerfile.findclass-ssr` (ARG declarations)
- Trigger: Changes to VITE_KEYCLOAK_URL, VITE_KEYCLOAK_REALM not reflected without rebuild
- Workaround: Rebuild container on configuration changes

### Memory Pressure on r4s

**Swap file dependency:**
- Symptoms: System instability during high memory usage
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/r4s/setup-swap.sh`
- Trigger: Multiple services starting simultaneously, or unexpected traffic spikes
- Workaround: Manual swap file setup required for r4s deployment

### Jenkins Password Reset Fragility

**Temporary file handling in password reset:**
- Symptoms: Potential file permission issues
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/setup-jenkins.sh:668,905`
- Trigger: System with restrictive umask settings
- Workaround: Explicit chmod 600 for temporary Groovy scripts

## Security Considerations

### Secret Management Multiple Patterns

**Mixed secret handling approaches:**
- Risk: Inconsistent security practices across scripts
- Files: Multiple files in `scripts/lib/secrets.sh` and Doppler integration
- Current mitigation: Doppler primary, with local .env fallback
- Recommendations: Standardize all secrets through Doppler, remove local .env dependency

### Temporary File Exposure

**Unencrypted temporary files with sensitive data:**
- Risk: Secrets may be visible in /tmp during script execution
- Files: Multiple scripts create temporary .env and .groovy files
- Current mitigation: Script marks them as temporary
- Recommendations: Use /dev/shm for temporary files, implement automatic cleanup

### Jenkins API Token Security

**Hard-coded credentials in scripts:**
- Risk: Credentials stored in version control
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/jenkins/config/jenkins-admin.env`
- Current mitigation: Excluded from .gitignore
- Recommendations: Move to Doppler secret management

## Performance Bottlenecks

### Docker Build Caching

**Inefficient build cache usage:**
- Problem: Full image rebuilds on small changes
- Files: `deploy/Dockerfile.findclass-ssr`
- Cause: Multi-stage builds with shared dependencies
- Improvement path: Implement build-arg caching, separate base image from application layers

### Health Check Polling

**Synchronous waiting with fixed intervals:**
- Problem: Deployment takes longer than necessary
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/pipeline-stages.sh:400,533-539`
- Cause: Fixed polling intervals not adaptive to container startup times
- Improvement path: Exponential backoff with early termination on success

### Large Script Loading

**Slow Pipeline startup:**
- Problem: Jenkins Pipeline loads 1000+ line script before execution
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/pipeline-stages.sh`
- Cause: Single monolithic script with all dependencies
- Improvement path: Lazy loading of pipeline functions, only load what's needed

## Fragile Areas

### r4s Hardware-Specific Code

**iStoreOS-specific assumptions:**
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/r4s/` (5 files)
- Why fragile: Hard-coded UCI commands, specific swap file location
- Safe modification: Create hardware detection layer, abstract iStoreOS operations
- Test coverage: Limited to r4s hardware

### Nginx Configuration Management

**Manual snippet management:**
- Files: `/Users/dianwenwang/Project/noda-infra/config/nginx/conf.d/`
- Why fragile: Direct file manipulation through docker exec
- Safe modification: Use nginx templating or configuration management tools
- Test coverage: No automated validation of nginx config syntax

### Doppler Integration Complexity

**Dual-mode secret loading:**
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/lib/secrets.sh`
- Why fragile: Multiple fallback paths increase failure scenarios
- Safe modification: Simplify to single secret source with clear error messages
- Test coverage: Requires actual Doppler project to test

## Scaling Limits

### Memory-Constrained Environment

**3.77 GiB RAM limit:**
- Current capacity: 7 services with memory limits totaling ~2.4GB
- Limit: Concurrent operations cause swap thrashing
- Scaling path: Offload backup processing to separate schedule, implement graceful degradation

### Single Server Dependency

**All services on single node:**
- Current capacity: Limited by single server resources
- Limit: No horizontal scaling, single point of failure
- Scaling path: Implement service separation when additional hardware available

## Dependencies at Risk

### Docker Compose Version

**Docker Compose v2 dependency:**
- Risk: Future breaking changes in compose file format
- Impact: All deployment scripts affected
- Migration plan: Test with Docker Compose v3 when available, prepare adapter layer

### Legacy Keycloak Configuration

**Deprecated KC_HOSTNAME_PORT option:**
- Risk: Keycloak updates may remove v1 options
- Impact: Authentication breaks on Keycloak upgrades
- Migration path: Already migrated to KC_HOSTNAME, but need to test each Keycloak version

## Missing Critical Features

### Automated Rollback

**No automatic rollback on failure:**
- Problem: Manual intervention required for deployment failures
- Blocks: Zero-downtime deployment promise
- Implementation: Add health-check triggered rollback in pipeline-stages.sh

### Centralized Logging

**Scattered log management:**
- Problem: No centralized log aggregation or alerting
- Blocks: Troubleshooting across multiple containers
- Implementation: Add fluentd/filebeat for log collection

## Test Coverage Gaps

### Pipeline Integration Testing

**Untested deployment workflows:**
- What's not tested: Actual Jenkins Pipeline execution end-to-end
- Files: `/Users/dianwenwang/Project/noda-infra/Jenkinsfile`
- Risk: Pipeline failures in production due to environment differences
- Priority: High - requires Jenkins mock or test environment

### r4s Hardware Testing

**Untested ARM64 behavior:**
- What's not tested: Performance and behavior differences from Mac development
- Files: All r4s-specific scripts
- Risk: Performance surprises or ARM-specific bugs
- Priority: Medium - requires r4s hardware for testing

### Secret Rotation Testing

**Untested secret rotation workflow:**
- What's not tested: Doppler secret rotation without downtime
- Files: `/Users/dianwenwang/Project/noda-infra/scripts/lib/secrets.sh`
- Risk: Secrets misconfiguration during rotation
- Priority: Medium - requires staged secret update testing

---

*Concerns audit: 2026-05-18*