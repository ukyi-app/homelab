#!/usr/bin/env bats
# ⚠️ 이 파일의 부재 단언은 **두 모양**이다 — grep rc만 열거하면 나머지 절반이 열거 밖으로 샌다.
#    (1) 경로 피연산자를 든 grep 하나(homepage @test) → `-eq 1`로 전환(SSOT ③·③-a).
#    (2) `[ -z "$(… | yq …)" ]` 커맨드 치환 둘(worker @test) → 좁힐 rc가 아예 없는 SSOT ② 모양이다.
#        처방은 rc 전환이 아니라 비공허 바닥값이며, 그 자리 주석에 실측을 적었다.
#    `run tpl`(helm template 래퍼)의 `-ne 0`은 부재 단언이 아니다 — helm의 스키마 위반 규약이라 비대상.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」②·③·③-a
CHART="${BATS_TEST_DIRNAME}/.."
R="--set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
   --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"
tpl() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 $R "$@"; }

@test "web gets Service and HTTPRoute referencing the shared Gateway" {
  out=$(tpl --set kind=web --set route.host=api.example.com --set route.public=true)
  echo "$out" | yq 'select(.kind=="Service")' | grep -q "port: 8080"
  rt=$(echo "$out" | yq 'select(.kind=="HTTPRoute")')
  echo "$rt" | grep -qF -- 'name: homelab'
  echo "$rt" | grep -qF -- 'namespace: gateway'
  echo "$rt" | grep -qF -- 'sectionName: web-public'
  echo "$rt" | grep -qF -- 'api.example.com'
}

@test "internal app binds to the internal HTTPS listener" {
  rt=$(tpl --set kind=web --set route.host=admin.home.example.com --set route.public=false | yq 'select(.kind=="HTTPRoute")')
  [[ "$rt" == *"sectionName: web-internal-tls"* ]]
}

@test "worker has no Service and no HTTPRoute" {
  out=$(tpl --set kind=worker)
  # ⚠️ 아래 두 부재 단언은 grep rc가 아니라 **커맨드 치환**이다(SSOT ②) — 렌더가 통째로 비면
  #    `$out`이 빈 문자열이라 둘 다 공허하게 통과한다. 2026-08-29 격리 트리 실측: templates/의
  #    3파일을 0바이트로 비우면(helm rc 0) 나머지 5개 @test는 전건 red인데 이 @test만 초록이었다.
  #    좁힐 rc가 없으므로 처방은 아래 양성 대조 — worker 렌더가 실제로 워크로드를 냈음을 증언해
  #    빈 렌더를 red로 만든다(같은 파일 homepage @test의 on.yaml 단언과 같은 역할).
  echo "$out" | grep -qF 'kind: Deployment'
  [ -z "$(echo "$out" | yq 'select(.kind=="Service")')" ]
  [ -z "$(echo "$out" | yq 'select(.kind=="HTTPRoute")')" ]
}

@test "app.validate rejects a public route bound to an internal .home. host" {
  run tpl --set kind=web --set route.public=true --set route.host=admin.home.example.com
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '.home.'
}

@test "app.validate rejects an internal route (public=false) whose host is not a .home. host" {
  run tpl --set kind=web --set route.public=false --set route.host=api.example.com
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '.home.'
}

@test "homepage discovery annotations gate on homepage.enabled" {
  tpl --set kind=web --set route.public=true --set route.host=api.example.com > "$BATS_TEST_TMPDIR/off.yaml"
  # 부재는 `-eq 1` — 이 피연산자는 **바로 윗줄 리다이렉트가 쓰는 것과 별개의 리터럴**이라 한쪽만
  # 드리프트하면 파일이 아예 없고, `-ne 0`은 그 rc 2를 "어노테이션 없음"으로 읽었다
  # (격리 트리 실측: 리다이렉트 쪽 경로만 바꿔도 이 @test는 초록이었다).
  # cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
  run grep -q 'gethomepage.dev/enabled' "$BATS_TEST_TMPDIR/off.yaml"; [ "$status" -eq 1 ]
  tpl --set kind=web --set route.public=true --set route.host=api.example.com --set homepage.enabled=true --set homepage.icon=mdi-test > "$BATS_TEST_TMPDIR/on.yaml"
  run grep -q 'gethomepage.dev/enabled: "true"' "$BATS_TEST_TMPDIR/on.yaml"; [ "$status" -eq 0 ]
  run grep -q 'gethomepage.dev/group: "Apps"' "$BATS_TEST_TMPDIR/on.yaml"; [ "$status" -eq 0 ]
  run grep -q 'gethomepage.dev/icon: "mdi-test"' "$BATS_TEST_TMPDIR/on.yaml"; [ "$status" -eq 0 ]
  run grep -q 'gethomepage.dev/pod-selector: "app.homelab/instance=t"' "$BATS_TEST_TMPDIR/on.yaml"; [ "$status" -eq 0 ]
}
