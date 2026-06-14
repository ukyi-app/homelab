#!/usr/bin/env bash
# DR 보조 도구 (④): fresh initdb `pg`(새 system ID)가 R2의 옛 barman 아카이브와 충돌해
# ContinuousArchiving이 깨질 때, serverName `pg`의 아카이브(base/+wals/)만 정리해 아카이빙을
# 재개시킨다. 재구축 후 prod에 복구할 실데이터가 없을 때의 정본 리셋 절차(2026-06-14 드릴 검증).
#
# 안전 설계:
#  (1) 기본은 dry-run(범위만 출력, 삭제 안 함) — 실제 삭제는 --purge가 필요하다.
#  (2) serverName 프리픽스(<bucket>/pg/)만 건드린다 — pgdump/ 헤지·타 버킷·terraform state 불변.
#  (3) bucket/endpoint는 라이브 ObjectStore에서 읽어 하드코딩하지 않는다.
#  (4) R2 평문 키는 디스크에 닿지 않는다(kubectl go-template → rclone env).
#
# 사용:
#   scripts/reset-pg-r2-archive.sh            # dry-run: pg/ 범위만 출력
#   scripts/reset-pg-r2-archive.sh --purge    # 실제 purge + 아카이빙 재개 확인 (파괴적)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/infra/k3s-bootstrap/kubeconfig}"
NS=database
OBJSTORE=pg-r2
SERVER=pg

purge=0
[ "${1:-}" = "--purge" ] && purge=1

command -v rclone >/dev/null 2>&1 || { echo "FATAL: rclone가 PATH에 없다" >&2; exit 2; }

# bucket/endpoint를 라이브 ObjectStore CR에서 도출한다 (하드코딩 회피).
dest="$(kubectl -n "$NS" get objectstore "$OBJSTORE" -o jsonpath='{.spec.configuration.destinationPath}')"
ep="$(kubectl -n "$NS" get objectstore "$OBJSTORE" -o jsonpath='{.spec.configuration.endpointURL}')"
bucket="${dest#s3://}"
bucket="${bucket%%/*}"
{ [ -n "$bucket" ] && [ -n "$ep" ]; } || { echo "FATAL: ObjectStore $OBJSTORE에서 bucket/endpoint를 못 읽음" >&2; exit 1; }

# R2 자격증명(라이브 secret) → rclone env. 평문 키는 출력하지 않는다.
AWS_ACCESS_KEY_ID="$(kubectl -n "$NS" get secret cnpg-r2-creds -o go-template='{{index .data "AWS_ACCESS_KEY_ID" | base64decode}}')"
AWS_SECRET_ACCESS_KEY="$(kubectl -n "$NS" get secret cnpg-r2-creds -o go-template='{{index .data "AWS_SECRET_ACCESS_KEY" | base64decode}}')"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ENV_AUTH=true
export RCLONE_CONFIG_R2_ENDPOINT="$ep"
export RCLONE_CONFIG_R2_REGION=auto
# R2 Object R&W 토큰은 HeadBucket을 거부한다 — 버킷 존재 체크를 끈다.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

prefix="r2:${bucket}/${SERVER}/"
echo "==> bucket=${bucket} serverName=${SERVER} endpoint=${ep}"
echo "==> 대상(삭제 후보): ${prefix} (base/+wals/) — pgdump/·타 버킷은 보존"
rclone size "$prefix" 2>/dev/null | grep -iE 'objects|size' || echo "    (이미 비어 있음/없음)"

if [ "$purge" -eq 0 ]; then
  echo "==> DRY-RUN. 실제로 정리하려면 --purge를 붙여 다시 실행하라."
  exit 0
fi

echo "==> PURGE ${prefix}"
rclone purge "$prefix"
echo "==> pgdump/ 보존 확인"
rclone size "r2:${bucket}/pgdump/" 2>/dev/null | grep -iE 'objects' || echo "    (pgdump/ 없음)"

echo "==> 아카이버 견인 (WAL switch)"
kubectl -n "$NS" exec "${SERVER}-1" -c postgres -- psql -U postgres -c "CHECKPOINT; SELECT pg_switch_wal()" >/dev/null 2>&1 || true

echo "==> ContinuousArchiving=True 대기 (max ~60s)"
arch=""
for _ in $(seq 1 12); do
  arch="$(kubectl -n "$NS" get cluster "$SERVER" -o jsonpath='{range .status.conditions[?(@.type=="ContinuousArchiving")]}{.status}{end}' 2>/dev/null || true)"
  echo "    ContinuousArchiving=${arch:-<none>}"
  [ "$arch" = "True" ] && break
  sleep 5
done
[ "$arch" = "True" ] || { echo "WARN: ContinuousArchiving이 아직 True가 아니다 — pg-1 로그를 확인하라" >&2; exit 1; }
echo "OK: serverName=${SERVER} 아카이브 리셋 완료 — 아카이빙 재개됨."
