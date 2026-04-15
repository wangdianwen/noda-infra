---
phase: 23-pipeline-integration
reviewed: 2026-04-15T12:00:00Z
depth: standard
files_reviewed: 3
files_reviewed_list:
  - jenkins/Jenkinsfile
  - scripts/jenkins/init.groovy.d/03-pipeline-job.groovy
  - scripts/pipeline-stages.sh
findings:
  critical: 1
  warning: 4
  info: 3
  total: 8
status: issues_found
---

# Phase 23: Code Review Report

**Reviewed:** 2026-04-15T12:00:00Z
**Depth:** standard
**Files Reviewed:** 3
**Status:** issues_found

## Summary

Reviewed the three files comprising the Jenkins Pipeline integration: the Jenkinsfile (8-stage blue-green deployment pipeline), the Groovy init script (Jenkins job configuration), and the pipeline stages shell function library. Found 1 critical issue with Docker Compose build context resolution, 4 warnings covering error handling gaps and code robustness, and 3 informational items.

The most significant issue is CR-01: `pipeline_build` uses `docker compose -f "$COMPOSE_FILE" build`, but `docker-compose.app.yml` defines the build context as `../../noda-apps` relative to the compose file location. When Jenkins runs from the workspace root, this relative path will resolve outside the workspace and likely fail or pick up the wrong source code.

## Critical Issues

### CR-01: Docker Compose build context resolves outside Jenkins workspace

**File:** `scripts/pipeline-stages.sh:243`
**Issue:** `pipeline_build` calls `docker compose -f "$COMPOSE_FILE" build findclass-ssr` where `COMPOSE_FILE` points to `docker/docker-compose.app.yml`. The compose file defines:
```yaml
build:
  context: ../../noda-apps
  dockerfile: ../noda-infra/deploy/Dockerfile.findclass-ssr
```
These relative paths are resolved relative to the compose file location (`docker/`). When Jenkins checks out `noda-infra` to `$WORKSPACE` and `noda-apps` to `$WORKSPACE/noda-apps`, the path `../../noda-apps` from `docker/` resolves to `$WORKSPACE/../../noda-apps` -- which is outside the workspace entirely.

Additionally, the `noda-apps` code is checked out by the Jenkinsfile into `$WORKSPACE/noda-apps/`, but Docker Compose build context points to a different location. The build will either fail (directory not found) or use stale/wrong source code.

**Fix:** Change `pipeline_build` to build the image directly using `docker build` with explicit paths, or override the build context via environment variable / `--build-context` flag:

```bash
pipeline_build() {
  local apps_dir="$1"
  local git_sha="$2"

  log_info "构建镜像..."
  docker build \
    -t findclass-ssr:latest \
    -f "$PROJECT_ROOT/deploy/Dockerfile.findclass-ssr" \
    "$apps_dir"
  docker tag findclass-ssr:latest "findclass-ssr:${git_sha}"
  log_success "镜像构建完成: findclass-ssr:${git_sha}"
}
```

This uses the same Dockerfile but points the build context at the Jenkins-checked-out `noda-apps` directory, avoiding the relative path issue.

## Warnings

### WR-01: `cleanup_old_images` sorts by date with lost time granularity

**File:** `scripts/pipeline-stages.sh:139-142`
**Issue:** The sort key `-k2` on `{{.Tag}} {{.CreatedAt}}` only captures the date portion of `CreatedAt` (e.g., `2026-04-15`), losing the time component. Images created on the same day will sort in arbitrary order rather than by actual creation time. This could cause the wrong images to be preserved or deleted.

**Fix:** Use Docker's `--format '{{.CreatedAt}}|{{.Tag}}'` with `sort -r` and a timestamp-preserving sort, or use `CreatedSince` as a proxy. Better yet, use `docker image inspect` for precise timestamps:

```bash
cleanup_old_images() {
  local keep_count="${1:-5}"
  local images
  images=$(docker images findclass-ssr --format '{{.ID}} {{.CreatedAt}} {{.Tag}}' \
    | grep -v ' latest ' \
    | sort -t' ' -k2 -r \
    | awk '{print $3}')

  # ... rest unchanged
```

Or use `--filter` and `json` format for reliable parsing.

### WR-02: `pipeline_failure_cleanup` hardcodes container name pattern

**File:** `scripts/pipeline-stages.sh:321`
**Issue:** The function hardcodes `local target_container="findclass-ssr-${target_env}"` instead of using `get_container_name "$target_env"` like every other function. If the container naming convention ever changes in `manage-containers.sh`, this cleanup path will silently operate on the wrong container name, potentially leaving a failed container running.

**Fix:**
```bash
pipeline_failure_cleanup() {
  local target_env="$1"
  local target_container
  target_container=$(get_container_name "$target_env)")
  # ... rest unchanged
```

### WR-03: `pipeline_test` `cd` inside sourced function can cause confusion

**File:** `scripts/pipeline-stages.sh:252`
**Issue:** `pipeline_test` calls `cd "$apps_dir"` to change the working directory. While each Jenkins `sh` block is a separate process (so the cd doesn't leak), the function name `pipeline_test` and its documentation say "安装依赖" but the actual lint/test execution happens as separate `sh` steps in the Jenkinsfile (lines 82-83). This separation is intentional per the comment on line 79-81, but the `cd` inside `pipeline_test` means if anyone calls `pipeline_test` and then expects to be back in the original directory, they will be surprised. The pattern is fragile.

**Fix:** Use a subshell for the cd, or pass the working directory to pnpm:
```bash
pipeline_test() {
  local apps_dir="$1"
  (cd "$apps_dir" && pnpm install --frozen-lockfile)
  log_success "依赖安装完成"
}
```

### WR-04: Jenkinsfile `ACTIVE_ENV` environment evaluation timing

**File:** `jenkins/Jenkinsfile:12-16`
**Issue:** `ACTIVE_ENV` is evaluated in the `environment {}` block, which runs when the pipeline agent is allocated -- before any stage executes. If the active environment file (`/opt/noda/active-env`) changes between pipeline start and the Switch stage, the `ACTIVE_ENV` and `TARGET_ENV` values will be stale. While `disableConcurrentBuilds()` prevents two pipelines from running simultaneously, a manual `manage-containers.sh switch` or a failed prior pipeline could change the state between evaluation and use. The Switch stage (line 113) passes `$ACTIVE_ENV` as the rollback target, but if the file was changed externally, the rollback would target the wrong environment.

**Fix:** Read the active environment at the point of use in the Switch stage, not in the environment block:

```groovy
stage('Switch') {
    steps {
        sh '''
            source scripts/lib/log.sh
            source scripts/pipeline-stages.sh
            CURRENT_ACTIVE=$(cat /opt/noda/active-env 2>/dev/null || echo blue)
            pipeline_switch "$TARGET_ENV" "$CURRENT_ACTIVE"
        '''
    }
}
```

## Info

### IN-01: Groovy init script hardcodes Git URL and credentials ID

**File:** `scripts/jenkins/init.groovy.d/03-pipeline-job.groovy:24-25`
**Issue:** The Git remote URL `git@github.com:dianwenwang/noda-infra.git` and credentials ID `noda-infra-git-credentials` are hardcoded in the XML template. If the repository URL changes or credentials are rotated, the init script must be manually updated and Jenkins reinitialized.

**Fix:** Consider externalizing these to Jenkins environment variables or a configuration file that the init script reads at runtime.

### IN-02: `pipeline_preflight` Jenkinsfile invocation passes no arguments

**File:** `jenkins/Jenkinsfile:56`
**Issue:** `pipeline_preflight` is called without arguments, relying on the default `$WORKSPACE/noda-apps`. This works correctly in Jenkins context but means the function's `$1` parameter is unused in practice. The fallback logic is sound; this is purely an observation.

**Fix:** No action needed. The default value matches Jenkins workspace layout.

### IN-03: Duplicate utility functions between `pipeline-stages.sh` and `blue-green-deploy.sh`

**File:** `scripts/pipeline-stages.sh:30-31`
**Issue:** The comments on lines 30, 67, and 130 note that `http_health_check`, `e2e_verify`, and `cleanup_old_images` were "copied from blue-green-deploy.sh" because that file "has no source guard and cannot be sourced." This creates a maintenance burden -- bug fixes must be applied in two places. The functions are identical in behavior but separate copies.

**Fix:** Consider adding a source guard to `blue-green-deploy.sh` and having `pipeline-stages.sh` source it, or extracting shared functions into a separate `scripts/lib/blue-green-common.sh` that both files source.

---

_Reviewed: 2026-04-15T12:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
