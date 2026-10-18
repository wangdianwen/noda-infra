#!/bin/sh
# Immich 缩略图自愈（每小时）：修上传链路不写 asset_job_status 的产品 bug
# + 视频缺流信息二次提取 + missing-only 补队。负载>8 自动跳过本轮。
LOG_TAG="immich-heal"
PSQL="docker exec immich_postgres psql -U postgres immich -t -A -c"
TOKEN=$(cat /mnt/mmc1-4/System/Scripts/.immich-ops-token 2>/dev/null)
[ -n "$TOKEN" ] || { echo "$LOG_TAG no token, abort"; exit 1; }

LOAD=$(cut -d" " -f1 /proc/loadavg)
if [ "$(awk -v l="$LOAD" "BEGIN{print (l>8)?1:0}")" = "1" ]; then
  echo "$(date "+%F %T") $LOG_TAG load=$LOAD 高负载跳过本轮"
  exit 0
fi

BF=$($PSQL "WITH ins AS (INSERT INTO asset_job_status (\"assetId\", \"metadataExtractedAt\") SELECT a.id, COALESCE((SELECT max(e.\"updatedAt\") FROM asset_exif e WHERE e.\"assetId\"=a.id), now()) FROM asset a WHERE a.status='active' AND EXISTS (SELECT 1 FROM asset_exif e WHERE e.\"assetId\"=a.id) AND NOT EXISTS (SELECT 1 FROM asset_job_status s WHERE s.\"assetId\"=a.id) ON CONFLICT (\"assetId\") DO NOTHING RETURNING 1) SELECT count(*) FROM ins;")
case "$BF" in (*[!0-9]*|"") BF=0;; esac

FIX=$($PSQL "WITH upd AS (UPDATE asset_job_status s SET \"metadataExtractedAt\"=NULL WHERE EXISTS (SELECT 1 FROM asset a WHERE a.id=s.\"assetId\" AND a.status='active' AND a.type='VIDEO' AND NOT EXISTS (SELECT 1 FROM asset_video v WHERE v.\"assetId\"=a.id) AND NOT EXISTS (SELECT 1 FROM asset_file f WHERE f.\"assetId\"=a.id AND f.type='thumbnail') AND s.\"metadataExtractedAt\" IS NOT NULL) RETURNING 1) SELECT count(*) FROM upd;")
case "$FIX" in (*[!0-9]*|"") FIX=0;; esac

echo "$(date "+%F %T") $LOG_TAG bf=$BF videofix=$FIX load=$LOAD"

if [ "$BF" = "0" ] && [ "$FIX" = "0" ]; then exit 0; fi

curl -s -X PUT -H "x-api-key: $TOKEN" -H "Content-Type: application/json" -d "{\"command\":\"start\",\"force\":false}" http://localhost:2283/api/jobs/metadataExtraction -o /dev/null
curl -s -X PUT -H "x-api-key: $TOKEN" -H "Content-Type: application/json" -d "{\"command\":\"start\",\"force\":false}" http://localhost:2283/api/jobs/thumbnailGeneration -o /dev/null
echo "$(date "+%F %T") $LOG_TAG kicked metadata+thumbnail"
