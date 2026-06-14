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
# 파일 인자는 항상 마지막 위치 — binary 모드 플래그(--input-type 등)가 끼어도 견고
if [ "$1" = "-d" ]; then for f in "$@"; do :; done; exec base64 -d < "$f"; fi
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

@test "sealed_consumers_count_local is zero on empty repo" {
  REPO="$TMP/repo-empty"; mkdir -p "$REPO"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  run sealed_consumers_count_local "$REPO"; [ "$status" -eq 0 ]; [ "$output" = "0" ]
}
@test "consumers_from_ref parses ns/name and returns 0 on a clean parse" {
  REPO="$TMP/repo-ref"; mkdir -p "$REPO/apps/foo/deploy/prod"
  printf 'kind: SealedSecret\nmetadata:\n  name: foo-secrets\n  namespace: prod\n' > "$REPO/apps/foo/deploy/prod/foo-secrets.sealed.yaml"
  (cd "$REPO" && git init -q && git add -A && git commit -q -m seed)
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  run consumers_from_ref "$REPO" "HEAD"; [ "$status" -eq 0 ]
  echo "$output" | grep -q "prod/foo-secrets"
}
@test "consumers_from_ref fails closed on malformed metadata" {
  REPO="$TMP/repo-bad"; mkdir -p "$REPO/apps/bad/deploy/prod"
  printf 'kind: SealedSecret\nmetadata:\n  name: bad\n' > "$REPO/apps/bad/deploy/prod/bad.sealed.yaml"  # namespace 누락
  (cd "$REPO" && git init -q && git add -A && git commit -q -m seed)
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  run consumers_from_ref "$REPO" "HEAD"; [ "$status" -ne 0 ]
}
@test "merge_consumers unions ref and live without duplicates" {
  REPO="$TMP/repo-m"; mkdir -p "$REPO/apps/a/deploy/prod"
  printf 'kind: SealedSecret\nmetadata:\n  name: a-secrets\n  namespace: prod\n' > "$REPO/apps/a/deploy/prod/a-secrets.sealed.yaml"
  (cd "$REPO" && git init -q && git add -A && git commit -q -m seed)
  printf '#!/bin/sh\nprintf "prod/a-secrets\\nedge/live-only\\n"\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run merge_consumers "$REPO" "HEAD"; [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" = "2" ]
  echo "$output" | grep -q "prod/a-secrets"; echo "$output" | grep -q "edge/live-only"
}

@test "before-destroy aborts on n=0 with committed cert but no backup dir" {
  REPO="$TMP/repo-cert0"; mkdir -p "$REPO/tools"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  printf 'CERT\n' > "$REPO/tools/sealed-secrets-cert.pem"
  printf '#!/bin/sh\nexit 0\n' > "$STUB/kubectl"  # live 0
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = fetch ] && exit 0; done\nexec /usr/bin/git "$@"\n' > "$STUB/git"
  chmod +x "$STUB/kubectl" "$STUB/git"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run assert_recoverable_before_destroy "$REPO" "" "HEAD"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "키 연속성 필요"
}
@test "before-destroy fails closed when live lookup fails" {
  REPO="$TMP/repo-fc"; mkdir -p "$REPO"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  printf '#!/bin/sh\nexit 7\n' > "$STUB/kubectl"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = fetch ] && exit 0; done\nexec /usr/bin/git "$@"\n' > "$STUB/git"
  chmod +x "$STUB/kubectl" "$STUB/git"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run assert_recoverable_before_destroy "$REPO" "" "HEAD"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "fail-closed"
}
@test "assert_dr_tools_present aborts when a tool is missing" {
  printf '#!/bin/sh\nexit 0\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB" run assert_dr_tools_present
  [ "$status" -ne 0 ]; echo "$output" | grep -q "도구 부재"
}
@test "cert check fails loudly when committed cert mismatches live" {
  REPO="$TMP/repo-c"; mkdir -p "$REPO/tools"; printf 'COMMITTED\n' > "$REPO/tools/sealed-secrets-cert.pem"
  printf '#!/bin/sh\necho LIVE\n' > "$STUB/kubeseal"
  cat > "$STUB/openssl" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -in) echo "Fingerprint=COMMITTED"; exit 0;; esac; done
echo "Fingerprint=LIVE"; exit 0
EOF
  chmod +x "$STUB/kubeseal" "$STUB/openssl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run assert_committed_cert_matches_live "$REPO"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "stale"
}
@test "prove_backup_restorable fails when key modulus does not match the matching cert" {
  REPO="$TMP/repo-pb"; mkdir -p "$REPO/tools" "$TMP/bk"; printf 'COMMITTED\n' > "$REPO/tools/sealed-secrets-cert.pem"
  printf 'dummy' > "$TMP/bk/ss-keys.111.enc.yaml"
  printf '#!/bin/sh\nprintf "apiVersion: v1\\nkind: List\\nitems:\\n- kind: Secret\\n  data:\\n    tls.crt: QQ==\\n    tls.key: Qg==\\n"\n' > "$STUB/sops"
  # openssl: committed cert fp == 백업 crt fp(일치) 이나 modulus는 crt=MODA, key=MODB(불일치)
  cat > "$STUB/openssl" <<'EOF'
#!/bin/sh
kind=x509; for a in "$@"; do [ "$a" = rsa ] && kind=rsa; done
case "$*" in
  *-fingerprint*) echo "Fingerprint=SAME"; exit 0;;
  *-modulus*) if [ "$kind" = rsa ]; then echo "Modulus=MODB"; else echo "Modulus=MODA"; fi; exit 0;;
esac
exit 0
EOF
  printf '#!/bin/sh\ncat\n' > "$STUB/base64"   # base64 -d 패스스루(테스트 단순화)
  chmod +x "$STUB/sops" "$STUB/openssl" "$STUB/base64"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run prove_backup_restorable "$REPO" "$TMP/bk"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "키쌍"
}
@test "verify_all fails closed when live lookup fails" {
  REPO="$TMP/repo-vf"; mkdir -p "$REPO"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  printf '#!/bin/sh\ncase "$*" in *"get sealedsecrets"*) exit 9;; esac\nexit 0\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run verify_all_sealedsecrets_unsealed "$REPO" "HEAD"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "fail-closed"
}
@test "verify_all iterates every consumer and fails on a missing Secret" {
  REPO="$TMP/repo-v"; mkdir -p "$REPO/apps/a/deploy/prod" "$REPO/apps/b/deploy/prod"
  printf 'kind: SealedSecret\nmetadata:\n  name: a-secrets\n  namespace: prod\n' > "$REPO/apps/a/deploy/prod/a-secrets.sealed.yaml"
  printf 'kind: SealedSecret\nmetadata:\n  name: b-secrets\n  namespace: prod\n' > "$REPO/apps/b/deploy/prod/b-secrets.sealed.yaml"
  (cd "$REPO" && git init -q && git add -A && git commit -q -m seed)
  cat > "$STUB/kubectl" <<'EOF'
#!/bin/sh
case "$*" in *"get sealedsecrets"*) exit 0;; esac
last=""; for a in "$@"; do last="$a"; done
case "$last" in a-secrets) exit 0;; *) exit 1;; esac
EOF
  chmod +x "$STUB/kubectl"
  export SEALED_UNSEAL_RETRIES=1  # UNSEAL_RETRIES는 source 시점에 평가되므로 source 전에 export해야 반영된다
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run verify_all_sealedsecrets_unsealed "$REPO" "HEAD"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "a-secrets"; echo "$output" | grep -q "b-secrets 미생성"
}
@test "rehearse_restore_on_live fails when backup List server-dry-run apply fails" {
  REPO="$TMP/repo-rh"; mkdir -p "$REPO/tools" "$TMP/bk"; printf 'CERT\n' > "$REPO/tools/sealed-secrets-cert.pem"
  printf 'dummy' > "$TMP/bk/ss-keys.111.enc.yaml"
  printf '#!/bin/sh\ncat\n' > "$STUB/sops"
  printf '#!/bin/sh\ncase "$*" in *"--dry-run=server"*) exit 1;; esac\nexit 0\n' > "$STUB/kubectl"
  chmod +x "$STUB/sops" "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run rehearse_restore_on_live "$REPO" "$TMP/bk"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "dry-run apply 실패"
}
@test "sanitize_backup_yaml strips server-managed metadata (P5-3)" {
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  out="$(printf 'apiVersion: v1\nkind: List\nitems:\n- kind: Secret\n  metadata:\n    name: k\n    namespace: sealed-secrets\n    uid: u1\n    resourceVersion: "9"\n    managedFields: [{manager: x}]\n  data: {tls.key: QQ==}\n' | sanitize_backup_yaml)"
  echo "$out" | grep -q "name: k"
  run bash -c "printf '%s' \"$out\" | grep -E 'uid:|resourceVersion:|managedFields:'"
  [ "$status" -ne 0 ]   # 서버관리 메타 0건
}
@test "verify_all stays fail-closed even with SEALED_DR_ALLOW_OFFLINE=1 (P5-1)" {
  REPO="$TMP/repo-vfo"; mkdir -p "$REPO"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  printf '#!/bin/sh\ncase "$*" in *"get sealedsecrets"*) exit 9;; esac\nexit 0\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" SEALED_DR_ALLOW_OFFLINE=1 run verify_all_sealedsecrets_unsealed "$REPO" "HEAD"
  [ "$status" -ne 0 ]
}
