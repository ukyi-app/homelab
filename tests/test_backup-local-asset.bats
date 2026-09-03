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
# ⚠️ 거부 레인이 레포 루트를 밟는다 — 그 경로가 곧 이 스위트의 산출물이므로 정리도 여기 몫이다.
#    (스크립트가 자기 부작용을 걷게 고쳤어도 teardown은 남긴다: 회귀하면 8개가 다시 쌓인다.)
teardown() { rm -rf "$STUBDIR" "$OUT" "$ROOT/scratch_backup_$$"; }

@test "usage error when outdir missing" {
  # ⚠️ `-ne 0`만으로는 「usage로 거부했다」와 「스크립트가 없어 못 돌았다」가 겹친다
  #    (실측: 스크립트 삭제 시 3레인 중 이 레인만 그대로 초록). usage 문구로 가른다.
  [ -f "$ROOT/scripts/backup-local-asset.sh" ]
  run scripts/backup-local-asset.sh
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'usage: backup-local-asset.sh'
}

@test "refuses an outdir inside the git work tree and leaves nothing behind" {
  run scripts/backup-local-asset.sh "$ROOT/scratch_backup_$$"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "git 작업트리"
  # 부작용 부재 증인 — 거부가 자기 `mkdir -p`를 되돌린다. 이 한 줄이 없던 동안 이 @test가
  # 실행 횟수만큼 레포 루트에 빈 700 디렉토리를 쌓았다(발견 시점 8개).
  [ ! -d "$ROOT/scratch_backup_$$" ]
}

@test "errors when runbooks are absent (owner-only)" {
  # fresh-checkout엔 docs/runbooks 부재 — CI/러너에서 loud하게(fail-closed)
  [ -d "$ROOT/docs/runbooks" ] && skip "런북 실재(owner 머신) — 부재 케이스 검증 불가"
  run scripts/backup-local-asset.sh "$OUT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "런북 부재"
}
