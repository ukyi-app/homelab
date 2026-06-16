#!/usr/bin/env bats
# Renovate self-hosted 도입 게이트 — 설정/워크플로의 핵심 불변식을 강제한다.
# (중간 단언은 [ ]/grep 단순 명령으로 — bash 3.2에서 [[ ]] 실패 침묵 통과 회피)
R="renovate.json"
WF=".github/workflows/renovate.yml"

@test "renovate.json is valid JSON with the homelab guardrails" {
  command -v jq >/dev/null || skip "jq required"
  jq -e . "$R" >/dev/null
  jq -e '.pinDigests == true' "$R" >/dev/null                    # 서드파티 이미지 digest 핀(supply-chain)
  jq -e '.["github-actions"].enabled == false' "$R" >/dev/null   # workflows:write 토큰 전까지 비활성
  jq -e 'any(.ignorePaths[]; . == "**/charts/**")' "$R" >/dev/null # 벤더 helm 캐시 제외
}

@test "renovate custom managers cover the homelab version pins" {
  command -v jq >/dev/null || skip "jq required"
  jq -e 'any(.customManagers[]; .depNameTemplate == "k3s-io/k3s")' "$R" >/dev/null
  grep -q 'argo-cd' "$R"        # argocd CHART_VERSION
  grep -q 'helmrelease' "$R"    # HelmChartInflationGenerator(sealed-secrets/tailscale/…)
}

@test "helmrelease custom manager actually extracts ALL charts incl sealed-secrets (no silent miss)" {
  # 존재 단언만으로는 정규식이 실제 차트를 잡는지 모른다 — name↔repo 사이 주석이 있으면 매치 0이 돼
  # sealed-secrets(보안 컨트롤러)가 silent 미추적됐던 버그. renovate.json 실제 matchString으로 추출 검증.
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  ms="$(jq -r '.customManagers[] | select(.description|test("HelmChartInflationGenerator")) | .matchStrings[0]' "$R")"
  [ -n "$ms" ]
  MS="$ms" python3 - <<'PY'
import re, os, glob, sys
# Renovate/RE2 명명그룹 (?<name>) → python (?P<name>)로 변환(매치 여부만 확인).
pat = re.compile(re.sub(r"\(\?<", "(?P<", os.environ["MS"]))
files = sorted(glob.glob("platform/*/prod/helmrelease.yaml")) + sorted(glob.glob("platform/*/helmrelease.yaml"))
missed = [f for f in files if not pat.search(open(f).read())]
assert files, "helmrelease 파일 0개?"
assert not missed, "helmrelease 정규식 미매치(silent 미추적): %s" % missed
assert any("sealed-secrets" in f for f in files), "sealed-secrets helmrelease 부재"
print("ok: %d helmrelease 전부 추출" % len(files))
PY
}

@test "renovate workflow is preflight-gated and writes via a SHA-pinned App token" {
  grep -q 'HOMELAB_WRITER_APP_ID' "$WF"               # Phase-0 preflight skip(미설정 시 clean skip)
  grep -q 'create-github-app-token@bcd2ba4' "$WF"     # 액션 full SHA 핀(레포 규약)
  grep -q 'renovatebot/github-action@8217b3fc' "$WF"  # 액션 full SHA 핀
  grep -q 'permission-contents: write' "$WF"
  grep -q 'permission-pull-requests: write' "$WF"
}

@test "renovate token does NOT request workflows:write (consistent with github-actions manager disabled)" {
  # 실제 indented 요청 키만 검사(주석의 Phase-0 안내 언급은 허용). 미요청이라야 App 미보유 시 토큰 민팅이 안 깨진다.
  run grep -qE '^[[:space:]]+permission-workflows:' "$WF"
  [ "$status" -ne 0 ]
}

@test "renovate tracks ArgoCD inline helm charts (cnpg-operator, cert-manager)" {
  command -v jq >/dev/null || skip "jq required"
  # argocd manager가 apps 경로에 활성 — kubernetes(image)·custom(helmrelease) manager가 못 잡는 인라인 차트 핀 커버.
  jq -e '.argocd.managerFilePatterns | any(test("argocd/root/apps"))' "$R" >/dev/null
  # manager가 잡을 입력(인라인 chart 핀)이 실제로 존재해야 한다.
  grep -q 'chart: cloudnative-pg' platform/argocd/root/apps/cnpg-operator.yaml
  grep -q 'chart: cert-manager' platform/argocd/root/apps/cert-manager.yaml
}
