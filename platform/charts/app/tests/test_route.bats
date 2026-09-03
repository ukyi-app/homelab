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
  # backendRef가 실제로 이 릴리스의 Service를 그 Service의 포트로 가리키는지 — 참조 무결성 증인.
  # kubeconform은 임의 name/port를 스키마상 유효로 보고 conftest는 PSA 축만 본다. 값 축은 이미
  # 막혀 있다(values.schema.json ports.http/metrics는 const라 앱 values로 드리프트 불가) — 이 두 줄이
  # 막는 건 service.yaml↔httproute.yaml **비대칭 템플릿 편집**이다. 빈 렌더 공허 통과는 위의
  # `port: 8080`(Service)·`sectionName: web-public`(HTTPRoute) 비공허 대조가 이미 막는다.
  [ "$(echo "$out" | yq 'select(.kind=="HTTPRoute") | .spec.rules[0].backendRefs[0].name')" = "$(echo "$out" | yq 'select(.kind=="Service") | .metadata.name')" ]
  [ "$(echo "$out" | yq 'select(.kind=="HTTPRoute") | .spec.rules[0].backendRefs[0].port')" = "$(echo "$out" | yq 'select(.kind=="Service") | .spec.ports[0].port')" ]
  # 인스턴스 라벨은 selector의 유일성 축이다(_helpers.tpl app.selectorLabels ★주석 — selector는
  # 생성 후 immutable). 키는 반드시 app.homelab/instance다(app.kubernetes.io/instance는 ArgoCD
  # 예약 라벨이라 회피 — 같은 helper 주석). 지우면 prod ns의 전 앱 selector가
  # `app.kubernetes.io/name: app` 하나로 붕괴해 엔드포인트 혼입·RS 소유권 충돌이 난다.
  [ "$(echo "$out" | yq 'select(.kind=="Service") | .spec.selector["app.homelab/instance"]')" = "t" ]
  [ "$(echo "$out" | yq 'select(.kind=="Deployment") | .spec.selector.matchLabels["app.homelab/instance"]')" = "t" ]
}

@test "selector instance label is release-derived, not a chart-wide constant" {
  # 위 두 줄만으론 「라벨 값을 리터럴 t로 대체」 뮤테이션이 통과한다 — 릴리스명을 바꾼 두 번째
  # 렌더로 파생 관계 자체를 잰다. 빈 렌더는 ""≠"zz"라 red(별도 양성 대조 불요).
  o2=$(helm template zz "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 $R \
    --set kind=web --set route.public=true --set route.host=api.example.com)
  [ "$(echo "$o2" | yq 'select(.kind=="Deployment") | .spec.selector.matchLabels["app.homelab/instance"]')" = "zz" ]
  [ "$(echo "$o2" | yq 'select(.kind=="Service") | .spec.selector["app.homelab/instance"]')" = "zz" ]
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
