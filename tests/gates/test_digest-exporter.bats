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

@test "drift recording-rule aligns both join sides on (app,digest) (no permanent false fire)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r6-ci-staleness.yaml"
  grep -q 'max by (app, digest) (ghcr_latest_digest)' "$R"   # 좌변 digest 보존
  grep -q '"app", "$1", "image_id"' "$R"                     # 우변 image_id→app 추출(k3s: image=bare ID)
  run grep -q 'max by (app) (ghcr_latest_digest)' "$R"; [ "$status" -ne 0 ]  # 파손식 회귀 금지
  run grep -q 'image=~' "$R"; [ "$status" -ne 0 ]            # bare-ID 라벨 selector 회귀 금지
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
