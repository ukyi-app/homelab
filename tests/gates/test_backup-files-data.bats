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
  # diskutil: 기본 Internal(허용). DISKUTIL_EXTERNAL=1 이면 External(dest 거부 케이스).
  cat >"$STUB/diskutil" <<'EOF'
#!/usr/bin/env bash
[ "$1" = info ] && { [ "${DISKUTIL_EXTERNAL:-0}" = 1 ] && echo "   Device Location: External" || echo "   Device Location: Internal"; }
exit 0
EOF
  # rsync 스텁: 실제 복사(--dry-run이면 미복사)로 매니페스트 경로를 커버.
  cat >"$STUB/rsync" <<'EOF'
#!/usr/bin/env bash
dry=0; for a in "$@"; do [ "$a" = "--dry-run" ] && dry=1; done
s="${@: -2:1}"; d="${@: -1}"
[ "$dry" = 1 ] && exit 0
mkdir -p "$d"; cp -a "$s". "$d" 2>/dev/null || cp -a "$s"/. "$d"; exit 0
EOF
  # curl 스텁: RSYNC_PUSH_FAIL=1 이면 push 실패(백업은 그래도 성공해야 함).
  cat >"$STUB/curl" <<'EOF'
#!/usr/bin/env bash
[ "${CURL_PUSH_FAIL:-0}" = 1 ] && exit 22
cat >/dev/null 2>&1; exit 0
EOF
  chmod +x "$STUB"/{diskutil,rsync,curl}
}
teardown() { rm -rf "$STUB" "$DEST" "$SRC"; }

@test "backup stages, promotes, and writes a sha256 manifest, then exits 0" {
  run bash "$S" "$DEST"; [ "$status" -eq 0 ]
  [ -f "$DEST/data/a.txt" ]
  run bash -c "ls '$DEST'/files-data.*.sha256"; [ "$status" -eq 0 ]
  run bash -c "ls -d '$DEST/data.new'"; [ "$status" -ne 0 ]   # 스테이징 잔재 없음
}
@test "REFUSES an external-disk dest (media-loss copy is useless)" {
  DISKUTIL_EXTERNAL=1 run bash "$S" "$DEST"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "매체 유실 무방비"
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
@test "passes shellcheck" { run shellcheck "$S"; [ "$status" -eq 0 ]; }
