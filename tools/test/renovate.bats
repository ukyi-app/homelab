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
