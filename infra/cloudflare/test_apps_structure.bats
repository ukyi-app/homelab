#!/usr/bin/env bats
# apps.json 구조 무결성(jq-only, terraform 비의존) — required gate가 수집(run-bats, .ci-exclude 미등재).
# 적대 리뷰: 이 검증이 advisory iac-validate(if: pull_request, 비-required)에만 있어 required gate를 우회했고,
# dns.tf의 toset()이 중복 host를 조용히 dedupe해 push-apply의 terraform plan도 통과시킨다 → host 충돌/예약어
# 탈취가 무인 적용될 수 있었다. terraform 의존 검사(validate·dns.tf grep)는 test_apps_data.bats에 잔류(excluded).
# @test 이름은 영어(CJK 인코딩 함정).

setup() { C="$(cd "$BATS_TEST_DIRNAME" && pwd)"; }

@test "apps.json is valid JSON and is an array" {
  run jq -e 'type == "array"' "$C/apps.json"
  [ "$status" -eq 0 ]
}

@test "apps.json has globally unique app names and hosts (no silent collision)" {
  # 중복 host는 toset에서 조용히 사라지지만 Gateway엔 같은 hostname HTTPRoute 2개 → 오라우팅.
  run jq -e '(.|length) == ([.[].name]|unique|length) and (.|length) == ([.[].host]|unique|length)' "$C/apps.json"
  [ "$status" -eq 0 ]
}

@test "apps.json hosts do not collide with reserved names (apex/www/home suffix, case-normalized)" {
  # [infra-b-5] DNS는 대소문자를 구별하지 않는데 아래 술어는 구별한다 — WWW./Files./x.Home. 같은
  # case variant 3종이 5/5 초록으로 통과했다(6라운드 실측). 정규화 대신 표기 자체를 계약으로 고정한다
  # — 표기 계약 = tools/app-config-schema.json:25 `^[a-z0-9.-]+$`(손 편집 PR만이 남은 진입로다).
  run jq -e 'all(.[]; (.host|test("^[a-z0-9.-]+$"))) and all(.[]; (.host != "ukyi.app") and (.host != "www.ukyi.app") and ((.host|endswith(".home.ukyi.app"))|not))' "$C/apps.json"
  [ "$status" -eq 0 ]
}

@test "reserved-hosts.json is valid and lists fully-qualified platform hosts" {
  # [infra-b-5] 거울 구멍 — 예약 목록 쪽이 대문자면 위 :22 표기 계약과 어긋난 채로 통과한다.
  # 같은 표기 계약을 예약어 쪽에도 건다(현행 rc 0, `Files.ukyi.app` 변조 뮤테이션 rc 1 — 실측).
  run jq -e '(.platform_hosts | type) == "array" and (.platform_hosts | length) > 0 and (.platform_hosts | all(test("^[a-z0-9.-]+\\.ukyi\\.app$")))' "$C/reserved-hosts.json"
  [ "$status" -eq 0 ]
}

@test "reserved-hosts.json pins the exact web-public platform host set" {
  # [infra-b-4] length>0은 바닥값이라 원소 삭제만 잡는다 — 원소 추가·교체(공개 표면 SSOT 자체의
  # 신원 변조)는 상한이 없어 19/19 초록이었다(6라운드 실측, files.ukyi.app→evil.ukyi.app 포함).
  # 신규 베스포크 공개 컴포넌트는 docs/bespoke-component-checklist.md 절차에서 공개 HTTPRoute와
  # 이 리터럴을 함께 갱신한다(추가·삭제·교체 전부 red — 형제 관용구: 정렬 후 리터럴 등식,
  # platform/traefik/prod/test_gateway_sync_wave.bats:145 · platform/argocd/extras/test_argocd_extras.bats:99).
  run jq -e '([.platform_hosts[]]|sort) == ["argocd-webhook.ukyi.app","files.ukyi.app"]' "$C/reserved-hosts.json"
  [ "$status" -eq 0 ]
}

@test "apps.json hosts do not collide with reserved platform hosts (reserved-hosts.json SSOT)" {
  # 예약 host(platform_hosts)를 앱이 등록하면 Gateway 오라우팅 — apps.json은 예약 host를 못 가진다.
  run jq -e -n --slurpfile a "$C/apps.json" --slurpfile r "$C/reserved-hosts.json" \
    '($r[0].platform_hosts // []) as $rh | all($a[0][]; .host as $h | ($rh | index($h)) == null)'
  [ "$status" -eq 0 ]
}
