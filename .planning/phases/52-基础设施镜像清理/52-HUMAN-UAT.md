---
status: partial
phase: 52-基础设施镜像清理
source: [52-VERIFICATION.md]
started: 2026-04-21T12:00:00Z
updated: 2026-04-21T12:00:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. noda-ops 镜像构建验证
expected: docker build 构建成功，运行时镜像中 which wget/gnupg/curl 返回非零，cloudflared/doppler/jq/numfmt/pg_isready 可用
result: [pending]

**验证命令：**
```bash
docker build -f deploy/Dockerfile.noda-ops -t noda-ops:test .
docker run --rm noda-ops:test sh -c "which wget 2>/dev/null && echo 'FAIL' || echo 'PASS'; cloudflared --version; doppler --version; jq --version; numfmt --from=iec 1K; pg_isready --version"
```

### 2. backup 镜像构建验证
expected: docker build 构建成功，运行时镜像中 jq/numfmt/pg_isready 可用，curl 不存在
result: [pending]

**验证命令：**
```bash
docker build -f deploy/Dockerfile.backup -t noda-backup:test .
docker run --rm noda-backup:test sh -c "jq --version; numfmt --from=iec 1K; pg_isready --version; which curl 2>/dev/null && echo 'FAIL' || echo 'PASS'"
```

### 3. Doppler 动态链接验证
expected: ldd /usr/bin/doppler 无缺失 .so 文件
result: [pending]

**验证命令：**
```bash
docker run --rm noda-ops:test sh -c "ldd /usr/bin/doppler"
```

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
