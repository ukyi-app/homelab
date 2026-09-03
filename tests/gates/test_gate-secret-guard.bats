#!/usr/bin/env bats
# supplychain-3: 시크릿 누출 가드(gitleaks + sops-guard)가 required `gate` 잡에 강제되는지 단언.
# verify.yaml은 required가 아니므로(분기보호 contexts=["gate"]) gate 잡 자체에 폴딩돼야 한다.

ROOT="$BATS_TEST_DIRNAME/../.."
CI="$BATS_TEST_DIRNAME/../../.github/workflows/ci.yaml"
PRECOMMIT="$BATS_TEST_DIRNAME/../../.pre-commit-config.yaml"

@test "gate job installs gitleaks pinned to the pre-commit rev" {
  # pre-commit rev(SSOT)와 동일 버전을 핀해야 한다 — ci.yaml은 .pre-commit-config.yaml에서 버전을 런타임
  # 유도(yq 구조 쿼리)해 다운로드하므로 드리프트가 0이다(리터럴 하드코딩보다 강함 — 자동 추종).
  rev=$(grep -A2 'gitleaks/gitleaks' "$PRECOMMIT" | grep -oE 'rev: v[0-9.]+' | grep -oE 'v[0-9.]+')
  [ -n "$rev" ]
  run grep -qE 'yq .*\.pre-commit-config\.yaml|select\(\.repo.*gitleaks' "$CI"
  [ "$status" -eq 0 ]
  run grep -q 'gitleaks/gitleaks/releases/download/' "$CI"
  [ "$status" -eq 0 ]
}

@test "gate gitleaks scans the working tree (--no-git), not full git history (F2)" {
  # ⚠️ codex pass4 F2: bare 'gitleaks detect'는 히스토리 전체 스캔이라 과거 시크릿 하나로 게이트가 영구 red.
  # 작업트리만 스캔하는 --no-git이 있어야 한다(pre-commit 훅 등가).
  run grep -qE 'gitleaks detect' "$CI"
  [ "$status" -eq 0 ]
  run grep -qE 'gitleaks detect.*--no-git' "$CI"
  [ "$status" -eq 0 ]
}

@test "gate gitleaks download is checksum-verified against the release checksums.txt, no placeholder (F3+restale F1)" {
  # ⚠️ codex pass5 F3 + restale F1: gitleaks 다운로드는 sha256sum -c로 검증해야 하고, 하드코딩 placeholder가 아니라
  # 릴리스 공식 checksums.txt로 검증해야 한다(placeholder를 그대로 두면 게이트가 invalid checksum으로 깨진다).
  run grep -qE 'sha256sum -c' "$CI"
  [ "$status" -eq 0 ]
  # 공식 checksums.txt를 받아 검증하는지(=실 해시; placeholder 없음).
  run grep -qE 'gitleaks_.*_checksums\.txt' "$CI"
  [ "$status" -eq 0 ]
  # ⚠️ 아래 두 부정 단언은 `-eq 1`이다 — grep rc는 0=매치 · 1=무매치 · 2=대상 부재/읽기불가다.
  # `-ne 0`이면 "$CI"가 사라져도(rc 2) "placeholder 없음"으로 읽혀 초록이 된다.
  # 위 두 `-eq 0` 단언이 같은 @test 안의 양성 대조라, $CI 부재·공허는 여기 닿기 전에 red다.
  # placeholder SHA256(`<... SHA256 ...>`)가 남아있으면 안 된다.
  run grep -qE 'GL_SHA256="<' "$CI"
  [ "$status" -eq 1 ]
  # 체크섬 없이 gitleaks tarball을 curl→tar로 바로 파이프하면 안 된다.
  run grep -qE 'gitleaks.*\.tar\.gz" *\| *sudo tar' "$CI"
  [ "$status" -eq 1 ]
}

@test "gate job runs sops-guard over all tracked enc.yaml" {
  run grep -q 'scripts/sops-guard.sh' "$CI"
  [ "$status" -eq 0 ]
  # 계약은 "추적된 *.enc.yaml 전수 검사"다. 예전엔 그걸 ci.yaml의 파이프 배관으로 단언했는데,
  # 그 배관은 **글롭이 깨지면 스크립트를 아예 호출하지 않아** 스텝이 조용히 초록이었다.
  # 이제 가드가 자기 도메인을 소유한다(무인자 = 자가 열거 + 바닥값) — 계약을 그쪽에 단언한다.
  run grep -q "git ls-files '\\*.enc.yaml'" "$ROOT/scripts/sops-guard.sh"
  [ "$status" -eq 0 ]
  # ⚠️ 위 두 단언만으로는 ci.yaml을 **옛 배관으로 되돌려도** 아무 게이트가 red가 되지 않는다
  # (적대 검토 실측: `git show <이전>:.github/workflows/ci.yaml` 한 줄 복사로 vacuous 경로 재개방).
  # 배선이 열거를 다시 떠맡으면(파일 목록을 파이프로 주입) 글롭이 깨질 때 스크립트가 아예
  # 호출되지 않아 스텝이 조용히 초록이다 — ci.yaml은 **무인자 호출만** 허용한다.
  out="$(grep -n 'scripts/sops-guard.sh' "$CI")"
  run grep -qF '|' <<<"$out"
  [ "$status" -ne 0 ]
}

# 배관을 옮긴 자리의 실측 증인 — 무인자 호출이 실제로 전수 검사인가.
@test "sops-guard with no arguments enumerates the tracked domain (not a silent no-op)" {
  run bash "$ROOT/scripts/sops-guard.sh"
  [ "$status" -eq 0 ]
  # 도메인이 붕괴하면 조용한 성공이 아니라 실패여야 한다.
  shim="$BATS_TEST_TMPDIR/bin"; mkdir -p "$shim"
  printf '#!/bin/sh\nif [ "$1" = "ls-files" ] && [ "$2" = "*.enc.yaml" ]; then exit 0; fi\nexec /usr/bin/git "$@"\n' > "$shim/git"
  chmod +x "$shim/git"
  PATH="$shim:$PATH" run bash "$ROOT/scripts/sops-guard.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "secret guard step lives in the gate job (required check), not only verify" {
  # `gate:` 잡 본문 안에 gitleaks/sops-guard가 있어야 한다(verify.yaml에만 있으면 안 됨).
  run awk '/^  gate:/{g=1} /^  [a-z]/ && !/^  gate:/{g=0} g && (/gitleaks/||/sops-guard/){print}' "$CI"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ⚠️ **비-0 전파까지가 '강제'다.** 이 파일의 나머지 레인은 전부 ci.yaml에 대한 토큰 존재 grep이라
#    검사가 **차단적인지**를 아무도 재지 않았다. 실측 2026-09-03 — 뮤테이션 A(secret-guard 스텝에
#    `continue-on-error: true` 한 줄 삽입)·B(`--exit-code 1`→`0` + checksum 파이프에 `|| true`)
#    양쪽에서 이 파일이 9/9 green이었고 check-workflow-readiness·check-ci-parity·actionlint·
#    check-guard-authority도 전부 rc 0이었다. required check는 `gate` 하나뿐이라(docs/decisions/0003)
#    스캐너가 조용히 비차단이 되면 평문 토큰 PR이 auto-merge로 main에 착지한다.
#    관용구 선례: tests/gates/test_iac-destroy-guard.bats:38-40(continue-on-error 부재 단언).
@test "the gate secret scanner is blocking (no continue-on-error/if, no fail-open idiom in its run body)" {
  # 두 스텝(secret-guard·sops-guard)이 실재한다 — 열거가 0건이면 아래 부재 단언이 공허하다.
  run yq -e '[.jobs.gate.steps[] | select((.name // "") | test("secret-guard|sops-guard"))] | length == 2' "$CI"
  [ "$status" -eq 0 ]
  # 스텝 수준 무력화: continue-on-error(비-0을 삼킨다) · if(조건부 비실행)
  run yq -e '[.jobs.gate.steps[] | select((.name // "") | test("secret-guard|sops-guard")) | select(has("continue-on-error") or has("if"))] | length == 0' "$CI"
  [ "$status" -eq 0 ]
  # 본문 수준 무력화: `|| true`(검출기 사망·검출을 함께 삼킨다) · `--exit-code 0`(gitleaks 비차단)
  body="$(yq -r '.jobs.gate.steps[] | select((.name // "") | test("secret-guard|sops-guard")) | .run' "$CI")"
  [ -n "$body" ]
  n="$(printf '%s' "$body" | grep -cF -- '|| true' || true)"
  [ "$n" -eq 0 ]
  n="$(printf '%s' "$body" | grep -cF -- '--exit-code 0' || true)"
  [ "$n" -eq 0 ]
  # 양성 대조 — gitleaks가 차단 종료코드로 돌고 있다(본문 추출이 살아 있다는 증인이기도 하다).
  printf '%s' "$body" | grep -qF -- '--exit-code 1'
}

@test "sops-guard PASSES a realistically sops-shaped enc.yaml (ENC[AES256_GCM,...] leaves)" {
  # codex pass1 F4 회귀 fixture: 실제 SOPS 리프 형태가 평문으로 오판되지 않아야(gate가 모든 enc.yaml을
  # 오차단하지 않게). age 키 불필요 — sops-guard는 구조만 본다. 게이트 글롭 포함 파일이라 required로 강제.
  # 실제 sops 파일은 항상 .sops.age(canonical cluster+recovery 공개키)를 갖는다 — recipient 신원 검사 통과용.
  d="$BATS_TEST_TMPDIR"
  cat > "$d/real.enc.yaml" <<'YAML'
apiVersion: v1
kind: Secret
stringData:
    TOKEN: ENC[AES256_GCM,data:Zm9v,iv:YmFy,tag:YmF6,type:str]
sops:
    age:
        - recipient: age1n3j7p70f0unl5dgrjhtr9jxrdntz2a67dtntu446qus9c3jd3fnsp8z960
          enc: x
        - recipient: age154tu9q7922xu46x0rkfm5l9x3ulf9u5at5qvxeaqfx9sgtm7cumq75jdwc
          enc: y
    mac: ENC[AES256_GCM,data:bWFj,type:str]
    lastmodified: "2026-06-16T00:00:00Z"
YAML
  run "$BATS_TEST_DIRNAME/../../scripts/sops-guard.sh" "$d/real.enc.yaml"
  [ "$status" -eq 0 ]
}

@test "sops-guard BLOCKS a plaintext-leaf enc.yaml even with valid sops metadata (gated behavioral)" {
  d="$BATS_TEST_TMPDIR"
  cat > "$d/leak.enc.yaml" <<'YAML'
apiVersion: v1
kind: Secret
stringData:
    TOKEN: super-secret-plaintext
sops:
    mac: ENC[AES256_GCM,data:bWFj,type:str]
    lastmodified: "2026-06-16T00:00:00Z"
YAML
  run "$BATS_TEST_DIRNAME/../../scripts/sops-guard.sh" "$d/leak.enc.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
}

@test "gitleaks allowlist stays minimal: default rules kept, exactly the two measured false-positive classes" {
  # v8.30.1 bump(2026-09-02)에서 gate가 잡은 9건 = *.sealed.yaml 8건(generic-api-key) + 벤더
  # barman manifest 1건(kubernetes-secret-yaml, 내용은 사이드카 이미지 참조). 그 둘만 면제한다 —
  # 면제 경로가 늘거나 기본 룰셋이 꺼지면 스캐너가 조용히 눈을 감는 것이므로 여기서 red.
  C="$ROOT/.gitleaks.toml"
  [ -f "$C" ]
  grep -qE '^useDefault = true$' "$C"
  # 면제 블록은 정확히 2개, 경로 패턴은 아래 둘뿐(양성 대조 + 건수 등식 — `grep -qv`는 부재를 못 잰다).
  [ "$(grep -c '^\[\[allowlists\]\]$' "$C")" -eq 2 ]
  [ "$(grep -c '^paths = ' "$C")" -eq 2 ]
  grep -qF -- "paths = ['''(^|/)[^/]+\.sealed\.yaml$''']" "$C"
  grep -qF -- "paths = ['''^platform/cnpg/barman-plugin/manifest\.yaml$''']" "$C"
  # ⚠️ **두 면제 모두** 룰 한정이어야 한다(파일 전체 면제 금지). 봉인본 쪽에 targetRules가 없던 동안
  # `*.sealed.yaml` 19개 파일에서 기본 룰셋이 통째로 꺼져, 봉인 안 한 평문 Secret을 그 이름으로 커밋해도
  # 스캐너가 무성이었다(실측: 같은 내용을 .plain.yaml/.sealed.yaml에 두면 전자만 잡혔다).
  # 건수 등식이 있어야 한 블록만 다시 넓어지는 재확장이 red가 된다.
  [ "$(grep -c '^targetRules = ' "$C")" -eq 2 ]
  grep -qF -- 'targetRules = ["kubernetes-secret-yaml"]' "$C"
  grep -qF -- 'targetRules = ["generic-api-key"]' "$C"
  # 원소 '추가' 축(exact-tests-1) — 위 멤버십 5건(useDefault·paths×2·targetRules×2)은 존재만
  # 잰다. disabledRules 한 줄로 기본 룰을 끄거나 regexes/stopwords/commits/regexTarget으로
  # 면제 스코프를 넓혀도 위 단언은 그대로 초록이었다 — 새 테이블·새 키 자체를 상한으로 문다.
  [ "$(grep -cE '^\[' "$C")" -eq 3 ]              # [extend] + [[allowlists]]×2 — 그 외 테이블 금지
  [ "$(grep -c '^description = ' "$C")" -eq 2 ]
  [ "$(grep -cE '^[A-Za-z_]+ *=' "$C")" -eq 7 ]   # 1+2+2+2 = 정확 집합(disabledRules 등 신규 키 = red)
}
