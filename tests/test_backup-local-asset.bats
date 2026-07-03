#!/usr/bin/env bats
# backup-local-asset 로직 가드(hermetic — sops stub). 실 age 왕복은 owner-local DR 드릴. ⚠️ [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STUBDIR="$(mktemp -d)"; PATH="$STUBDIR:$PATH"; export PATH STUBDIR
  cat >"$STUBDIR/sops" <<'EOF'
#!/usr/bin/env bash
# encrypt: stdin→stdout 그대로; decrypt(-d): 그대로 되돌림(왕복 항등 stub)
cat
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
