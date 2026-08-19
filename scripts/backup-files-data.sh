#!/usr/bin/env bash
# files-data 오프-매체 rsync 백업 (H2/M14 — files는 git+R2+age 재구축 불변식의 유일 예외).
#
# > 리눅스 재작성 2026-08-19. 이전 판은 **macOS/OrbStack 시대** 문서이자 코드였다 —
# > 매체 판별이 `diskutil Device Location == Internal`이었고, source 경로에
# > `${vmpath#/mnt/mac}`(OrbStack VM → 호스트 /Volumes) 변환이 박혀 있었으며,
# > 배선이 레포 밖 launchd plist였다. NUC엔 `diskutil`도 launchd도 없어 **하드 실패**했다.
#
# 왜: bulk-ssd의 files-data PV는 Retain·Prune=false·관측으로 오삭제/침묵유실은 막지만
# **매체 자체가 죽으면 전손**이다. 다른 물리 디스크로 rsync해 매체 유실에 대비한다.
# R2 미사용(무료티어)이라 이 호스트 사본이 유일한 2차 매체다.
#
# 🔴 **매체 판별을 "내장이냐"에서 "source와 dest가 다른 물리 디스크냐"로 바꿨다.**
#    macOS 판은 `Internal`을 요구했는데, 그건 "외장 SSD가 bulk"라는 **그 시절 배치의 우연**이지
#    불변식이 아니다. 지키려던 것은 처음부터 **사본이 원본과 다른 매체에 있다**는 것이고,
#    레포도 SSOT에 그렇게 못박았다(versions.env: "국면의 구별은 경로가 아니라 디바이스 정체성").
#    국면 B에서는 배치가 뒤집힌다 — source=별도 SSD(/mnt/bulk), dest=내장 루트. `Internal` 요구를
#    그대로 옮겼다면 **정확히 거꾸로** 걸렸을 것이다.
#
# 불변식: (1) source=라이브 files/files-data PV 호스트 경로(kubectl claimRef 파생).
#   (2) dest=**source와 다른 물리 디스크**(같은 디스크면 거부 — 같은 매체 사본은 무의미).
#       판별은 `findmnt --target` → 백킹 디바이스 → `lsblk -nso … --raw`로 TYPE=disk까지 거슬러 올라간다.
#       ⚠️ 파일시스템 동일성(st_dev)으로 판별하면 **같은 디스크의 다른 파티션**을 통과시킨다 — 매체
#          유실에 함께 죽는 배치라 정확히 막아야 할 것을 놓친다. 그래서 물리 디스크까지 간다.
#       ⚠️ 판별 실패는 '안전'이 아니라 '판정 불가'다 — fail-loud(레포 규약: dr-drill/destroy-node와 동형).
#   (3) 성공 시 sha256 매니페스트 + files_backup_last_success_timestamp·용량을 vmsingle에 push(r4 게이트).
#   (4) fail-loud: source 파생 실패·dest 동일 디스크·rsync 실패는 비-0 종료. push 실패는 WARN(신선도 알림이 backstop).
#
# 사용:
#   scripts/backup-files-data.sh <dest(source와 다른 디스크, git 밖)>   # 백업 + 매니페스트 + 메트릭 push
#   scripts/backup-files-data.sh --dry-run <dest>                      # rsync -n (무변경, push 없음)
#   scripts/backup-files-data.sh --verify  <dest>                      # 최신 백업서 전수 복원 + sha256 대조(매체 판독성 게이트)
#
# 배선: `host-config/etc/systemd/system/files-data-backup.{service,timer}` (일1회, RPO=24h).
# ⚠️ **국면 A에서는 이 스크립트가 의도적으로 거부한다.** NUC은 디스크가 하나이고 `/mnt/bulk`는
#    루트 LV의 bind라 source와 dest가 같은 물리 매체다. 그 상태로 타이머를 켜면 알림은 초록이
#    되지만 사본은 같은 매체에 놓인다(**정직한 red보다 나쁜 false-green**).
#    그래서 유닛 파일은 **설치만 되고 enable되지 않는다**(`host-config.sh --apply`는 enable하지 않는다).
#    국면 B(별도 SSD를 /mnt/bulk에 마운트) 이후 `systemctl enable --now files-data-backup.timer`가
#    배선의 마지막 한 줄이다. 그때까지 `FilesBackupStale`의 absent 가지는 한시 억제돼 있고,
#    `tests/gates/test_files-backup-phase-a.bats`가 창을 비우는 순간 억제 제거를 강제한다.
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
latest_manifest() { find "$dest" -maxdepth 1 -name 'files-data.*.sha256' 2>/dev/null | LC_ALL=C sort | tail -1; }

# --- --verify: 최신 매니페스트의 '모든' 항목을 복원 위치서 판독해 sha256 전수 재대조 ---
# 첫 항목만 검사하면 나머지 파일 손상/삭제를 놓친다(내용-인지 검증 — 매체 판독성 게이트).
if [ "$MODE" = verify ]; then
  man="$(latest_manifest)"; [ -n "$man" ] || { echo "ERROR: 매니페스트 없음 — 먼저 백업 생성" >&2; exit 1; }
  [ -s "$man" ] || { echo "ERROR: 매니페스트 비어있음: $man" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  n=0
  # IFS-보존 파싱: 'read -r want rel'(기본 IFS)은 선두 공백을 먹어 ' <경로>'(빈 해시) 행을 rel='' 로
  # 읽고 조용히 skip(전수 대조 취지 위반 false-green). want=첫 공백 앞, rel=첫 공백 뒤로 잘라 선두/후행
  # 공백 파일명도 보존한다. 공백 없는 행(want==line)이나 빈 해시/경로는 손상 매니페스트 — fail-loud.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    want="${line%% *}"; rel="${line#* }"
    if [ "$want" = "$line" ] || [ -z "$want" ] || [ -z "$rel" ]; then
      echo "ERROR: 매니페스트 손상 행(해시/경로 파싱 실패): '$line' — 백업 무결성 의심" >&2; exit 1
    fi
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
  # ⚠️ **jq를 먼저 본다** — 이 스크립트는 systemd timer가 **root로** 돌린다. NUC 실측(2026-08-19):
  #    root PATH에 `yq`가 없다(mise shim은 ukyi 전용이라 root에서 "not a valid shim"으로 죽는다).
  #    `jq`는 `/usr/bin/jq`로 전역 설치돼 있다. 배선 시 정확히 여기서 물리므로 순서가 계약이다.
  _jsonq=""
  if command -v jq >/dev/null 2>&1; then _jsonq=jq
  elif command -v yq >/dev/null 2>&1; then _jsonq=yq
  else echo "ERROR: jq/yq 둘 다 부재 — source PV 파생 불가" >&2; exit 2; fi
  # ⚠️ `.status.phase=="Bound"`가 **계약이다.** Retain 정책 PV는 Released가 돼도 claimRef를 그대로
  #    들고 있어서, claimRef만 보는 셀렉터에는 **고아 PV가 함께 걸린다**(같은 클러스터 실측 2026-08-19:
  #    database/pg-1에 Released 4 + Bound 1, 클러스터 전체 고아 9건). 고아의 hostPath 디렉토리는
  #    디스크에 실재하므로 아래 `[ -d ]`도 그대로 통과하고, 그러면 **엉뚱한 옛 데이터를 백업하면서**
  #    사본↔사본을 대조하는 `--verify`는 초록으로 지나간다 — 어느 가드도 못 잡는다.
  #    (이 커밋에서 $vmpath가 매체 판정의 절반(phys_disk(source))으로 승격돼 더 load-bearing해졌다.)
  # ⚠️ `head -1`로 접지 마라. 후보가 2개 이상이면 진실은 "어느 게 맞는지 모른다"이고, 조용히 첫 줄을
  #    고르는 건 판정 불가를 성공으로 위장하는 것이다. 세어서 요란하게 죽인다.
  _pvpaths="$(kubectl get pv -o json \
    | "$_jsonq" -r '.items[] | select(.status.phase=="Bound" and .spec.claimRef.namespace=="files" and .spec.claimRef.name=="files-data") | (.spec.hostPath.path // .spec.local.path // "")' \
    | grep . || true)"
  _pvn="$(printf '%s\n' "$_pvpaths" | grep -c . || true)"
  [ "${_pvn:-0}" -le 1 ] || {
    echo "ERROR: Bound인 files/files-data PV가 ${_pvn}건이다 — 어느 것이 source인지 판정 불가(추측 금지)." >&2
    printf '%s\n' "$_pvpaths" | sed 's/^/       후보: /' >&2
    exit 2
  }
  vmpath="$_pvpaths"
fi
[ -n "$vmpath" ] || { echo "ERROR: files/files-data PV 호스트 경로 파생 실패(바운드 PV 없음?)" >&2; exit 2; }
[ -d "$vmpath" ] || { echo "ERROR: source 디렉토리 부재: $vmpath" >&2; exit 2; }

# --- dest 매체 검사: source와 **다른 물리 디스크**여야 한다 ---
# 같은 디스크 위 사본은 매체 유실에 함께 죽으므로 백업이 아니다. 파일시스템 동일성이 아니라
# **물리 디스크 동일성**으로 판별한다 — 같은 디스크의 다른 파티션/LV도 거부해야 하기 때문이다.
for _c in findmnt lsblk; do
  command -v "$_c" >/dev/null 2>&1 || { echo "ERROR: ${_c} 부재 — 매체 판별 불가(판정 불가는 '안전'이 아니다)" >&2; exit 2; }
done
# 경로 → 백킹 물리 디스크 이름. bind 마운트의 `SOURCE[/subpath]` 표기에서 대괄호부를 떼고,
# LVM/파티션을 거슬러 올라가 TYPE=disk를 찾는다. `--raw`가 없으면 트리 문자(`\`-`)가 섞인다.
# ⚠️ 판별의 한계(정직하게 적어 둔다): (1) 조상 disk가 여럿인 구성(mdraid/multipath/여러 PV를 묶은
#    VG)에서는 첫 한 개로 접힌다 — 집합 disjoint가 아니라 첫 원소 동일성 비교다. (2) 같은 물리
#    매체의 서로 다른 TYPE=disk 이름(NVMe 다중 네임스페이스, multipath 개별 경로)은 "다른 디스크"로
#    통과한다. 둘 다 이 노드엔 존재하지 않고(단일 NVMe·컨트롤러 1·네임스페이스 1) 국면 B 계획
#    (`docs/runbooks/external-ssd.md` §2: 새 M.2를 **직접** /mnt/bulk에 마운트)에도 없다.
#    그 구성을 도입한다면 이 함수부터 집합 비교로 바꿔라.
phys_disk() {
  local _p="$1" _src _d
  _src="$(findmnt -no SOURCE --target "$_p" 2>/dev/null | sed 's/\[.*//')" || return 1
  [ -n "$_src" ] || return 1
  _d="$(lsblk -nso NAME,TYPE --raw "$_src" 2>/dev/null | awk '$2 == "disk" { print $1; exit }')" || return 1
  [ -n "$_d" ] || return 1
  printf '%s' "$_d"
}
src_disk="$(phys_disk "$vmpath" || true)"
dst_disk="$(phys_disk "$dest" || true)"
[ -n "$src_disk" ] || { echo "ERROR: source($vmpath)의 백킹 물리 디스크를 판별하지 못했다 — 매체 분리를 단언할 수 없다" >&2; exit 2; }
[ -n "$dst_disk" ] || { echo "ERROR: dest($dest)의 백킹 물리 디스크를 판별하지 못했다 — 매체 분리를 단언할 수 없다" >&2; exit 2; }
if [ "$src_disk" = "$dst_disk" ]; then
  echo "ERROR: source와 dest가 **같은 물리 디스크**다(${src_disk}) — 같은 매체 사본은 매체 유실에 함께 죽는다." >&2
  echo "       source=$vmpath  dest=$dest" >&2
  echo "       국면 A(bulk가 루트 LV의 bind)에서는 이것이 정상 거동이다 — 국면 B(별도 SSD를 /mnt/bulk에" >&2
  echo "       마운트) 이후에 실행하라. 지금 억지로 돌리면 알림만 초록이 되고 사본은 같은 디스크에 놓인다." >&2
  exit 1
fi
echo "==> 매체 분리 확인: source=${src_disk} · dest=${dst_disk}"

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
# ⚠️ 프로세스 치환(< <(...))으로 while을 메인 셸에서 돌린다 — 파이프(| while)면 루프가 서브셸이라
#    빈 해시 발각 시 exit이 서브셸만 죽이고 스크립트는 계속 진행한다(fail-loud 무력). sha256 실패/빈 출력은
#    ' <경로>'(빈 해시) 행을 남겨 --verify 전수 대조를 조용히 통과시키므로(false-green) 즉시 중단한다.
man="$dest/files-data.$(date +%s).sha256"
: > "$man"
while IFS= read -r f; do
  rel="${f#./}"
  h="$(sha256 "$dest/data.new/$rel" | awk '{print $1}')" || h=""
  [ -n "$h" ] || { echo "ERROR: sha256 계산 실패($rel) — 매니페스트 무결성 훼손, 승격 중단" >&2; rm -f "$man"; rm -rf "$dest/data.new"; exit 1; }
  printf '%s %s\n' "$h" "$rel" >> "$man"
done < <(cd "$dest/data.new" && find . -type f -print)
[ -s "$man" ] || { echo "ERROR: 매니페스트 비어있음 — 승격 중단" >&2; rm -f "$man"; rm -rf "$dest/data.new"; exit 1; }

# --- 4) 승격(rotate): 직전 스냅샷 1개(data.prev) 보존 ---
rm -rf "$dest/data.prev"
if [ -d "$dest/data" ]; then mv "$dest/data" "$dest/data.prev"; fi
mv "$dest/data.new" "$dest/data"
echo "==> 승격 완료: $man (${new_count}개 파일, 직전 스냅샷 data.prev 보존, RPO=24h)"

# --- 성공/용량 메트릭 push (FilesBackupStale·FilesBulkSSDLow 게이트) ---
push_metrics() {
  local url="$1" avail size payload ts
  # ✅ **2026-08-19: 여기 있던 fail-loud 갭을 닫았다.** 이전 판은 `${avail:-0}`/`${size:-0}` 폴백으로
  #    df가 실패해도 **0을 실은 채** 성공 하트비트를 함께 발행했다. 그러면
  #      · FilesBackupStale  → 초록 (하트비트가 나갔으므로)
  #      · FilesBulkSSDLow   → avail=0이 흘러들어 "여유 0%"로 **오귀속 페이지**
  #      · size까지 0이면 0/0=NaN이라 반대로 **침묵**
  #    이 되어, 진실("df가 실패했다")이 어느 쪽으로도 드러나지 않았다.
  #    ⚠️ 읽는 쪽(r4 expr)에 absent()나 `size > 0` 가드를 다는 우회는 여전히 금지다 — 전자는
  #    FilesBackupStale와 중복 페이지, 후자는 **진짜 결핍(avail=0)**까지 억제해 알림을 죽인다.
  #    처방은 주석 자신이 적어 둔 대로 **쓰는 쪽에서 검증**하는 것이다:
  #      값이 온전하면 3줄 전부, 아니면 **하트비트만** 보내고 용량은 아예 안 보낸다(+ 요란한 WARN).
  #      백업은 실제로 성공했으므로 하트비트는 참이고, 모르는 값을 지어내지 않는다.
  avail="$(df -k "$vmpath" 2>/dev/null | awk 'NR == 2 { print $4 * 1024 }')"
  size="$(df -k "$vmpath" 2>/dev/null | awk 'NR == 2 { print $2 * 1024 }')"
  # ⚠️ 형태가 **계약이다** — `OUT="${OUT}<이름> ${VAL}\n"` + `printf '%b'`.
  #    (a) 명령 치환으로 조립하면(`payload="$(printf '…\n')"`) 후행 개행이 벗겨져 다음 메트릭과
  #        **붙어버린다**(`…timestamp 1755600000files_data_bulk_avail_bytes 100`). 그러면 하트비트가
  #        파싱되지 않아 백업이 성공해도 FilesBackupStale이 영원히 발화한다.
  #    (b) 진짜 개행을 문자열에 넣으면 `check-alert-rules.ts`의 정적 추출기(EXPO_INLINE)가 못 읽어
  #        "push 페이로드를 정적으로 해석할 수 없다"로 **fail-closed FAIL**이 난다(모드 C).
  #    둘 다 실측으로 밟았다(2026-08-19). 리터럴 `\n` + `%b`가 두 요구를 동시에 만족하는 유일한 형태이고,
  #    digest-exporter가 같은 이유로 같은 형태를 쓴다.
  #    ⚠️ 값도 `${VAR}`나 숫자여야 한다 — `$(date …)`를 값 자리에 두면 추출기가 못 읽는다
  #       (EXPO_INLINE의 값 토큰은 `%fmt`·`$var`·숫자다. `$(`는 매치하지 않는다 — 실측).
  ts="$(date -u +%s)"
  payload="files_backup_last_success_timestamp ${ts}\n"
  # 숫자인가(빈 값·비숫자 거부) → size > 0인가. 둘 다 통과할 때만 용량을 싣는다.
  if ! printf '%s' "$avail" | grep -qE '^[0-9]+$' || ! printf '%s' "$size" | grep -qE '^[0-9]+$'; then
    echo "WARN: df 파싱 실패(avail='${avail}' size='${size}') — 용량 메트릭을 **보내지 않는다**." >&2
    echo "      0을 지어내면 FilesBulkSSDLow가 '여유 0%'로 오귀속 페이지를 낸다. 백업 자체는 성공했다." >&2
  elif [ "$size" -le 0 ]; then
    echo "WARN: df가 size=0을 보고했다 — 용량 메트릭을 보내지 않는다(0/0=NaN이 알림을 침묵시킨다)." >&2
  else
    payload="${payload}files_data_bulk_avail_bytes ${avail}\n"
    payload="${payload}files_data_bulk_size_bytes ${size}\n"
  fi
  # `%b`가 리터럴 `\n`을 실제 개행으로 편다 — 마지막 줄도 개행으로 끝난다(exposition 규약).
  printf '%b' "$payload" | curl -fsS --data-binary @- "${url}/api/v1/import/prometheus"
}
if [ -n "$PUSHGW" ]; then
  push_metrics "$PUSHGW" || echo "WARN: 메트릭 push 실패($PUSHGW) — FilesBackupStale가 페이징할 것(백업 자체는 성공)" >&2
else
  # 호스트→클러스터: vmsingle는 ClusterIP라 port-forward 경유(노드 호스트는 *.home을 안 푼다 —
  # resolved의 DNS=는 공인 리졸버이고 AdGuard의 split-horizon을 타지 않는다).
  kubectl -n "$PF_NS" port-forward "svc/$PF_SVC" "$PF_PORT:$PF_PORT" >/dev/null 2>&1 &
  pf=$!; trap 'kill "$pf" 2>/dev/null || true' EXIT
  for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$PF_PORT/health" >/dev/null 2>&1 && break; sleep 0.5; done
  push_metrics "http://127.0.0.1:$PF_PORT" || echo "WARN: 메트릭 push 실패(port-forward) — FilesBackupStale가 페이징할 것(백업 자체는 성공)" >&2
fi
echo "OK: files-data 백업 완료 → $dest/data (오프-SSD 사본, RPO=24h)"
