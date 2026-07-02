#!/usr/bin/env bash
# files-data 오프-SSD rsync 백업 (H2/M14 — files는 git+R2+age 재구축 불변식의 유일 예외).
#
# 왜: bulk-ssd(외장 SSD) files-data PV는 Retain·Prune=false·관측으로 오삭제/침묵유실은 막지만
# 매체(SSD) 자체가 죽으면 전손이다. files-data를 Mac 내장 디스크(오프-SSD 사본)로 rsync해 매체
# 유실에 대비한다. R2 미사용(무료티어)이라 이 호스트 사본이 유일한 2차 매체다.
#
# 불변식: (1) source=라이브 files/files-data PV 호스트 경로(kubectl claimRef 파생; VM /mnt/mac* → 호스트 /Volumes*).
#   (2) dest=반드시 내장 디스크(외장이면 거부 — 같은 매체 사본 무의미, diskutil Device Location).
#   (3) 성공 시 sha256 매니페스트 + files_backup_last_success_timestamp·용량을 vmsingle에 push(r4 게이트).
#   (4) fail-loud: source 파생 실패·dest 외장·rsync 실패는 비-0 종료. push 실패는 WARN(신선도 알림이 backstop).
#
# 사용:
#   scripts/backup-files-data.sh <dest(내장 디스크, git 밖)>      # 백업 + 매니페스트 + 메트릭 push
#   scripts/backup-files-data.sh --dry-run <dest>                # rsync -n (무변경, push 없음)
#   scripts/backup-files-data.sh --verify  <dest>                # 최신 백업서 파일 1개 복원 + sha256 대조(매체 판독성 게이트)
# launchd 배선(일1회, RPO=24h)은 owner-local — docs/runbooks/external-ssd.md.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODE=backup
case "${1:-}" in
  --dry-run) MODE=dryrun; shift ;;
  --verify)  MODE=verify; shift ;;
esac
dest="${1:?usage: backup-files-data.sh [--dry-run|--verify] <dest(내장 디스크, git 밖)>}"
mkdir -p "$dest"; dest="$(cd "$dest" && pwd)"

export KUBECONFIG="${KUBECONFIG:-$ROOT/infra/k3s-bootstrap/kubeconfig}"
PUSHGW="${METRICS_PUSH_URL:-}"   # 비면 vmsingle로 port-forward. 셋이면 그 URL로 직접 push.
PF_NS=observability; PF_SVC=vmsingle; PF_PORT=8428

sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
# find로 최신 매니페스트 선택(SC2012 회피 — ls 대신 find + sort). 파일명은 epoch 정렬 안전.
latest_manifest() { find "$dest" -maxdepth 1 -name 'files-data.*.sha256' 2>/dev/null | sort | tail -1; }

# --- --verify: 최신 매니페스트의 '모든' 항목을 복원 위치서 판독해 sha256 전수 재대조 ---
# 첫 항목만 검사하면 나머지 파일 손상/삭제를 놓친다(내용-인지 검증 — 매체 판독성 게이트).
if [ "$MODE" = verify ]; then
  man="$(latest_manifest)"; [ -n "$man" ] || { echo "ERROR: 매니페스트 없음 — 먼저 백업 생성" >&2; exit 1; }
  [ -s "$man" ] || { echo "ERROR: 매니페스트 비어있음: $man" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  n=0
  while read -r want rel; do
    [ -n "${rel:-}" ] || continue
    n=$((n + 1))
    file="$dest/data/$rel"; [ -f "$file" ] || { echo "ERROR: 백업에 파일 부재: $rel" >&2; exit 1; }
    cp "$file" "$tmp/restored"                      # 복원 시뮬레이션(매체서 판독)
    got="$(sha256 "$tmp/restored" | awk '{print $1}')"
    [ "$got" = "$want" ] || { echo "ERROR: 복원 sha256 불일치($rel): want=$want got=$got — 백업 매체 손상 의심" >&2; exit 1; }
  done < "$man"
  [ "$n" -gt 0 ] || { echo "ERROR: 매니페스트에 유효 항목 없음: $man" >&2; exit 1; }
  echo "OK: --verify 통과(${n}개 파일 복원+sha256 일치, $man)"
  exit 0
fi

# --- source 파생: files/files-data PV 호스트 경로 ---
vmpath="${FILES_DATA_HOST_PATH:-}"
if [ -z "$vmpath" ]; then
  command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl 부재 — source PV 파생 불가" >&2; exit 2; }
  command -v yq >/dev/null 2>&1 || { echo "ERROR: yq 부재" >&2; exit 2; }
  vmpath="$(kubectl get pv -o json \
    | yq -r '.items[] | select(.spec.claimRef.namespace=="files" and .spec.claimRef.name=="files-data") | (.spec.hostPath.path // .spec.local.path // "")' \
    | head -1 || true)"
  vmpath="${vmpath#/mnt/mac}"                      # VM /mnt/mac/Volumes/... → 호스트 /Volumes/...
fi
[ -n "$vmpath" ] || { echo "ERROR: files/files-data PV 호스트 경로 파생 실패(바운드 PV 없음?)" >&2; exit 2; }
[ -d "$vmpath" ] || { echo "ERROR: source 디렉토리 부재: $vmpath" >&2; exit 2; }

# --- dest 매체 검사: 반드시 내장 디스크(외장 SSD 사본은 매체 유실 무방비) ---
command -v diskutil >/dev/null 2>&1 || { echo "ERROR: diskutil 부재 — dest 매체 판별 불가" >&2; exit 2; }
loc="$(diskutil info "$dest" 2>/dev/null | awk -F': *' '/Device Location/{print $2}' | tr -d '[:space:]' || true)"
[ "$loc" = "Internal" ] || { echo "ERROR: dest($dest) Device Location='${loc:-?}' — 외장 SSD 위 사본은 매체 유실 무방비. 내장 디스크 경로를 쓰라." >&2; exit 1; }

if [ "$MODE" = dryrun ]; then
  echo "==> DRY-RUN rsync $vmpath/ → $dest/data.new/ (스테이징 — 승격 없음)"
  rsync -a --dry-run "$vmpath/" "$dest/data.new/"
  exit 0
fi

# --- 1) 스테이징: 기존 사본($dest/data)에 직접 --delete 금지 ---
# 소스가 빈 상태(잘못된 PV 재바인딩·빈 카탈로그)면 --delete가 유일한 오프-SSD 사본을
# 그대로 비워버린다(침묵 유실 전파). 스테이징 → sanity → 승격(rotate)로만 반영한다.
rm -rf "$dest/data.new"
if [ -d "$dest/data" ]; then
  rsync -a --link-dest="$dest/data" "$vmpath/" "$dest/data.new/"   # 불변 파일은 hardlink(공간 절약)
else
  rsync -a "$vmpath/" "$dest/data.new/"
fi

# --- 2) 승격 전 sanity: 비어있지 않음 + 급감 가드 ---
new_count="$(find "$dest/data.new" -type f | wc -l | tr -d ' ')"
[ "$new_count" -gt 0 ] || { echo "ERROR: 스테이징 0파일($vmpath 소스 비어있음?) — 승격 중단, 기존 사본 보존. PV 재바인딩/빈 카탈로그 의심." >&2; rm -rf "$dest/data.new"; exit 1; }
if [ -d "$dest/data" ]; then
  old_count="$(find "$dest/data" -type f | wc -l | tr -d ' ')"
  if [ "$old_count" -gt 0 ] && [ $((new_count * 2)) -lt "$old_count" ] && [ "${FORCE_SHRINK:-0}" != 1 ]; then
    echo "ERROR: 파일 수 급감($old_count → $new_count, >50% 축소) — 승격 중단, 기존 사본 보존. 의도된 대량 삭제면 FORCE_SHRINK=1로 재실행." >&2
    rm -rf "$dest/data.new"; exit 1
  fi
fi

# --- 3) sha256 매니페스트: 스테이징 기준, 승격 전 생성 ('<sha> <상대경로>' — 복원 검증 입력) ---
man="$dest/files-data.$(date +%s).sha256"
: > "$man"
( cd "$dest/data.new" && find . -type f -print ) | while IFS= read -r f; do
  printf '%s %s\n' "$(sha256 "$dest/data.new/${f#./}" | awk '{print $1}')" "${f#./}" >> "$man"
done
[ -s "$man" ] || { echo "ERROR: 매니페스트 비어있음 — 승격 중단" >&2; rm -f "$man"; rm -rf "$dest/data.new"; exit 1; }

# --- 4) 승격(rotate): 직전 스냅샷 1개(data.prev) 보존 ---
rm -rf "$dest/data.prev"
if [ -d "$dest/data" ]; then mv "$dest/data" "$dest/data.prev"; fi
mv "$dest/data.new" "$dest/data"
echo "==> 승격 완료: $man (${new_count}개 파일, 직전 스냅샷 data.prev 보존, RPO=24h)"

# --- 성공/용량 메트릭 push (FilesBackupStale·FilesBulkSSDLow 게이트) ---
push_metrics() {
  local url="$1" avail size
  avail="$(df -k "$vmpath" 2>/dev/null | awk 'NR==2{print $4*1024}')"   # 외장 SSD 여유 bytes
  size="$(df -k "$vmpath" 2>/dev/null | awk 'NR==2{print $2*1024}')"    # 총량 bytes
  printf 'files_backup_last_success_timestamp %s\nfiles_data_bulk_avail_bytes %s\nfiles_data_bulk_size_bytes %s\n' \
    "$(date -u +%s)" "${avail:-0}" "${size:-0}" \
    | curl -fsS --data-binary @- "${url}/api/v1/import/prometheus"
}
if [ -n "$PUSHGW" ]; then
  push_metrics "$PUSHGW" || echo "WARN: 메트릭 push 실패($PUSHGW) — FilesBackupStale가 페이징할 것(백업 자체는 성공)" >&2
else
  # 호스트→클러스터: vmsingle는 ClusterIP라 port-forward 경유(이 Mac은 *.home 미해석).
  kubectl -n "$PF_NS" port-forward "svc/$PF_SVC" "$PF_PORT:$PF_PORT" >/dev/null 2>&1 &
  pf=$!; trap 'kill "$pf" 2>/dev/null || true' EXIT
  for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$PF_PORT/health" >/dev/null 2>&1 && break; sleep 0.5; done
  push_metrics "http://127.0.0.1:$PF_PORT" || echo "WARN: 메트릭 push 실패(port-forward) — FilesBackupStale가 페이징할 것(백업 자체는 성공)" >&2
fi
echo "OK: files-data 백업 완료 → $dest/data (오프-SSD 사본, RPO=24h)"
