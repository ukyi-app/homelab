#!/usr/bin/env bats
# deadmanswitch relay 회귀 가드.
# (1) busybox 1.36 nc에는 -q 옵션이 없다 — 'nc -l -p PORT -q 1'은 invalid option으로 즉시 죽어
#     webhook을 영구 거부했고, 그 결과 healthchecks를 과도 ping해 dead-man switch를 무력화한
#     라이브 인시던트가 있었다.
# (2) fm-1: nc가 실제로 연결을 서빙(exit 0)했을 때만 healthchecks를 ping해야 한다. nc 실패를
#     '|| true'로 삼키고 무조건 wget을 발화하면, bind 경합/busybox 엣지로 nc가 연결 없이 반환할 때
#     루프가 healthchecks를 폭주 ping해 webhook 미수신인데도 체크가 영구 green이 된다.
# 이 릴레이는 k8s 워크로드라 테스트는 임베드 relay.sh에 대한 '정적' grep이다(busybox 부재·CI 클러스터 비접촉).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어 — 한글 인코딩 깨짐.

setup() {
  # ⚠️ #53 false-green 수정 (스코프 추가): 테스트가 prod/로 이동(platform/victoria-stack/prod/test_relay.bats)했는데
  # main의 현재 setup은 여전히 ../.. (2-up)이라 ROOT가 platform/victoria-stack로 잘못 잡혀 F가 존재하지 않는 doubled
  # 경로가 된다 → 기존 -q 가드가 공허 통과(보호 0). prod/는 root에서 3-deep이므로 ../../.. 로 고친다.
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  F="$ROOT/platform/victoria-stack/prod/deadmanswitch-relay.yaml"
}

@test "relay nc listener does not use the busybox-incompatible -q flag" {
  run grep -nE 'nc[[:space:]].*-q' "$F"
  [ "$status" -ne 0 ]
}

@test "relay does not swallow nc failure with a trailing || true before pinging" {
  # '... | nc -l ... || true' 패턴(nc 실패 무시)이 더는 없어야 한다.
  run grep -nE 'nc[[:space:]]+-l[^|]*\|\|[[:space:]]*true' "$F"
  [ "$status" -ne 0 ]
}

@test "relay pings healthchecks only when nc served a request (wget nested under nc success)" {
  # wget(healthchecks ping)이 nc를 조건으로 한 if 성공 분기 안에 있어야 한다.
  # 정적 증거: 'if ... nc -l ...; then' 라인이 존재하고, 그 then 블록 안에서 wget이 호출된다.
  run grep -nE 'if[[:space:]].*nc[[:space:]]+-l[[:space:]]+-p[[:space:]]+9095' "$F"
  [ "$status" -eq 0 ]
  # wget은 if 가드와 같은 then 블록의 들여쓰기 깊이(공백 6칸 이상)로 중첩돼야 한다.
  run grep -nE '^[[:space:]]{6,}wget[[:space:]]' "$F"
  [ "$status" -eq 0 ]
}

@test "relay self-throttles on nc bind failure with a floor sleep" {
  # nc 실패 분기에 sleep(>=1초)이 있어 bind 경합 시 루프 spin/healthchecks 폭주를 막는다.
  run grep -nE '^[[:space:]]+sleep[[:space:]]+[1-9][0-9]*' "$F"
  [ "$status" -eq 0 ]
}

@test "relay Deployment carries a checksum/relay-script annotation matching relay.sh (F7 GitOps roll)" {
  # ⚠️ codex pass2 F7: ConfigMap 변경은 파드 자동 재시작이 없다 — 스크립트 해시를 pod template annotation으로
  # 박아 relay.sh 변경 시 template이 바뀌어 ArgoCD가 자동 롤하게 한다. 이 단언이 annotation==hash를 강제.
  command -v yq >/dev/null || skip "yq required"
  expected=$(yq 'select(.kind=="ConfigMap").data."relay.sh"' "$F" | sha256sum | cut -c1-16)
  ann=$(yq 'select(.kind=="Deployment").spec.template.metadata.annotations."checksum/relay-script"' "$F")
  [ -n "$ann" ]
  [ "$ann" = "$expected" ]
}
