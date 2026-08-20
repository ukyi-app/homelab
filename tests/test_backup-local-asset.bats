#!/usr/bin/env bats
# backup-local-asset 로직 가드(hermetic — sops stub). 실 age 왕복은 owner-local DR 드릴. ⚠️ [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STUBDIR="$(mktemp -d)"; PATH="$STUBDIR:$PATH"; export PATH STUBDIR
  cat >"$STUBDIR/sops" <<'EOF'
#!/usr/bin/env bash
# 왕복 항등 stub — **입력원은 argv가 정한다**(파일 인자는 항상 마지막 위치).
# 호출부 3곳이 전부 마지막 위치에 피연산자를 준다: backup-local-asset.sh:34 `-d … "$latest"`,
# :50 encrypt `… --output-type binary /dev/stdin`, :52 `-d … "$tmp"`.
# ⚠️ 본문이 피연산자 없는 `cat`이면 :34/:52는 파이프의 첫 명령이라 먹일 stdin이 없다 — 실패가 아니라
#    **hang**이다(호출자의 fd 0에서 EOF를 기다린다). 같은 클래스를 test_sealed-secrets-restore.bats가
#    실측으로 밟았다(rc=124).
for f in "$@"; do :; done
exec cat "$f"
EOF
  chmod +x "$STUBDIR/sops"
  OUT="$(mktemp -d)"   # git 밖
}
teardown() { rm -rf "$STUBDIR" "$OUT"; }

@test "usage error when outdir missing" {
  run scripts/backup-local-asset.sh
  [ "$status" -ne 0 ]
}

@test "refuses an outdir inside the git work tree" {
  run scripts/backup-local-asset.sh "$ROOT/scratch_backup_$$"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "git 작업트리"
}

@test "errors when runbooks are absent (owner-only)" {
  # fresh-checkout엔 docs/runbooks 부재 — CI/러너에서 loud하게(fail-closed)
  [ -d "$ROOT/docs/runbooks" ] && skip "런북 실재(owner 머신) — 부재 케이스 검증 불가"
  run scripts/backup-local-asset.sh "$OUT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "런북 부재"
}
