#!/usr/bin/env bats
# Grafana 대시보드 ConfigMap 가드 — 이 표면에는 검증이 **0건**이었다(2026-08-31 신설).
#
# 왜 필요한가: `homelab-resources`의 "vs limit" 테이블은 NOTES.md가 §10 메모리 원장의 라이브 뷰로
# 축성한 패널이고, memory-ledger.md의 right-size 판단이 실제로 이 지표에서 나왔다. 그런데 그 분자가
# working_set이면 회수 가능한 page cache가 실사용으로 계상돼 **"누구를 줄일까"를 잘못 정렬한다**
# (PR #564: 같은 결함이 ContainerMemoryNearLimit을 위양성 발화시켰다. 라이브 실측으로 traefik이
# 62.4% vs 11.9%로 50%p 벌어졌고 순위 자체가 뒤바뀐다). 알림은 게이트가 지키는데 사람이 읽는
# 결정 표면은 아무도 안 지키고 있었다.
#
# ⚠️ 판정은 **파싱한 패널의 expr**에 대해서만 한다. 파일 전체를 grep하면 ConfigMap 상단 주석이
#    금지 메트릭 이름을 담고 있어 부재 단언이 조용히 무력화된다(이 레포의 「규약을 설명한 파일이
#    그 규약에서 면제된다」 클래스 — tests/gates/test_vmalert-config.bats가 같은 이유로 expr만 본다).
# ⚠️ 중간 단언은 `[ ]`만 — bash 3.2에서 `[[ ]]` 실패가 침묵 통과한다.
# @test 이름은 영어다(디렉토리 단위 실행에서 CJK 이름이 침묵 스킵되는 검증된 버그).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CM="$ROOT/platform/victoria-stack/prod/grafana-dashboards.yaml"
  DASH="$BATS_TEST_TMPDIR/resources.json"
  yq -r '.data["resources.json"]' "$CM" > "$DASH"
}

@test "the dashboard ConfigMap carries valid JSON with the expected identity" {
  [ -s "$DASH" ]
  run jq -e . "$DASH"
  [ "$status" -eq 0 ]
  run jq -re '.uid' "$DASH"
  [ "$status" -eq 0 ]
  [ "$output" = "homelab-resources" ]
}

# scan-floor — 패널 열거가 붕괴하면 아래 판정들이 공집합에 대해 vacuous green이 된다.
@test "panel enumeration does not collapse (scan floor)" {
  n="$(jq -r '.panels | length' "$DASH")"
  echo "SCAN: grafana-dashboards:panels: $n"
  [ "$n" -ge 3 ]
  # 모든 패널이 최소 하나의 질의를 갖는다 — 빈 targets는 패널을 판정 밖으로 빼는 조용한 문이다.
  empty="$(jq -r '[.panels[] | select((.targets // []) | length == 0)] | length' "$DASH")"
  [ "$empty" -eq 0 ]
}

# ★ 이 파일의 이유. limit 대비 비율은 **회수 불가 메모리**로 재야 한다.
@test "the limit-ratio panel measures unreclaimable memory, not working_set" {
  E="$BATS_TEST_TMPDIR/ratio-expr.txt"
  jq -r '.panels[] | select(.title | test("vs limit")) | .targets[].expr' "$DASH" > "$E"
  # 대상 패널이 사라지거나 제목이 바뀌면 여기서 red — 부재를 통과로 읽지 않는다.
  [ -s "$E" ]
  # limit으로 나누는 패널이 맞다는 확인(엉뚱한 패널을 재고 있지 않다).
  grep -q 'kube_pod_container_resource_limits' "$E"
  # ⚠️ 분모는 **두 KSM 계열의 or**여야 한다 — 네이티브 사이드카(restartPolicy: Always인 initContainer)의
  #    limit은 init 계열로 나가는데 분자에는 그 cgroup이 실려 과대 비율이 된다(라이브 pg-1 8.9% vs 7.1%).
  grep -q 'kube_pod_init_container_resource_limits' "$E"
  # ⚠️ 그 결박이 없으면 **더 틀린다** — 종료된 일반 init(bootstrap-controller 1Gi·copyutil 240Mi)까지
  #    분모에 실린다(pg-1 2.37Gi·4.0%). 룰은 per-container or라 무사했지만 pod 합산 표면에는 그 성질이
  #    없어 cAdvisor 실행 중 시리즈에 결박해야 한다. 이 줄이 종료 init 합산 회귀의 유일한 증인이다.
  grep -q 'and on (namespace,pod,container)' "$E"

  grep -q 'container_memory_usage_bytes' "$E"
  grep -q 'container_memory_total_inactive_file_bytes' "$E"
  grep -q 'container_memory_total_active_file_bytes' "$E"

  # ⚠️ 금지된 분자 셋. working_set = memory.current − inactive_file 이라 active_file(활성 clean page
  #    cache)을 싣고, max_usage는 캐시를 통째로 싣는다. cache 차감은 반대편 오답이다 — cgroup v2의
  #    memory.stat:file은 tmpfs·shared memory를 포함하고 이 호스트는 swap이 0이라 그 몫이 회수 불가다.
  run grep -q 'container_memory_working_set_bytes' "$E"; [ "$status" -eq 1 ]
  run grep -q 'container_memory_max_usage_bytes' "$E"; [ "$status" -eq 1 ]
  run grep -q 'container_memory_cache' "$E"; [ "$status" -eq 1 ]
}

# working_set 패널 자체는 **유지되어야 한다** — 비율이 아니라 총 사용량 추이이고 제목이 지표를
# 정직하게 말한다. 위 판정을 "working_set을 전부 없애라"로 오독해 이 패널까지 지우는 회귀를 막는다.
# 두 패널이 나란히 있어야 캐시 몫이 눈에 보인다.
@test "the working-set timeseries panel survives (it is the honest use of that metric)" {
  E="$BATS_TEST_TMPDIR/ws-expr.txt"
  jq -r '.panels[] | select(.title | test("working set"; "i")) | .targets[].expr' "$DASH" > "$E"
  [ -s "$E" ]
  grep -q 'container_memory_working_set_bytes' "$E"
  # 이 패널은 비율이 아니다 — limit으로 나누면 위 패널과 같은 오독을 다시 만든다.
  run grep -q 'kube_pod_container_resource_limits' "$E"; [ "$status" -eq 1 ]
}
