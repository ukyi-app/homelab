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
  # placeholder SHA256(`<... SHA256 ...>`)가 남아있으면 안 된다.
  run grep -qE 'GL_SHA256="<' "$CI"
  [ "$status" -ne 0 ]
  # 체크섬 없이 gitleaks tarball을 curl→tar로 바로 파이프하면 안 된다.
  run grep -qE 'gitleaks.*\.tar\.gz" *\| *sudo tar' "$CI"
  [ "$status" -ne 0 ]
}

@test "gate job runs sops-guard over all tracked enc.yaml" {
  run grep -q 'scripts/sops-guard.sh' "$CI"
  [ "$status" -eq 0 ]
  # 계약은 "추적된 *.enc.yaml 전수 검사"다. 예전엔 그걸 ci.yaml의 파이프 배관으로 단언했는데,
  # 그 배관은 **글롭이 깨지면 스크립트를 아예 호출하지 않아** 스텝이 조용히 초록이었다.
  # 이제 가드가 자기 도메인을 소유한다(무인자 = 자가 열거 + 바닥값) — 계약을 그쪽에 단언한다.
  run grep -q "git ls-files '\\*.enc.yaml'" "$ROOT/scripts/sops-guard.sh"
  [ "$status" -eq 0 ]
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
