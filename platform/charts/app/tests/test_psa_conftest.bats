#!/usr/bin/env bats
# PSA restricted conftest 백스톱 — 스키마가 못 잡는 약화(capabilities.add·Unconfined seccomp 등)를
# 렌더 파드에서 잡는다(라이브 admission 패리티, 적대 리뷰 Pass1 #4·Pass3 #3). @test 영어(CJK 함정).
CHART="${BATS_TEST_DIRNAME}/.."
REGO="$CHART/tests/psa-restricted.rego"

@test "chart fixtures (web/worker/site) pass PSA restricted conftest" {
  for k in web worker site; do
    # ⚠️ helm과 conftest를 **나눈다**. 예전엔 `run bash -c "helm … | conftest …"` 한 줄이었는데
    #    (a) `bash -c`는 pipefail을 물려받지 않아 helm 실패가 conftest의 rc에 가려지고
    #    (b) conftest는 **빈 stdin에 rc 0**("10 tests, 10 passed")이다 — 둘이 겹쳐 빈 렌더가 초록으로
    #    통과했다(2026-08-29 M1 실측: templates/ 3파일을 0바이트로 비워도 이 @test는 ok).
    #    분리하면 helm 실패는 bats errexit이, 빈 렌더는 아래 양성 대조가 각각 red로 만든다.
    out=$(helm template t "$CHART" -f "$CHART/tests/fixtures/$k.yaml")
    echo "$out" | grep -qF 'kind: Deployment'
    run conftest test --policy "$REGO" - <<<"$out"
    echo "$output"
    [ "$status" -eq 0 ]
  done
}

@test "conftest denies capabilities.add beyond NET_BIND_SERVICE (schema-allowed weakening)" {
  run bash -c "helm template t '$CHART' -f '$CHART/tests/fixtures-bad/caps-add.yaml' | conftest test --policy '$REGO' -"
  echo "$output"
  [ "$status" -ne 0 ]
}

@test "conftest denies Unconfined seccomp (schema-allowed weakening)" {
  run bash -c "helm template t '$CHART' -f '$CHART/tests/fixtures-bad/seccomp-unconfined.yaml' | conftest test --policy '$REGO' -"
  echo "$output"
  [ "$status" -ne 0 ]
}
