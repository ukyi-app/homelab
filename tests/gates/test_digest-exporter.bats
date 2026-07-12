#!/usr/bin/env bats
# R6 ImageDigestDrift 소생: digest-exporter가 (a) private GHCR 자격으로 inspect하고, (b) recording-rule
# join이 양변 라벨(app,digest) 정렬돼 오발화하지 않으며, (c) egress가 격리되고, (d) APPS가 apps/와 parity.
# (@test 이름 영어, 중간 단언 run+[ ] — bash 3.2 함정)
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; D="$ROOT/platform/victoria-stack/prod/digest-exporter.yaml"; }

@test "digest-exporter authenticates to private GHCR via ghcr-read authfile" {
  grep -q -- '--authfile /auth/config.json' "$D"          # skopeo가 자격 사용
  grep -q 'secretName: ghcr-read' "$D"                    # observability ns dockerconfigjson 마운트
  # SealedSecret 소스 존재(owner seal 산출) + kustomization 배선
  [ -f "$ROOT/platform/victoria-stack/prod/ghcr-read.sealed.yaml" ]
  grep -q 'ghcr-read.sealed.yaml' "$ROOT/platform/victoria-stack/prod/kustomization.yaml"
}

@test "digest-exporter pod is egress-isolated (label + default-deny + ghcr/vmsingle allow)" {
  N="$ROOT/platform/victoria-stack/prod/networkpolicy.yaml"
  grep -q 'app.kubernetes.io/name: digest-exporter' "$D"   # netpol 셀렉터용 pod 라벨
  grep -q 'digest-exporter-default-deny-egress' "$N"
  grep -q 'digest-exporter-allow-egress' "$N"
}

@test "drift recording-rule aligns both join sides on (app,digest) and rolls up the push metric" {
  R="$ROOT/platform/victoria-stack/prod/rules/r6-ci-staleness.yaml"
  # ⚠️ $R은 ConfigMap이다 — 룰 YAML은 .data["r6.yaml"]에 **문자열로** 박혀 있다(.spec.groups 아님 → 빈 결과).
  # 단언은 record expr **하나만** 겨냥한다(주석·타 룰이 단언을 만족시키는 오염 차단).
  EXPR="$(yq '.data["r6.yaml"]' "$R" | yq '.groups[].rules[] | select(.record == "app:image_digest_drift") | .expr')"
  [ -n "$EXPR" ]                                                          # 추출 실패 = 즉시 FAIL(빈 문자열 false-green 차단)
  grep -qE 'max by \(app, digest\) \(' <<<"$EXPR"                         # 좌변 digest 라벨 보존(조인 양변 정렬)
  grep -qE 'last_over_time\(ghcr_latest_digest\[[0-9]+m\]\)' <<<"$EXPR"   # push(10m) 메트릭에 rollup 착용 — 없으면 5m 룩백에 구멍→영구 무발화
  grep -q '"app", "$1", "image_id"' "$R"                                  # 우변 image_id→app 추출(k3s: image=bare ID)
  # 파손식(좌변이 digest 라벨을 떨궈 조인 키 소실) 회귀 금지. 부정 패턴은 ghcr_latest_digest **주변으로 좁힌다** —
  # 넓게 쓰면 우변 존재 가드의 정당한 `max by (app) (label_replace(kube_pod_container_info…))`까지 잡아
  # 올바른 픽스를 RED로 만든다. 맨 `! grep` 중간 부정은 bats false-green 함정 → run + status.
  run grep -qE 'max by \(app\) \([^)]*ghcr_latest_digest' <<<"$EXPR"
  [ "$status" -ne 0 ]
  run grep -q 'image=~' "$R"; [ "$status" -ne 0 ]                         # bare-ID 라벨 selector 회귀 금지
}

@test "drift rule's twin pod selectors stay byte-identical (unless RHS vs. existence guard)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r6-ci-staleness.yaml"
  EXPR="$(yq '.data["r6.yaml"]' "$R" | yq '.groups[].rules[] | select(.record == "app:image_digest_drift") | .expr')"
  [ -n "$EXPR" ]
  # `unless` 우변과 말미 존재 가드는 같은 파드 셀렉터의 **바이트 쌍둥이**다(중복 수용: 새 recording rule은
  # eval 순서 의존, 우변 rollup은 fail-open 거울상 → 둘 다 더 나쁘다). 문제는 그 쌍둥이 계약을 지키는 가드가
  # 없다는 것 — 누가 ns/owner/app-추출 정규식을 **한쪽만** 고치면 가드의 app 집합이 조용히 좁아져 진짜
  # 드리프트를 억제한다(= 우리가 고친 fail-open의 재발 경로). 여기서 못박는다.
  sel="$(grep -oE 'kube_pod_container_info\{[^}]*\}' <<<"$EXPR")"
  [ "$(printf '%s\n' "$sel" | wc -l | tr -d ' ')" -eq 2 ]           # 파드 셀렉터는 정확히 2회(unless 우변 + 존재 가드)
  [ "$(printf '%s\n' "$sel" | sort -u | wc -l | tr -d ' ')" -eq 1 ] # …그리고 둘이 동일(namespace + image_id 정규식)
  # app-추출 label_replace도 쌍둥이 — 치환 정규식까지 포함해 동일해야 가드의 app 집합이 우변과 일치한다.
  lr="$(grep -oE '"app", "\$1", "image_id", "[^"]*"' <<<"$EXPR")"
  [ "$(printf '%s\n' "$lr" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(printf '%s\n' "$lr" | sort -u | wc -l | tr -d ' ')" -eq 1 ]
}

@test "digest-exporter APPS tracks exactly the deployed apps/ set (variant-chain parity)" {
  val="$(yq 'select(.kind=="CronJob").spec.jobTemplate.spec.template.spec.containers[].env[] | select(.name=="APPS").value' "$D")"
  got="$(printf '%s' "$val" | tr ' ' '\n' | sed -n 's/=.*//p' | grep -v '^$' | sort | tr '\n' ' ')"
  want="$(ls -1 "$ROOT/apps" | grep -vx 'README.md' | sort | tr '\n' ' ')"
  [ "$got" = "$want" ] || { echo "APPS names='$got' != apps/='$want'"; false; }
}

@test "digest-exporter pushes via curl (wget is absent from the skopeo image)" {
  grep -q 'curl -fsS --data-binary' "$D"
  # 주석의 'wget' 언급은 허용 — 파이프 호출(| wget)만 금지(회귀 표적을 정확히 겨냥)
  run grep -qE '\|\s*wget' "$D"; [ "$status" -ne 0 ]
}
