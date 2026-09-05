#!/usr/bin/env bats
# sealing key 백업 체인 — DR 게이트.
# 불변식: 컨트롤러 sealing key 없이는 git의 SealedSecret을 아무도 복호화 못 한다.
# 백업은 (1) 평문을 디스크에 남기지 않고 (2) 실패 시 직전 백업을 파괴하지 않으며(원자적)
# (3) git 밖에만 보관된다.
# ⚠️ 부재 단언 규약(`-eq 1` · 디렉토리·재귀 자리는 **비공허 바닥값 + 양성 대조**를 한 쌍으로)은
#    docs/traps-detail.md 「열거 붕괴 → vacuous green」 ③·③-a와 그 「처방(bats 부재 단언)」이 SSOT다.
#    이 파일 고유의 사정: 술어 `PLAINTEXT-MARKER`의 출처가 실 트리가 아니라 **로컬 스텁**이다 —
#    마커 문자열이 드리프트하면 바닥값은 그대로 초록인 채 "평문 0건"만 vacuous해지고, 그 손해
#    방향이 황금률 2(평문 시크릿)다. 그래서 양성 대조를 술어를 주조하는 자리(make_stubs)에 두어
#    스텁을 쓰는 모든 @test가 개별 실행(`bats -f`)에서도 술어 생존을 함께 증언하게 한다.
#    (그 배치는 정적 검출기도 읽는다 — `make_stubs`는 heredoc **밖**의 0열 함수 본문이라
#     check-bats-style이 파일 스코프 양성 대조로 집계한다. 실측: 그 한 줄만 지우면 아래 두
#     자리가 [ABS-REC]로 재검출된다.)
#    바닥값 증인은 각 콜사이트의 `[ -s … ]`다 — 열거 대상 디렉토리에 파일이 실재함을 잰다.
#    뮤테이션 실측(2026-08-31, 격리 트리): 피시험 스크립트에 `rm -f "$outdir"/*`를 넣고 형제
#    단언(내용 비교·건수 대조)을 지운 상태에서 `-s`만 남기면 두 @test가 **red**, 같은 조건에서
#    `-s`가 없던 착지 전 형태는 **green**이었다(`grep -r`이 빈 디렉토리에 rc 1을 내는 그 vacuity).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$ROOT/scripts/backup-sealed-secrets-key.sh"
  TMP="$(mktemp -d)"
  STUB="$TMP/bin"
  mkdir -p "$STUB" "$TMP/out"
  # CI 러너엔 전역 git identity가 없다 — 임시 repo의 git commit이 'Author identity unknown'(rc 128)으로
  # 깨지지 않게 이 스위트 한정 identity를 env로 공급(자기완결; activate-app.bats의 per-repo config와 동일 취지).
  export GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@homelab.test
  export GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@homelab.test
}
# ⚠️ 거부 레인 하나가 레포 루트를 밟는다 — 그 경로가 곧 이 스위트의 산출물이므로 정리도 여기 몫이다.
#    (스크립트가 자기 부작용을 걷게 고쳤어도 teardown은 남긴다: 회귀하면 실행 횟수만큼 다시 쌓인다.)
teardown() { rm -rf "$TMP" "$ROOT/scratch_ssk_$$"; }

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
  # 양성 대조 — 부재 단언이 쓰는 **같은 술어**가 스텁 산출물에는 실제로 매치한다.
  # 스텁이 마커를 다른 문자열로 바꾸면 여기서 red다(그게 없으면 아래 `grep -r … -eq 1`은
  # 술어가 죽었는지 평문이 없는지를 구별하지 못한다 — 바닥값만으론 못 보는 절반).
  # 파이프 종단이 아니라 **경로 피연산자**로 잰다(SSOT ③-b: 파이프 끝 grep은 부재의 rc 2가
  # 빈 stdin의 rc 1로 눌린다). 프로브는 $TMP/out 밖이라 아래 열거·건수 증인을 오염시키지 않는다.
  "$STUB/kubectl" > "$TMP/plaintext-probe"
  grep -q "PLAINTEXT-MARKER" "$TMP/plaintext-probe"
}

# 항등 패스스루 sops 스텁(리허설 경로 전용) — **입력원은 argv가 정한다.**
# 파일 인자는 항상 마지막 위치 — binary 모드 플래그(--input-type 등)가 끼어도 견고(위 ok 갈래와 같은 규약).
# ⚠️ 본문을 피연산자 없는 `cat`으로 되돌리면 argv를 무시하고 fd 0을 읽는다. 피시험 코드
#    (scripts/sealing-key-dr-gate.sh:121)는 **항상** 파일 인자를 주고 파이프로 먹이지 않으므로 그건
#    실패가 아니라 **hang**이다(실측 2026-08-20: never-EOF stdin에서 rc=124, TAP이 `1..1`에서 정지).
make_sops_passthrough_stub() {
  cat > "$STUB/sops" <<'EOF'
#!/bin/sh
for f in "$@"; do :; done
exec cat "$f"
EOF
  chmod +x "$STUB/sops"
}

@test "backup script exists and is executable" {
  [ -x "$S" ]
}

@test "backup refuses an output dir inside the git work tree" {
  make_stubs ok
  PATH="$STUB:$PATH" run "$S" "$ROOT/scripts"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "git"
  # 이 레인의 피연산자는 **기존** 디렉토리다 — 거부의 `rmdir … || true`가 비어 있지 않은 outdir을
  # 지키는 것을 증언한다(부재 경로 축은 아래 @test가 잰다).
  [ -d "$ROOT/scripts" ]
}

@test "backup refuses an outdir inside the git work tree and leaves nothing behind" {
  # ⚠️ 스크립트의 `mkdir -p`가 git-작업트리 판정보다 **앞**이다 — 거부하면서 거부 대상을 만들어
  #    두면 그 빈 700 디렉토리는 git에 안 보이고(추적 0) 발견 수단이 `ls`뿐인 무증인 잔여물이 된다.
  #    형제 backup-local-asset.sh에서 실제로 레포 루트에 8개가 그렇게 쌓인 뒤 발견된 클래스다.
  #    위 @test는 기존 디렉토리를 주므로(mkdir이 no-op) 이 축을 원리적으로 관측하지 못한다.
  make_stubs ok
  PATH="$STUB:$PATH" run "$S" "$ROOT/scratch_ssk_$$"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "git 작업트리"
  [ ! -d "$ROOT/scratch_ssk_$$" ]
}

@test "failed encryption leaves the previous backup intact and no plaintext on disk" {
  make_stubs fail
  printf 'OLD-BACKUP' > "$TMP/out/ss-keys.111.enc.yaml"
  PATH="$STUB:$PATH" run "$S" "$TMP/out"
  [ "$status" -ne 0 ]
  # 직전 백업 무손상 (truncate/덮어쓰기 금지)
  # `-s`가 **비공허 바닥값**이다 — 아래 `grep -r`의 피연산자 디렉토리에 파일이 실재함을 잰다
  # (빈 디렉토리 grep -r은 rc 1이라 무매치와 구별되지 않는다). 내용 비교는 무손상을 잰다:
  # 두 줄은 같은 뮤테이션(이 파일 소실)에서 함께 red이고, 앞줄이 그 근거를 **형태로** 낸다.
  [ -s "$TMP/out/ss-keys.111.enc.yaml" ]
  [ "$(cat "$TMP/out/ss-keys.111.enc.yaml")" = "OLD-BACKUP" ]
  # 평문/임시파일 잔존 0
  # 디렉토리 피연산자 — `-eq 1`이 경로 소실(rc 2)을 닫고, 비공허 바닥값은 바로 위 `-s`다.
  # 나머지 절반인 **양성 대조**는 make_stubs가 세운다(술어가 스텁 산출물에 실재함) —
  # 둘이 한 쌍이라야 이 자리가 닫힌다.
  run grep -r "PLAINTEXT-MARKER" "$TMP/out"
  [ "$status" -eq 1 ]
  # ⚠️ 이 자리는 `ls`로 `-eq 1`이 **원리적으로** 불가능하다 — 무매치 글롭과 대상 부재가 같은
  #    rc 2로 합쳐진다(기전·실측표는 SSOT의 `ls` 행). 그래서 rc를 고쳐 쓰는 대신 단언의 의도
  #    ('임시파일이 남지 않았다')를 그대로 재는 find로 옮긴다 — 부재 rc 1 / 무매치 rc 0 + 빈 출력.
  #    depth는 SSOT 예시(`-maxdepth 1`)와 달리 재귀로 둔다: 형제 `grep -r`과 도메인을 맞춰
  #    중첩된 평문 유출을 원리적으로 놓치지 않기 위해서다(mktemp는 outdir 직하에만 쓴다).
  #    rc와 출력을 **함께** 건다 — find의 rc 관례가 구현마다 갈려도 부재면 stderr가 $output에
  #    섞여 `-z`가 red를 낸다.
  run find "$TMP/out" -name 'ss-keys.tmp.*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "successful backup writes a versioned file, decrypt-verified, previous kept" {
  make_stubs ok
  printf 'OLD-BACKUP' > "$TMP/out/ss-keys.111.enc.yaml"
  PATH="$STUB:$PATH" run "$S" "$TMP/out"
  [ "$status" -eq 0 ]
  # 버전드: 기존 + 신규 = 2개 (덮어쓰기 아님)
  [ "$(ls -1 "$TMP/out"/ss-keys.*.enc.yaml | wc -l | tr -d ' ')" = "2" ]
  # `-s`가 **비공허 바닥값**이다 — 위 건수 대조와 같은 사실을 형태로 낸다(`[ "$(…)" = … ]`은
  # 커맨드 치환이라 정적으로 읽히지 않는다). 아래 `grep -r`의 피연산자에 파일이 실재한다.
  [ -s "$TMP/out/ss-keys.111.enc.yaml" ]
  [ "$(cat "$TMP/out/ss-keys.111.enc.yaml")" = "OLD-BACKUP" ]
  # 신규 백업은 평문이 아니어야 한다 (스텁 암호화 통과 확인)
  # 디렉토리 피연산자 — `-eq 1`이 경로 소실(rc 2)을 닫고, 비공허 바닥값은 바로 위 `-s`다.
  # 나머지 절반인 **양성 대조**는 make_stubs가 세운다 — 둘이 한 쌍이라야 이 자리가 닫힌다.
  run grep -r "PLAINTEXT-MARKER" "$TMP/out"
  [ "$status" -eq 1 ]
}

# --verify(키 회전 게이트, :47-59) 전용 스텁 — make_stubs(:36-62)의 kubectl 계약(고정 Secret YAML,
# 백업 **생성** axis)과 결이 달라 별도 함수로 둔다: 기존 5개 @test의 kubectl 계약을 건드리지 않는다.
# ⚠️ hermetic 스텁 스위트에서 --verify 비교 predicate를 실행하는 @test가 이 파일에 0건이었다
# (2026-09 뮤테이션 실측: :53 `!=`를 `=`로 반전해도 위 12개 @test 전건 그대로 ok — 유일한 실행처는
# 라이브 posture(tests/posture/test_dr-assets.bats)와 sealing-key-dr-gate.sh:79뿐이었다).
make_verify_stubs() { # $1 = 백업에 담을 키 이름들(공백 구분, "keyabc keydef" 형태) · 라이브는 keyabc+keydef 고정
  cat > "$STUB/kubectl" <<'EOF'
#!/bin/sh
printf 'sealed-secrets-keyabc\nsealed-secrets-keydef\n'
EOF
  chmod +x "$STUB/kubectl"
  # 기존 sops "ok" 스텁(make_stubs, :42-47)과 동일한 base64 -d 파일-인자 계약 — 재사용.
  cat > "$STUB/sops" <<'EOF'
#!/bin/sh
if [ "$1" = "-d" ]; then for f in "$@"; do :; done; exec base64 -d < "$f"; fi
exec base64
EOF
  chmod +x "$STUB/sops"
  names=""
  for k in $1; do names="${names}name: sealed-secrets-${k}
"; done
  printf '%s' "$names" | base64 > "$TMP/out/ss-keys.999.enc.yaml"
}

@test "--verify passes when the latest backup's key set matches the live sealing keys" {
  make_verify_stubs "keyabc keydef"
  PATH="$STUB:$PATH" run "$S" --verify "$TMP/out"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "일치"
}

@test "--verify FAILS when the backup's key set no longer matches live (rotation detection, DR gate)" {
  make_verify_stubs "keyabc"   # 라이브는 keyabc+keydef, 백업은 keyabc뿐 — 회전/누락 시뮬레이션
  PATH="$STUB:$PATH" run "$S" --verify "$TMP/out"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "회전 감지"
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
  # CI엔 kubeseal/sops 바이너리가 없다 — assert_dr_tools_present의 presence 체크용 스텁(이 경로는 미호출).
  printf '#!/bin/sh\nexit 0\n' > "$STUB/kubeseal"; printf '#!/bin/sh\nexit 0\n' > "$STUB/sops"
  chmod +x "$STUB/kubectl" "$STUB/git" "$STUB/kubeseal" "$STUB/sops"
  . "$ROOT/scripts/sealing-key-dr-gate.sh"
  PATH="$STUB:$PATH" run assert_recoverable_before_destroy "$REPO" "" "HEAD"
  [ "$status" -ne 0 ]; echo "$output" | grep -q "키 연속성 필요"
}
@test "before-destroy fails closed when live lookup fails" {
  REPO="$TMP/repo-fc"; mkdir -p "$REPO"; (cd "$REPO" && git init -q && git commit -q --allow-empty -m init)
  printf '#!/bin/sh\nexit 7\n' > "$STUB/kubectl"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = fetch ] && exit 0; done\nexec /usr/bin/git "$@"\n' > "$STUB/git"
  # CI엔 kubeseal/sops 바이너리가 없다 — assert_dr_tools_present의 presence 체크용 스텁(이 경로는 미호출).
  printf '#!/bin/sh\nexit 0\n' > "$STUB/kubeseal"; printf '#!/bin/sh\nexit 0\n' > "$STUB/sops"
  chmod +x "$STUB/kubectl" "$STUB/git" "$STUB/kubeseal" "$STUB/sops"
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
  make_sops_passthrough_stub
  printf '#!/bin/sh\ncase "$*" in *"--dry-run=server"*) exit 1;; esac\nexit 0\n' > "$STUB/kubectl"
  chmod +x "$STUB/kubectl"
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

@test "sealing-key-dr-gate is source-safe: no bash-only 'trap ... RETURN'" {
  # 이 파일은 스스로 sourceable lib이라 선언한다(sealing-key-dr-gate.sh:2). RETURN 트랩은 bash
  # 전용이라 zsh에서 source하면 `trap: undefined signal: RETURN`으로 등록 자체가 실패하고,
  # rehearse_restore_on_live가 만든 임시 ns(sealed-dr-rehearsal)가 클러스터에 조용히 남는다.
  # 실측 대조: zsh source → 잔류 / bash source → 정리. 이 호스트 기본 셸이 zsh이므로 사람이
  # 프롬프트에서 함수를 직접 부르는 경로가 정확히 그 조건이다. 정리는 명시 호출로만 한다.
  # 주석에서 이 함정을 설명하는 문장은 걸리면 안 되므로, 줄 머리의 실제 trap 문만 본다.
  # 파일 피연산자라 `-eq 1`이 리네임·삭제를 그대로 닫는다 — 실측: 이 스크립트를 리네임하면
  # `-ne 0` 형태는 ok(vacuous green)였고 `-eq 1`은 red다.
  run grep -nE '^[[:space:]]*trap[[:space:]].*RETURN' "$ROOT/scripts/sealing-key-dr-gate.sh"
  [ "$status" -eq 1 ]
}

@test "rehearse_restore_on_live cleans up on every exit path after ns creation" {
  # ns 생성 이후 이탈 경로는 실패 2 + 성공 1 = 3개다. 하나라도 빠지면 잔류한다.
  run bash -c "grep -c '_rehearsal_cleanup' '$ROOT/scripts/sealing-key-dr-gate.sh'"
  [ "$status" -eq 0 ]
  # 정의 1 + 호출 3 = 4 이상
  [ "$output" -ge 4 ]
}

# 스텁 계약 증인 — 헬퍼의 입력원이 **argv**임을 단언한다. stdin에는 다른 내용을 파이프로 흘려 두므로,
# 헬퍼 본문이 bare `cat`으로 되돌아가면 hang이 아니라 FROM-STDIN이 나와 **red**가 된다(파이프라 EOF가 있다).
@test "the shared sops passthrough stub takes its input from the file operand, not stdin" {
  make_sops_passthrough_stub
  printf 'FROM-FILE' > "$TMP/probe"
  run env PATH="$STUB:$PATH" bash -c 'printf FROM-STDIN | sops -d --input-type binary --output-type binary "$1"' _ "$TMP/probe"
  [ "$status" -eq 0 ]
  [ "$output" = "FROM-FILE" ]
}
