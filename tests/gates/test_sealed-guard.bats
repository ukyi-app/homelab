#!/usr/bin/env bats
# scripts/sealed-guard.sh — `*.sealed.yaml` 구조 가드의 gate 테스트.
#
# 병(2026-09-03 실측): 봉인본의 오봉인 두 형태를 어떤 기존 게이트도 잡지 않았다 —
# sops-guard는 `*.enc.yaml`만 보고(픽스처를 인자로 줘도 rc=0), pre-commit 훅 files 정규식도
# `\.enc\.yaml$`뿐이며, `scripts/check-app-deploy.sh`의 봉인 검사는 `apps/*/deploy/prod/` 스코프라
# platform/ 봉인본 19개가 통째로 무커버였다. `.gitleaks.toml`의 봉인본 면제는 `generic-api-key`로
# 좁혀졌지만 그 두 형태가 정확히 그 룰에 걸리는 모양이라 스코프를 좁혀도 여전히 면제된다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

ROOT="$BATS_TEST_DIRNAME/../.."
GUARD="$BATS_TEST_DIRNAME/../../scripts/sealed-guard.sh"
CI="$BATS_TEST_DIRNAME/../../.github/workflows/ci.yaml"
PRECOMMIT="$BATS_TEST_DIRNAME/../../.pre-commit-config.yaml"

# 정상 봉인본 픽스처 — 각 red 픽스처는 여기서 **한 조항만** 어긋난다(대조군).
write_sealed() {
  cat > "$1" <<'YAML'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: foo-secrets
  namespace: prod
spec:
  encryptedData:
    DB_PASSWORD: AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
  template:
    metadata:
      name: foo-secrets
      namespace: prod
    type: Opaque
YAML
}

@test "sealed-guard PASSES a realistically sealed SealedSecret (no false block)" {
  # 이 대조군이 없으면 아래 red 레인 전부가 "가드가 모든 것을 막는다"와 구별되지 않는다.
  write_sealed "$BATS_TEST_TMPDIR/ok.sealed.yaml"
  run bash "$GUARD" "$BATS_TEST_TMPDIR/ok.sealed.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: sealed-guard:files: 1$'
  echo "$output" | grep -qE '^SCAN: sealed-guard:keys: 1$'
}

@test "sealed-guard BLOCKS a plaintext leaf left in spec.template.stringData" {
  # 가장 개연적인 오봉인 — 봉인은 했는데 평문 비밀번호가 template에 잔류한다.
  # gitleaks의 봉인본 면제(generic-api-key)가 원리적으로 못 보는 형태다.
  d="$BATS_TEST_TMPDIR"
  cat > "$d/leak.sealed.yaml" <<'YAML'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: foo-secrets
  namespace: prod
spec:
  encryptedData:
    DB_PASSWORD: AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
  template:
    metadata:
      name: foo-secrets
      namespace: prod
    type: Opaque
    stringData:
      DB_PASSWORD: hunter2-plaintext-left-behind
YAML
  run bash "$GUARD" "$d/leak.sealed.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
  echo "$output" | grep -q 'plaintext leaf'
}

@test "sealed-guard BLOCKS a plaintext Secret committed under a *.sealed.yaml name" {
  d="$BATS_TEST_TMPDIR"
  cat > "$d/plain.sealed.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: foo-secrets
  namespace: prod
stringData:
  DB_PASSWORD: hunter2-never-sealed
YAML
  run bash "$GUARD" "$d/plain.sealed.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
  echo "$output" | grep -q 'SealedSecret'
}

@test "sealed-guard BLOCKS an empty encryptedData map (nothing was actually sealed)" {
  d="$BATS_TEST_TMPDIR"
  cat > "$d/empty.sealed.yaml" <<'YAML'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: foo-secrets
  namespace: prod
spec:
  encryptedData: {}
  template:
    metadata:
      name: foo-secrets
      namespace: prod
YAML
  run bash "$GUARD" "$d/empty.sealed.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'encryptedData'
}

@test "sealed-guard BLOCKS an encryptedData value that is not kubeseal ciphertext" {
  # ①②③을 통과하는 "형식만 맞춘" 위조 — 평문을 encryptedData 자리에 그대로 넣은 형태.
  d="$BATS_TEST_TMPDIR"
  cat > "$d/fake.sealed.yaml" <<'YAML'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: foo-secrets
  namespace: prod
spec:
  encryptedData:
    DB_PASSWORD: hunter2-not-ciphertext
  template:
    metadata:
      name: foo-secrets
      namespace: prod
YAML
  run bash "$GUARD" "$d/fake.sealed.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'ciphertext'
}

@test "sealed-guard BLOCKS a value that merely contains the substring Ag (anchor, not substring, match)" {
  # guard-decision-b-2 — line 82의 test("^Ag[A-Za-z0-9+/=]+\$")가 앵커를 잃고 부분매칭으로 완화돼도
  # 위 테스트의 픽스처("hunter2-not-ciphertext")는 우연히 "Ag"를 포함하지 않아 그 회귀를 못 잡는다.
  # 이 픽스처는 "Ag"를 중간에 담되(Agent) 전체가 Ag+base64는 아니다 — 앵커 자체의 독립 증인.
  d="$BATS_TEST_TMPDIR"
  cat > "$d/fake.sealed.yaml" <<'YAML'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: foo-secrets
  namespace: prod
spec:
  encryptedData:
    DB_PASSWORD: leaked-Agent-007-not-ciphertext
  template:
    metadata:
      name: foo-secrets
      namespace: prod
YAML
  run bash "$GUARD" "$d/fake.sealed.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'ciphertext'
}

@test "sealed-guard BLOCKS a file it cannot parse (an unjudgeable file is not a passing file)" {
  # 파싱 실패는 모든 집계를 0으로 만든다 — 그 0을 "위반 없음"으로 읽으면 fail-open이다.
  d="$BATS_TEST_TMPDIR"
  printf 'kind: [unclosed\n' > "$d/broken.sealed.yaml"
  run bash "$GUARD" "$d/broken.sealed.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
}

@test "sealed-guard sums over every document of a multi-document sealed file" {
  # 문서 하나만 보면 두 번째 문서의 평문 리프가 통째로 투명해진다.
  d="$BATS_TEST_TMPDIR"
  cat > "$d/multi.sealed.yaml" <<'YAML'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: a
  namespace: prod
spec:
  encryptedData:
    K: AgAAAA==
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: b
  namespace: prod
spec:
  encryptedData:
    K: AgBBBB==
  template:
    stringData:
      P: plaintext-in-the-second-document
YAML
  run bash "$GUARD" "$d/multi.sealed.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '1 plaintext leaf'
}

@test "an enumeration collapse dies on the file floor and withholds the marker" {
  write_sealed "$BATS_TEST_TMPDIR/ok.sealed.yaml"
  run bash "$GUARD" --floor sealed-guard:files=99 "$BATS_TEST_TMPDIR/ok.sealed.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '열거 붕괴'
  # 붕괴한 실행은 마커를 내지 않는다 — "검사했다"로 읽히면 소비자가 정반대 사실을 받는다.
  out="$output"
  run grep -q '^SCAN: sealed-guard:files:' <<<"$out"
  [ "$status" -eq 1 ]
}

@test "the key-total floor catches a collapse the file-count axis cannot see" {
  # 파일 수는 정상인데 내용이 통째로 빈 붕괴 — 파일 수 축으로는 원리적으로 관측되지 않는다.
  write_sealed "$BATS_TEST_TMPDIR/ok.sealed.yaml"
  run bash "$GUARD" --floor sealed-guard:keys=99 "$BATS_TEST_TMPDIR/ok.sealed.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'sealed-guard:keys'
  # 양성 대조 — 파일 축은 통과했다(두 도메인이 실제로 분리돼 있다는 증인).
  echo "$output" | grep -qE '^SCAN: sealed-guard:files: 1$'
}

@test "an unknown --floor domain is rejected instead of silently disabling the floor" {
  run bash "$GUARD" --floor nope=1
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'sealed-guard:files'
}

@test "the real tree passes and both scan domains report a non-empty count" {
  run bash "$GUARD"
  [ "$status" -eq 0 ]
  files="$(printf '%s\n' "$output" | sed -n 's/^SCAN: sealed-guard:files: //p')"
  keys="$(printf '%s\n' "$output" | sed -n 's/^SCAN: sealed-guard:keys: //p')"
  [ -n "$files" ]
  [ -n "$keys" ]
  # 바닥값과 같은 수치를 여기 다시 적지 않는다(손 관리 사본은 드리프트한다) — 비공허만 단언한다.
  [ "$files" -ge 1 ]
  [ "$keys" -ge "$files" ]
}

@test "the guard enumerates the tracked sealed domain itself (no caller-owned glob)" {
  # 예전 sops-guard의 병: 호출부가 `git ls-files … | xargs -r`로 열거를 소유하면 글롭이 깨질 때
  # 스크립트가 **아예 호출되지 않아** required 스텝이 조용히 초록이다.
  run grep -q "git ls-files '\\*.sealed.yaml'" "$ROOT/scripts/sealed-guard.sh"
  [ "$status" -eq 0 ]
  out="$(grep -n 'scripts/sealed-guard.sh' "$CI")"
  [ -n "$out" ]
  printf '%s' "$out" | grep -q 'bash scripts/sealed-guard.sh'
  # 인자를 주입하는 배선(파이프·xargs)은 그 vacuous 경로의 재개방이다.
  run grep -qE 'scripts/sealed-guard\.sh.*(xargs|\|)' "$CI"
  [ "$status" -eq 1 ]
}

@test "the pre-commit hook wires the guard to the sealed suffix (not the sops suffix)" {
  run yq -e '.repos[] | select(.repo == "local") | .hooks[] | select(.id == "sealed-guard") | .entry == "scripts/sealed-guard.sh"' "$PRECOMMIT"
  [ "$status" -eq 0 ]
  run yq -e '.repos[] | select(.repo == "local") | .hooks[] | select(.id == "sealed-guard") | .files' "$PRECOMMIT"
  [ "$status" -eq 0 ]
  [ "$output" = '\.sealed\.yaml$' ]
}

@test "the gate step for the guard is blocking (no continue-on-error, no if)" {
  # ⚠️ **행두 앵커**(`(^|\n)\s*`) — `.run` 전문에 test()를 걸면 주석 줄도 매치된다. 실측 2026-09-04:
  #    이 스텝 본문을 `# 비활성화: bash scripts/sealed-guard.sh` + `true`로 바꿔도 이 파일 35/35 ·
  #    형제 게이트(ci-gate·check-skeleton-gate·guard-authority) 26/27 · `bun tools/check-guard-authority.ts`
  #    rc 0으로 **아무 곳도** 잡지 않았다(원장 세 줄이 전부 같은 주석 문자열로 만족됐다). 이 파일의
  #    ledger 축과 달리 여기엔 두 번째 venue가 없어 조용해지면 진짜 fail-open이다.
  #    아래 `length == 0` 레인은 선택자가 0건이면 공허하게 참이라, 위 `length == 1`이 그 양성 대조다.
  run yq -e '[.jobs.gate.steps[] | select((.run // "") | test("(^|\n)\s*bash scripts/sealed-guard\.sh"))] | length == 1' "$CI"
  [ "$status" -eq 0 ]
  run yq -e '[.jobs.gate.steps[] | select((.run // "") | test("(^|\n)\s*bash scripts/sealed-guard\.sh")) | select(has("continue-on-error") or has("if"))] | length == 0' "$CI"
  [ "$status" -eq 0 ]
}

@test "the gitleaks residual-gap note names the structural guard that closes it" {
  # 면제가 남긴 갭을 산문으로만 적어두면 그 문장이 처방보다 오래 산다 — 이름을 실재와 묶는다.
  C="$ROOT/.gitleaks.toml"
  [ -f "$C" ]
  grep -qF 'scripts/sealed-guard.sh' "$C"
  [ -x "$ROOT/scripts/sealed-guard.sh" ]
}
