#!/usr/bin/env bats
# sealing key 백업 체인 — DR 게이트.
# 불변식: 컨트롤러 sealing key 없이는 git의 SealedSecret을 아무도 복호화 못 한다.
# 백업은 (1) 평문을 디스크에 남기지 않고 (2) 실패 시 직전 백업을 파괴하지 않으며(원자적)
# (3) git 밖에만 보관된다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$ROOT/scripts/backup-sealed-secrets-key.sh"
  TMP="$(mktemp -d)"
  STUB="$TMP/bin"
  mkdir -p "$STUB" "$TMP/out"
}
teardown() { rm -rf "$TMP"; }

# 스텁: kubectl은 가짜 키 Secret을 내보내고, sops는 base64로 "암호화"한다(평문 grep 차단).
make_stubs() { # $1 = sops 동작: ok | fail
  cat > "$STUB/kubectl" <<'EOF'
#!/bin/sh
printf 'kind: Secret\ndata:\n  tls.key: PLAINTEXT-MARKER\n'
EOF
  if [ "$1" = ok ]; then
    cat > "$STUB/sops" <<'EOF'
#!/bin/sh
if [ "$1" = "-d" ]; then exec base64 -d < "$2"; fi
exec base64
EOF
  else
    cat > "$STUB/sops" <<'EOF'
#!/bin/sh
exit 1
EOF
  fi
  chmod +x "$STUB/kubectl" "$STUB/sops"
}

@test "backup script exists and is executable" {
  [ -x "$S" ]
}

@test "backup refuses an output dir inside the git work tree" {
  make_stubs ok
  PATH="$STUB:$PATH" run "$S" "$ROOT/scripts"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "git"
}

@test "failed encryption leaves the previous backup intact and no plaintext on disk" {
  make_stubs fail
  printf 'OLD-BACKUP' > "$TMP/out/ss-keys.111.enc.yaml"
  PATH="$STUB:$PATH" run "$S" "$TMP/out"
  [ "$status" -ne 0 ]
  # 직전 백업 무손상 (truncate/덮어쓰기 금지)
  [ "$(cat "$TMP/out/ss-keys.111.enc.yaml")" = "OLD-BACKUP" ]
  # 평문/임시파일 잔존 0
  run grep -r "PLAINTEXT-MARKER" "$TMP/out"
  [ "$status" -ne 0 ]
  run ls "$TMP/out"/ss-keys.tmp.*
  [ "$status" -ne 0 ]
}

@test "successful backup writes a versioned file, decrypt-verified, previous kept" {
  make_stubs ok
  printf 'OLD-BACKUP' > "$TMP/out/ss-keys.111.enc.yaml"
  PATH="$STUB:$PATH" run "$S" "$TMP/out"
  [ "$status" -eq 0 ]
  # 버전드: 기존 + 신규 = 2개 (덮어쓰기 아님)
  [ "$(ls -1 "$TMP/out"/ss-keys.*.enc.yaml | wc -l | tr -d ' ')" = "2" ]
  [ "$(cat "$TMP/out/ss-keys.111.enc.yaml")" = "OLD-BACKUP" ]
  # 신규 백업은 평문이 아니어야 한다 (스텁 암호화 통과 확인)
  run grep -r "PLAINTEXT-MARKER" "$TMP/out"
  [ "$status" -ne 0 ]
}

@test "restore runbook documents the sealing key recovery path (local only)" {
  # 런북은 로컬 전용(gitignored) — CI에는 없으므로 존재할 때만 검증
  [ -d "$ROOT/docs/runbooks" ] || skip "no local runbooks"
  run grep -qi "sealing key" "$ROOT/docs/runbooks/restore.md"
  [ "$status" -eq 0 ]
}
