#!/usr/bin/env bash
# DR 보조 도구 (④): fresh initdb 클러스터(새 system ID)가 R2의 옛 barman 아카이브와 충돌해
# ContinuousArchiving이 깨질 때, **그 클러스터가 쓰는** serverName의 아카이브(base/+wals/)만
# 정리해 아카이빙을 재개시킨다. 재구축 후 prod에 복구할 실데이터가 없을 때의 정본 리셋 절차(2026-06-14 드릴 검증).
#
# 안전 설계:
#  (1) 기본은 dry-run(범위만 출력, 삭제 안 함) — 실제 삭제는 --purge가 필요하다.
#  (2) **이 클러스터가 실제로 쓰는** serverName 프리픽스만 건드린다 — pgdump/ 헤지·타 버킷·tf state 불변.
#  (3) bucket/endpoint **와 serverName**을 라이브에서 읽어 하드코딩하지 않는다. serverName을 박아두면
#      NUC에서 실행할 때 라이브 Mac의 prefix를 지운다(R2 버저닝 없음 = 되돌릴 수 없음).
#  (4) R2 평문 키는 디스크에 닿지 않는다(kubectl go-template → rclone env).
#  (5) 다른 클러스터의 아카이브를 지우려면 PG_ARCHIVE_SERVER + --purge-foreign **둘 다** 필요하다.
#
# 사용:
#   scripts/reset-pg-r2-archive.sh            # dry-run: 이 클러스터의 아카이브 범위만 출력
#   scripts/reset-pg-r2-archive.sh --purge    # 실제 purge + 아카이빙 재개 확인 (파괴적)
#   PG_ARCHIVE_SERVER=pg scripts/reset-pg-r2-archive.sh --purge --purge-foreign
#                                             # PONR 1: Mac 시대 아카이브 정리 (계획서 §0)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/infra/k3s-bootstrap/kubeconfig}"
NS=database
OBJSTORE=pg-r2
# ⚠️ **k8s Cluster 이름과 아카이브 serverName은 다른 것이다.** 예전엔 `SERVER` 하나가 셋을 겸직했다
#    (R2 prefix · 파드 이름 `${SERVER}-1` · Cluster 이름). NUC 이전에서 그 겸직이 깨졌다 —
#    NUC의 k8s Cluster는 `pg`인데 아카이브는 `pg-nuc`다(계획서 §3.4 병렬 운용 분리).
CLUSTER="${PG_CLUSTER:-pg}"

purge=0
purge_foreign=0
for _a in "$@"; do
  case "$_a" in
    --purge) purge=1 ;;
    --purge-foreign) purge_foreign=1 ;;
    *) echo "FATAL: 알 수 없는 인자 '${_a}' (사용법: $0 [--purge] [--purge-foreign])" >&2; exit 2 ;;
  esac
done

command -v rclone >/dev/null 2>&1 || { echo "FATAL: rclone가 PATH에 없다" >&2; exit 2; }
command -v kubectl >/dev/null 2>&1 || { echo "FATAL: kubectl이 PATH에 없다" >&2; exit 2; }

# ⚠️ **아카이브 serverName을 하드코딩하지 않는다** — 라이브 Cluster에서 파생한다. 이 스크립트가
#    bucket/endpoint에 대해 이미 지키는 원칙(:9 "하드코딩 회피")과 같은 규칙이다.
#    하드코딩하면 NUC에서 실행할 때 **라이브 Mac의 prefix를 지운다**(R2에 버저닝 없음 = 되돌릴 수 없음).
SERVER="$(kubectl -n "$NS" get cluster "$CLUSTER" \
  -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}' 2>/dev/null || true)"
[ -n "$SERVER" ] \
  || { echo "FATAL: Cluster ${CLUSTER}(ns ${NS})에서 아카이브 serverName을 파생하지 못했다 — 어느 prefix를 지울지 알 수 없으므로 중단한다" >&2; exit 1; }

# 명시 override는 **다른 클러스터의 아카이브를 지우는 행위**다(예: PONR 1에서 Mac의 `pg/` 정리).
# 사고로 일어나서는 안 되므로 전용 플래그를 하나 더 요구한다.
if [ -n "${PG_ARCHIVE_SERVER:-}" ] && [ "$PG_ARCHIVE_SERVER" != "$SERVER" ]; then
  [ "$purge_foreign" -eq 1 ] || {
    echo "FATAL: PG_ARCHIVE_SERVER='${PG_ARCHIVE_SERVER}'가 이 클러스터의 아카이브('${SERVER}')와 다르다." >&2
    echo "       남의 아카이브를 지우는 행위다. 의도했다면 --purge-foreign을 함께 줄 것." >&2
    exit 1
  }
  echo "WARN: FOREIGN PURGE — 이 클러스터('${SERVER}')가 아니라 '${PG_ARCHIVE_SERVER}'를 대상으로 한다." >&2
  SERVER="$PG_ARCHIVE_SERVER"
fi

# bucket/endpoint를 라이브 ObjectStore CR에서 도출한다 (하드코딩 회피).
dest="$(kubectl -n "$NS" get objectstore "$OBJSTORE" -o jsonpath='{.spec.configuration.destinationPath}')"
ep="$(kubectl -n "$NS" get objectstore "$OBJSTORE" -o jsonpath='{.spec.configuration.endpointURL}')"
bucket="${dest#s3://}"
bucket="${bucket%%/*}"
{ [ -n "$bucket" ] && [ -n "$ep" ]; } || { echo "FATAL: ObjectStore ${OBJSTORE}에서 bucket/endpoint를 못 읽음" >&2; exit 1; }

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
echo "==> bucket=${bucket} k8s-cluster=${CLUSTER} archive-serverName=${SERVER} endpoint=${ep}"
echo "==> 대상(삭제 후보): ${prefix} (base/+wals/) — 다른 top-level prefix·타 버킷은 보존"
rclone size "$prefix" 2>/dev/null | grep -iE 'objects|size' || echo "    (이미 비어 있음/없음)"

if [ "$purge" -eq 0 ]; then
  echo "==> DRY-RUN. 실제로 정리하려면 --purge를 붙여 다시 실행하라."
  exit 0
fi

echo "==> PURGE ${prefix}"
rclone purge "$prefix"
echo "==> 보존 확인 — purge 대상 외 top-level prefix가 그대로인가"
# 특정 이름을 하드코딩하지 않는다: 남아 있는 prefix 전부를 찍어 사람이 눈으로 대조한다.
# (pgdump/ = restore.md 경로 B, 별개 오프사이트. purge는 barman PITR 경로만 지운다.)
rclone lsf --dirs-only "r2:${bucket}/" 2>/dev/null | sed 's/^/    남음: /' || echo "    (열거 실패)"

echo "==> 아카이버 견인 (WAL switch)"
kubectl -n "$NS" exec "${CLUSTER}-1" -c postgres -- psql -U postgres -c "CHECKPOINT; SELECT pg_switch_wal()" >/dev/null 2>&1 || true

echo "==> ContinuousArchiving=True 대기 (max ~60s)"
arch=""
for _ in $(seq 1 12); do
  arch="$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{range .status.conditions[?(@.type=="ContinuousArchiving")]}{.status}{end}' 2>/dev/null || true)"
  echo "    ContinuousArchiving=${arch:-<none>}"
  [ "$arch" = "True" ] && break
  sleep 5
done
[ "$arch" = "True" ] || { echo "WARN: ContinuousArchiving이 아직 True가 아니다 — pg-1 로그를 확인하라" >&2; exit 1; }
echo "OK: archive serverName=${SERVER} (k8s cluster ${CLUSTER}) 리셋 완료 — 아카이빙 재개됨."
