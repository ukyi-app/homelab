#!/usr/bin/env bats
# deadmanswitch relay 회귀 가드.
# (1) busybox 1.38 nc에는 -q 옵션이 없다 — 'nc -l -p PORT -q 1'은 invalid option으로 즉시 죽어
#     webhook을 영구 거부했고, 그 결과 healthchecks를 과도 ping해 dead-man switch를 무력화한
#     라이브 인시던트가 있었다.
# (2) fm-1: nc가 실제로 연결을 서빙(exit 0)했을 때만 healthchecks를 ping해야 한다. nc 실패를
#     '|| true'로 삼키고 무조건 wget을 발화하면, bind 경합/busybox 엣지로 nc가 연결 없이 반환할 때
#     루프가 healthchecks를 폭주 ping해 webhook 미수신인데도 체크가 영구 green이 된다.
# 이 릴레이는 k8s 워크로드라 테스트는 임베드 relay.sh에 대한 '정적' grep이다(busybox 부재·CI 클러스터 비접촉).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어 — 한글 인코딩 깨짐.
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 deadmanswitch-relay.yaml 단일 파일이라
#    그것으로 닫힌다. setup이 이미 ROOT 오산으로 F를 doubled 경로로 만들어 전건 공허 통과한 전력이
#    있는 파일이라(위 #53 기록) 이 rc 구별이 그 재발의 두 번째 방어선이다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a

setup() {
  # ⚠️ #53 false-green 수정 (스코프 추가): 테스트가 prod/로 이동(platform/victoria-stack/prod/test_relay.bats)했는데
  # main의 현재 setup은 여전히 ../.. (2-up)이라 ROOT가 platform/victoria-stack로 잘못 잡혀 F가 존재하지 않는 doubled
  # 경로가 된다 → 기존 -q 가드가 공허 통과(보호 0). prod/는 root에서 3-deep이므로 ../../.. 로 고친다.
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  F="$ROOT/platform/victoria-stack/prod/deadmanswitch-relay.yaml"
}

@test "relay nc listener does not use the busybox-incompatible -q flag" {
  # ⚠️ 부재 단언 단독이라 `$F`를 읽는 형제 증인이 없다 — 예전 `-ne 0`에서는 대상 리네임에도
  #    초록이었다. 2026-08-29 격리 트리 실측(base=`git archive HEAD`, 매니페스트만 리네임):
  #    6건 중 **3건**이 살아남았다 — 이 부재 단언 둘(rc 2를 무매치로 오독)과, `$F`를 아예 읽지
  #    않아 리네임에 영향받지 않는 맨 아래 kustomization 배선 @test. 즉 헤더가 적은 두 라이브
  #    인시던트의 회귀 가드가 대상 부재에 공허했다.
  #    `-eq 1`로 고친 지금 같은 뮤테이션의 생존은 1건 = 그 배선 @test뿐이다(같은 날 실측).
  run grep -nE 'nc[[:space:]].*-q' "$F"
  [ "$status" -eq 1 ]
}

@test "relay does not swallow nc failure with a trailing || true before pinging" {
  # '... | nc -l ... || true' 패턴(nc 실패 무시)이 더는 없어야 한다.
  # ⚠️ 위 @test와 같다 — 위 실측에서 리네임을 견디고 살아남은 부재 단언 둘 중 하나였다.
  run grep -nE 'nc[[:space:]]+-l[^|]*\|\|[[:space:]]*true' "$F"
  [ "$status" -eq 1 ]
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

@test "relay is wired into the victoria-stack kustomization" {
  # ⚠️ 이 파일의 나머지 @test는 전부 deadmanswitch-relay.yaml **원문**만 읽는다 — relay가
  #    kustomization에서 빠져 클러스터에 존재하지 않는 동안에도 전건 초록이었다(2026-08-12~17 실측).
  #    배선 단언이 컷오버 전용 가드(tests/gates/의 병행운용 divergence 파일)에만 있으면 그 파일의
  #    은퇴와 함께 이 갭이 되돌아온다. 그래서 relay 자신의 도메인 가드에 둔다
  #    (선례: test_pvc_du_exporter.bats의 "du exporter is wired into kustomization").
  # ⚠️ 그 가드 파일을 **이름으로 부르지 않는다** — 파일명 자체가 컷오버 마커 문자열을 담고 있어
  #    부르는 순간 이 파일이 마커 원장에 잡힌다(방금 실제로 밟았다).
  # ⚠️ 원문 grep이 아니라 `yq` 파싱이다 — 주석 줄과 들여쓰기가 어긋나 시퀀스 원소가 아닌 줄을
  #    통과시키지 않기 위해서다(둘 다 이 항목이 실제로 누워 있던 형태다).
  command -v yq >/dev/null || skip "yq required"
  run yq '.resources | contains(["deadmanswitch-relay.yaml"])' "$ROOT/platform/victoria-stack/prod/kustomization.yaml"
  printf '%s' "$output" | grep -qxF -- 'true'
}
