#!/bin/sh
# 发版资源探针（2026-10-07）：输出 key=value 供管线 pipeline_resource_gate 解析。
# 只读、无副作用；缺失项输出 key=unknown（管线对 unknown 按失败项处理）。
avail=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk "{print \$2}")
[ -n "$avail" ] && echo "mem_avail_mb=$((avail / 1024))" || echo "mem_avail_mb=unknown"
mp=$(docker stats --no-stream --format "{{.MemPerc}}" seaweedfs 2>/dev/null | tr -d "%")
echo "weed_memperc=${mp:-unknown}"
echo "weed_health=$(docker inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" seaweedfs 2>/dev/null)"
echo "relays=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -c "^tmp-s3-relay-")"
echo "load1=$(awk "{print int(\$1)}" /proc/loadavg 2>/dev/null)"
swt=$(grep SwapTotal /proc/meminfo 2>/dev/null | awk "{print \$2}")
swf=$(grep SwapFree /proc/meminfo 2>/dev/null | awk "{print \$2}")
if [ -n "$swt" ] && [ "$swt" -gt 0 ] 2>/dev/null; then
  echo "swapfree_pct=$((swf * 100 / swt))"
else
  echo "swapfree_pct=100"
fi
