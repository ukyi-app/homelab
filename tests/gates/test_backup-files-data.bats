#!/usr/bin/env bats
# backup-files-data.sh 헤르메틱 가드(스텁으로 밀폐). @test 이름은 영어. ⚠️ 중간 부정 단언은 run+[ ]로만.
S="scripts/backup-files-data.sh"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  STUB="$(mktemp -d)"; DEST="$(mktemp -d)"; SRC="$(mktemp -d)"
  PATH="$STUB:$PATH"; export PATH STUB DEST SRC
  echo "hello-files" > "$SRC/a.txt"; mkdir -p "$SRC/sub"; echo "beta" > "$SRC/sub/b.txt"
  export FILES_DATA_HOST_PATH="$SRC"          # kubectl 파생 우회(테스트 밀폐)
  export METRICS_PUSH_URL="http://127.0.0.1:59999"   # push 대상 스텁(비면 port-forward 경로)
  # 매체 판별 스텁(2026-08-19 리눅스 재작성): diskutil이 아니라 findmnt+lsblk를 밀폐한다.
  # 기본은 source/dest가 **다른 물리 디스크**(허용). 노브 둘:
  #   SAME_DISK=1     → 둘 다 같은 디스크 (거부돼야 정상 — 국면 A가 정확히 이 상태다)
  #   RESOLVE_FAIL=1  → findmnt가 빈 출력 (판정 불가 → 거부돼야 정상, '안전'으로 읽으면 안 된다)
  cat >"$STUB/findmnt" <<'EOF'
#!/usr/bin/env bash
[ "${RESOLVE_FAIL:-0}" = 1 ] && exit 0
t=""; while [ "$#" -gt 0 ]; do [ "$1" = "--target" ] && { t="$2"; break; }; shift; done
if [ "${SAME_DISK:-0}" = 1 ]; then echo "/dev/samedisk1"; exit 0; fi
# ⚠️ **dest 기준**으로 가른다(source 기준이 아니라). source 경로는 테스트마다 다르다 —
#    빈-소스 케이스가 별도 mktemp를 쓰므로, source 접두로 가르면 그게 dest와 같은 디스크로
#    잡혀 매체 검사에서 먼저 걸리고 정작 검증하려던 승격 가드에 도달하지 못한다.
case "$t" in "$DEST"*) echo "/dev/dstdisk1" ;; *) echo "/dev/srcdisk1" ;; esac
EOF
  # lsblk -nso NAME,TYPE --raw <dev> → `<disk> disk` 한 줄(파티션 접미 1을 떼 디스크명을 만든다)
  cat >"$STUB/lsblk" <<'EOF'
#!/usr/bin/env bash
d=""; for a in "$@"; do d="$a"; done
b="$(basename "$d")"; b="${b%1}"
printf '%s disk\n' "$b"
EOF
  # rsync 스텁: 실제 복사(--dry-run이면 미복사)로 매니페스트 경로를 커버.
  cat >"$STUB/rsync" <<'EOF'
#!/usr/bin/env bash
dry=0; for a in "$@"; do [ "$a" = "--dry-run" ] && dry=1; done
s="${@: -2:1}"; d="${@: -1}"
[ "$dry" = 1 ] && exit 0
mkdir -p "$d"; cp -a "$s". "$d" 2>/dev/null || cp -a "$s"/. "$d"; exit 0
EOF
  # curl 스텁: CURL_PUSH_FAIL=1 이면 push 실패(백업은 그래도 성공해야 함).
  # ⚠️ **stdin을 버리지 않고 $DEST/pushed.txt에 남긴다.** 이전 스텁은 `cat >/dev/null`이라
  #    payload 형태를 아무도 안 봤고, 그 사이 명령 치환이 개행을 먹어 두 메트릭이 붙어버린
  #    fatal 버그가 12/12 초록을 통과했다(2026-08-19 적대 검증이 잡았다).
  #    스텁이 관대하면 그 스텁이 지키는 것이 없다.
  cat >"$STUB/curl" <<'EOF'
#!/usr/bin/env bash
[ "${CURL_PUSH_FAIL:-0}" = 1 ] && { cat >/dev/null 2>&1; exit 22; }
cat > "${DEST}/pushed.txt" 2>/dev/null || cat >/dev/null 2>&1
exit 0
EOF
  chmod +x "$STUB"/{findmnt,lsblk,rsync,curl}
}
teardown() { rm -rf "$STUB" "$DEST" "$SRC"; }

@test "backup stages, promotes, and writes a sha256 manifest, then exits 0" {
  run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  [ -f "$DEST/data/a.txt" ]
  run bash -c "ls '$DEST'/files-data.*.sha256"; [ "$status" -eq 0 ]
  run bash -c "ls -d '$DEST/data.new'"; [ "$status" -ne 0 ]   # 스테이징 잔재 없음
}
@test "REFUSES a dest on the SAME physical disk as the source (media-loss copy is useless)" {
  # 🔴 macOS 판은 `diskutil Device Location == Internal`을 요구했다. 그건 "외장 SSD가 bulk"라는
  #    그 시절 배치의 우연이지 불변식이 아니다 — 국면 B에서는 배치가 뒤집혀(source=별도 SSD,
  #    dest=내장 루트) 그 요구가 **정확히 거꾸로** 걸린다. 불변식은 처음부터 "다른 매체"였다.
  SAME_DISK=1 run bash "$S" "$DEST"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "같은 물리 디스크"
}
@test "REFUSES when the backing disk cannot be resolved (unknown is not safe)" {
  # 판정 불가를 '안전'으로 읽으면 tmpfs·미지원 매체에서 조용히 같은-매체 사본을 만든다.
  # 레포 규약(dr-drill/destroy-node의 findmnt 부재 처리)과 동형으로 fail-loud.
  RESOLVE_FAIL=1 run bash "$S" "$DEST"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "판별하지 못했다"
}
@test "--dry-run makes no changes and pushes no metric" {
  run bash "$S" --dry-run "$DEST"; [ "$status" -eq 0 ]
  run bash -c "ls '$DEST'/files-data.*.sha256 2>/dev/null"; [ "$status" -ne 0 ]
}
@test "--verify restores one file and passes sha256, fails on corruption" {
  bash "$S" "$DEST" >/dev/null
  run bash "$S" --verify "$DEST"; [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--verify 통과"
  # 손상 주입: 백업 파일 1개 변조 → --verify FAIL
  echo tampered >> "$DEST/data/a.txt"
  run bash "$S" --verify "$DEST"; [ "$status" -ne 0 ]
  echo "$output" | grep -q "sha256 불일치"
}
@test "EMPTY source aborts promotion and preserves the previous copy" {
  bash "$S" "$DEST" >/dev/null                       # 1차 백업으로 사본 확보
  EMPTY="$(mktemp -d)"
  FILES_DATA_HOST_PATH="$EMPTY" run bash "$S" "$DEST"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "승격 중단"
  [ -f "$DEST/data/a.txt" ]                          # 기존 사본 무손상
  rm -rf "$EMPTY"
}
@test "sharp shrink aborts unless FORCE_SHRINK=1, which promotes and keeps data.prev" {
  for i in 1 2 3 4 5; do echo "f$i" > "$SRC/f$i.txt"; done
  bash "$S" "$DEST" >/dev/null                       # 7파일 백업
  rm -f "$SRC"/f*.txt "$SRC/sub/b.txt"               # 7→1 급감
  run bash "$S" "$DEST"; [ "$status" -ne 0 ]
  echo "$output" | grep -q "급감"
  [ -f "$DEST/data/f1.txt" ]                         # 승격 중단 — 기존 사본 유지
  FORCE_SHRINK=1 run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  [ -f "$DEST/data.prev/f1.txt" ]                    # 직전 스냅샷 보존
}
@test "metric push failure does NOT fail the backup (staleness alert is the backstop)" {
  CURL_PUSH_FAIL=1 run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  echo "$output" | grep -q "WARN: 메트릭 push 실패"
}
@test "fails loud when the source path does not exist" {
  FILES_DATA_HOST_PATH="/no/such/dir" run bash "$S" "$DEST"; [ "$status" -ne 0 ]
}
@test "manifest generation fails loud on an empty sha256 (no silent empty-hash rows), no promotion" {
  # shasum 스텁: 빈 출력·성공 종료 → 해시 계산이 '성공했으나 값이 빈' 병리 케이스 재현.
  # (STUB이 PATH 선두라 sha256() 의 command -v shasum 이 이 스텁을 집는다.)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/shasum"; chmod +x "$STUB/shasum"
  run bash "$S" "$DEST"; [ "$status" -ne 0 ]
  echo "$output" | grep -q "sha256 계산 실패"
  run bash -c "ls -d '$DEST/data.new' 2>/dev/null"; [ "$status" -ne 0 ]   # 스테이징 정리됨
  run bash -c "ls -d '$DEST/data' 2>/dev/null"; [ "$status" -ne 0 ]       # 승격 안 됨
}
@test "manifest round-trips filenames with leading/trailing spaces (IFS-preserving verify)" {
  printf 'spacey\n' > "$SRC/ leading.txt"        # 선두 공백 파일명
  printf 'spacey2\n' > "$SRC/trailing .txt"      # 후행 공백 파일명
  run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  run bash "$S" --verify "$DEST"; [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--verify 통과"
}
@test "passes shellcheck" { run shellcheck "$S"; [ "$status" -eq 0 ]; }

@test "the pushed payload is valid prometheus exposition (one metric per line, trailing newline)" {
  # 🔴 이 @test가 없어서 fatal이 통과했다. `payload="$(printf '…\n')"`는 명령 치환이 후행 개행을
  #    먹어 다음 메트릭과 **붙어버린다**(`…timestamp 1755600000files_data_bulk_avail_bytes 100`).
  #    그러면 하트비트가 파싱되지 않아 백업이 성공해도 FilesBackupStale이 영원히 발화한다 —
  #    이 스크립트가 막으려던 바로 그 거짓 red다.
  run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  [ -f "$DEST/pushed.txt" ]
  # 3줄: 하트비트 + avail + size. 각 줄이 `이름 값` 정확히 두 토막이어야 한다.
  n="$(grep -c . "$DEST/pushed.txt")"
  [ "$n" -eq 3 ]
  run grep -qE '^files_backup_last_success_timestamp [0-9]+$' "$DEST/pushed.txt"; [ "$status" -eq 0 ]
  run grep -qE '^files_data_bulk_avail_bytes [0-9]+$' "$DEST/pushed.txt"; [ "$status" -eq 0 ]
  run grep -qE '^files_data_bulk_size_bytes [0-9]+$' "$DEST/pushed.txt"; [ "$status" -eq 0 ]
  # 마지막 줄이 개행으로 끝나는가(exposition 규약) — 없으면 마지막 메트릭이 잘린다.
  run bash -c "[ -z \"\$(tail -c 1 '$DEST/pushed.txt')\" ]"; [ "$status" -eq 0 ]
}

@test "a broken df sends the heartbeat ALONE — it never fabricates a zero" {
  # 🔴 이 분기가 이 커밋이 새로 만든 계약인데 커버리지가 0이었다. 이전 판은 `${avail:-0}`/`${size:-0}`로
  #    **0을 지어내** FilesBulkSSDLow가 "여유 0%"로 오귀속 페이지를 내게 했다(진실은 "df가 실패했다").
  #    지금 계약: 값이 온전할 때만 용량 2줄, 아니면 **하트비트 1줄만** + 요란한 WARN, 종료코드는 0
  #    (백업 자체는 실제로 성공했으므로 하트비트는 참이다).
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/df"; chmod +x "$STUB/df"
  run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  echo "$output" | grep -q "df 파싱 실패"
  [ -f "$DEST/pushed.txt" ]
  n="$(grep -c . "$DEST/pushed.txt")"; [ "$n" -eq 1 ]
  run grep -qE '^files_backup_last_success_timestamp [0-9]+$' "$DEST/pushed.txt"; [ "$status" -eq 0 ]
  # ⚠️ rc 2(pushed.txt 부재/읽기불가)를 통과로 읽지 않는다 — `-ne 0`이면 push가 통째로 사라져도
  #   "용량 메트릭 없음"으로 읽혀 초록이다. 매치 없음은 정확히 rc=1. 위 두 줄(줄 수 + 하트비트
  #   매치)이 이 부정 단언의 양성 대조다.
  run grep -q 'files_data_bulk_' "$DEST/pushed.txt"; [ "$status" -eq 1 ]
}

@test "df reporting size=0 also drops the capacity metrics (0/0=NaN would silence the alert)" {
  printf '#!/usr/bin/env bash\nprintf "F 1K B A C M\\n/x 0 0 0 0%% /x\\n"\n' > "$STUB/df"; chmod +x "$STUB/df"
  run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  echo "$output" | grep -q "size=0"
  n="$(grep -c . "$DEST/pushed.txt")"; [ "$n" -eq 1 ]
  # 양성 대조 — 그 한 줄이 실제로 하트비트임을 본다. 없으면 아래 부정 단언이 "무엇이 남았는지"를
  # 묻지 않은 채 통과할 수 있다.
  run grep -qE '^files_backup_last_success_timestamp [0-9]+$' "$DEST/pushed.txt"; [ "$status" -eq 0 ]
  run grep -q 'files_data_bulk_' "$DEST/pushed.txt"; [ "$status" -eq 1 ]   # rc 2(대상 부재)를 통과로 읽지 않는다
}

@test "the source PV selector takes only Bound — a Retain orphan keeps both its claimRef and its directory" {
  # ⚠️ Retain PV는 Released가 돼도 claimRef를 그대로 들고 있다(같은 클러스터 실측 2026-08-19:
  #    database/pg-1에 Released 4 + Bound 1). claimRef만 보고 `head -1` 하면 고아를 고를 수 있고,
  #    고아 디렉토리는 디스크에 실재하므로 `[ -d ]`도 통과한다 → **엉뚱한 옛 데이터를 백업**하고
  #    사본↔사본을 대조하는 `--verify`는 초록으로 지나간다. 아래 JSON은 고아를 **먼저** 둔다 —
  #    `.status.phase=="Bound"` 필터를 지우면 이 @test가 즉시 문다.
  ORPH="$(mktemp -d)"; echo "stale-mac-era" > "$ORPH/old.txt"
  unset FILES_DATA_HOST_PATH
  cat > "$STUB/pv.json" <<EOF
{"items":[
 {"status":{"phase":"Released"},"spec":{"claimRef":{"namespace":"files","name":"files-data"},"hostPath":{"path":"$ORPH"}}},
 {"status":{"phase":"Bound"},"spec":{"claimRef":{"namespace":"files","name":"files-data"},"hostPath":{"path":"$SRC"}}}
]}
EOF
  printf '#!/usr/bin/env bash\ncat "$STUB/pv.json"\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
  run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  [ -f "$DEST/data/a.txt" ]
  run bash -c "[ ! -e '$DEST/data/old.txt' ]"; [ "$status" -eq 0 ]
  rm -rf "$ORPH"
}

@test "two Bound candidates are refused loudly — never a head -1 guess" {
  # 후보가 2개면 진실은 "어느 게 맞는지 모른다"다. 조용히 첫 줄을 고르는 건 판정 불가를 성공으로 위장하는 것.
  SRC2="$(mktemp -d)"; echo "other" > "$SRC2/a.txt"
  unset FILES_DATA_HOST_PATH
  cat > "$STUB/pv.json" <<EOF
{"items":[
 {"status":{"phase":"Bound"},"spec":{"claimRef":{"namespace":"files","name":"files-data"},"hostPath":{"path":"$SRC"}}},
 {"status":{"phase":"Bound"},"spec":{"claimRef":{"namespace":"files","name":"files-data"},"hostPath":{"path":"$SRC2"}}}
]}
EOF
  printf '#!/usr/bin/env bash\ncat "$STUB/pv.json"\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
  run bash "$S" "$DEST"; [ "$status" -eq 2 ]
  echo "$output" | grep -q "판정 불가"
  run bash -c "[ ! -e '$DEST/data' ]"; [ "$status" -eq 0 ]
  rm -rf "$SRC2"
}
