#!/usr/bin/env bats
# adguard *.home rewrite 셀프힐 리컨실러(메타갭 ① W2-A) 계약.
# ⚠️ @test 이름은 영어만(bats dir-run 인코딩), 중간 단언은 [ ]/grep만(bash 3.2 [[ ]] 침묵통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  F="$ROOT/platform/adguard/prod/rewrite-reconciler.yaml"       # SA + CronJob + 전용 egress netpol
  R="$ROOT/platform/adguard/prod/rewrite-reconciler-rbac.yaml"  # gateway ns Role/RoleBinding(cross-ns)
}

@test "reconciler reads traefik-ts svc via apiserver and converges the *.home rewrite" {
  grep -q '/api/v1/namespaces/gateway/services/traefik-ts' "$F"
  grep -q '/control/rewrite' "$F"
  grep -q '\*.home.ukyi.app' "$F"
}

@test "reconciler uses atomic rewrite update (no delete-add gap) — AdGuard v0.107.45+" {
  # F7: 원자적 /control/rewrite/update로 stale→want 교체(delete→add 비원자성으로 rewrite 소실 회피).
  grep -q '/control/rewrite/update' "$F"
  # 무방비 delete 금지(링치핀을 빈 상태로 남기지 않는다).
  run grep -q '/control/rewrite/delete' "$F"; [ "$status" -ne 0 ]
}

@test "reconciler calls the update endpoint with PUT (AdGuard registers update as PUT, not POST)" {
  # ★적대 리뷰 HIGH: /control/rewrite/update는 PUT-전용(rewritehttp.go:150) — curl -d(=POST)면 405로
  #   매번 실패해 stale 교정(리컨실러 핵심 목적)이 100% 불능. update 호출에 -X PUT 필수. add는 POST 유지.
  grep -qE '(-X PUT|--request PUT)' "$F"
  # PUT은 update 경로 근처에만(add는 POST). update 라인과 -X PUT가 같은 호출 블록인지 근접 확인.
  grep -A2 -- '-X PUT' "$F" | grep -q '/control/rewrite/update'
}

@test "reconciler pushes success timestamp metric to vmsingle (fail-closed staleness)" {
  grep -q 'adguard_rewrite_reconcile_timestamp' "$F"
  grep -q 'api/v1/import/prometheus' "$F"
}

@test "list_answer counts domain matches and rejects duplicates (mutation-retry residue)" {
  # WRITE의 잔존 재시도 창(타임아웃·5xx — curl 기본 transient)이 add를 중복시킬 수 있고,
  # 첫-매치 반환은 그 사실을 가린다 — 카운트 red가 유일한 감지선이다(awk는 0건에도 rc 0).
  grep -q 'awk -F' "$F"
  grep -q 'rewrite 중복' "$F"
}

@test "reconciler verifies read-back equals want before pushing the success heartbeat" {
  # read-back 검증이 하트비트 push보다 앞서는지(라인 순서, F7).
  rb=$(grep -n 'read-back' "$F" | head -1 | cut -d: -f1)
  hb=$(grep -n 'adguard_rewrite_reconcile_timestamp' "$F" | head -1 | cut -d: -f1)
  [ -n "$rb" ]
  [ -n "$hb" ]
  [ "$rb" -lt "$hb" ]
}

@test "reconciler carries no telegram credential or direct send path (notify via fix metric only)" {
  # F13: DNS 변이 권한 파드에 발송 자격·인터넷 egress 금지 — 통지는 메트릭→vmalert→alertmanager.
  run grep -qi 'sendMessage' "$F"; [ "$status" -ne 0 ]
  run grep -q 'TELEGRAM' "$F"; [ "$status" -ne 0 ]
  grep -q 'adguard_rewrite_last_fix_timestamp' "$F"
}

@test "reconciler fix timestamp is emitted only when a fix happened (no 0-sample noise, F19)" {
  # F19: no-op 런의 0 샘플이 last_over_time 최신값을 0으로 덮어 직전 fix 통지를 지우지 않도록 FIXED 게이트.
  grep -q 'FIXED' "$F"
}

@test "reconciler job has concurrency and deadline guards (no overlapping linchpin mutation)" {
  # F6: 의존성 정체 시 중첩 실행이 stale 값으로 rewrite를 변이(플래핑)하는 것 차단.
  grep -q 'concurrencyPolicy: Forbid' "$F"
  grep -q 'activeDeadlineSeconds: 120' "$F"
  grep -q 'startingDeadlineSeconds: 300' "$F"
  grep -q 'backoffLimit: 0' "$F"
}

@test "reconciler bounds every curl via READ and WRITE vars (timeouts on both, no bare curl)" {
  # F6/F12: 전 네트워크 호출이 타임아웃 바운드 — 재시도 등급이 갈려 var가 둘이다(followup-sweep 01).
  grep -q 'CURL_READ=' "$F"
  grep -q 'CURL_WRITE=' "$F"
  [ "$(grep -cE 'CURL_(READ|WRITE)=.*connect-timeout 5' "$F")" = "2" ]
  [ "$(grep -cE 'CURL_(READ|WRITE)=.*max-time 20' "$F")" = "2" ]
  [ "$(grep -cE 'CURL_(READ|WRITE)=.*retry-connrefused' "$F")" = "2" ]
  run grep -cE '^[[:space:]]*curl[[:space:]]' "$F"
  [ "$output" = "0" ] || [ "$status" -ne 0 ]
}

@test "read calls retry all transient errors within a widened bounded window" {
  # DNS(exit 6)는 curl이 이미 재시도한다(파드 실측 2026-08-27 — man 목록 밖인데도). 2026-07-26
  # 사고의 병은 재시도 창 6초였다 — 그래서 READ는 창 확대(retry 6·delay 3·rmt 30)가 본처방이고,
  # --retry-all-errors의 실델타는 TLS(35)·전송 리셋(55/56)·부분 전송(18)이다(멱등이라 안전).
  grep -E 'CURL_READ=' "$F" | grep -q -- '--retry-all-errors'
  grep -E 'CURL_READ=' "$F" | grep -q -- '--retry-max-time'
  grep -E 'CURL_READ=' "$F" | grep -q -- '--retry 6'
}

@test "mutation calls never opt into retry-all-errors (duplicate rewrite guard)" {
  # add(POST)/update(PUT)는 "적용됐는데 응답만 실패"의 재시도가 중복 rewrite를 만든다 —
  # ⚠️ curl 기본 transient(타임아웃 28·5xx)는 --retry가 **항상** 재시도하므로 이 위험은 좁게
  # 잔존하고(감지는 list_answer 중복 카운트), 여기서 막는 것은 그 창을 전 오류로 **넓히는 것**이다.
  # connrefused는 커넥션 수립 전 실패라 언제나 안전한 확장.
  run bash -c 'grep -E "CURL_WRITE=" "$1" | grep -- "--retry-all-errors"' _ "$F"
  [ "$status" -ne 0 ]
  # 방향: WRITE var 사용처가 전부 변이 엔드포인트다(콜사이트→var가 아니라 var→콜사이트 —
  # -B 오프셋 결합은 헤더 한 줄 추가로 거짓 실패가 난다, 01 리뷰). 사용처 수 2 = add(POST) +
  # update(PUT) — 변이 콜사이트를 늘리면 이 수와 아래 대조를 함께 갱신하라.
  run bash -c 'grep -A3 "\$CURL_WRITE" "$1" | grep -E "/control/rewrite/(add|update)\""' _ "$F"
  [ "$status" -eq 0 ]
  [ "$(grep -c '\$CURL_WRITE' "$F")" = "2" ]
}

@test "the retry budget stays under the job deadline (arithmetic witness)" {
  # 호출당 최악 ≈ retry-max-time + max-time(창 끝에 시작된 마지막 시도). '지연 2개(READ/WRITE 조합
  # 무관)'까지 데드라인 안이어야 한다 — 그래서 WRITE에도 retry-max-time이 있어야 부등식이 참이다.
  # 3개+ 동시 지연은 광역 이상이라 DeadlineExceeded→다음 주기(staleness 알림 소관).
  # ⚠️ 값은 **assignment 줄에서만** 뽑는다 — 주석의 버전 번호(--retry-max-time 7.32 류)를 head -1이
  #    주우면 증인이 공허해진다(01 리뷰 실측: 구판이 rmt=7·mt=7을 읽어 어떤 값이든 통과했다).
  #    같은 이유로 vacuity 가드(≥10)를 둔다 — 버전 조각을 주웠으면 여기서 죽는다.
  rl=$(grep -v '^[[:space:]]*#' "$F" | grep 'CURL_READ=')
  wl=$(grep -v '^[[:space:]]*#' "$F" | grep 'CURL_WRITE=')
  rmt=$(printf '%s' "$rl" | grep -oE -- '--retry-max-time [0-9]+' | grep -oE '[0-9]+$')
  wrmt=$(printf '%s' "$wl" | grep -oE -- '--retry-max-time [0-9]+' | grep -oE '[0-9]+$')
  mt=$(printf '%s' "$rl" | grep -oE -- ' --max-time [0-9]+' | grep -oE '[0-9]+$')
  adl=$(grep -oE 'activeDeadlineSeconds: [0-9]+' "$F" | grep -oE '[0-9]+$')
  [ -n "$rmt" ]
  [ -n "$wrmt" ]
  [ -n "$mt" ]
  [ -n "$adl" ]
  [ "$rmt" -ge 10 ]
  [ "$wrmt" -ge 10 ]
  [ "$mt" -ge 10 ]
  big=$(( rmt > wrmt ? rmt : wrmt ))
  [ $(( 2 * (big + mt) )) -lt "$adl" ]
}

@test "every curl-holding variable is timeout-bounded (third-var regression guard)" {
  # 두 이름(READ/WRITE)만 검사하면 무바운드 세 번째 var(PUSH="curl -fsS" 류)가 조용히 샌다 —
  # curl을 담는 var 전수와 그중 max-time 보유 수가 같아야 한다(바닥값 2는 열거 붕괴 방어).
  vars=$(grep -cE '[A-Z_]+="curl' "$F")
  bounded=$(grep -cE '[A-Z_]+="curl[^"]*--max-time [0-9]+' "$F")
  [ "$vars" -ge 2 ]
  [ "$vars" = "$bounded" ]
}

@test "no bare curl reaches the network even through pipes or substitutions" {
  # 라인 선두만 보면 `} | curl …`·`v=$(curl …)`가 샌다(01 리뷰 실측 — metrics push가 정확히
  # 파이프 형태). var 정의 2줄만 정당 보유처다. 주석(행두·꼬리)은 산문이라 먼저 걷는다 —
  # "curl 임시 경로" 류 언급이 오탐이 된다(스크립트 본문 문자열에 ` #`가 없어 꼬리 절단이 안전).
  run bash -c 'sed -e "s/^[[:space:]]*#.*//" -e "s/[[:space:]]#.*$//" "$1" | grep -nE "(^|[|;&(=[[:space:]])curl[[:space:]]" | grep -vE "CURL_(READ|WRITE)=\"curl"' _ "$F"
  [ "$status" -ne 0 ]
}

@test "the mutation image base stays bookworm-or-later (retry flags exist in its curl)" {
  # --retry-all-errors(7.71+)·--retry-max-time(7.32+) 의존 — 베이스가 alpine/busybox류로 바뀌면
  # 리컨실러가 unknown option으로 전 주기 실패한다. digest 핀과 Dockerfile은 따로 흐르므로
  # Dockerfile 베이스 선언을 앵커로 잡는다(2026-08-27 파드 실측: bookworm curl 7.88 — 두 플래그 동작).
  grep -q 'FROM debian:bookworm' "$ROOT/ops/pg-tools/Dockerfile"
}

@test "reconciler does not mount telegram; uses SA token for apiserver (API-user, token required)" {
  # 리컨실러는 apiserver를 읽으므로 SA 토큰이 필요(automount:false 금지 — du-exporter와 반대).
  run grep -q 'automountServiceAccountToken: false' "$F"; [ "$status" -ne 0 ]
  grep -q 'serviceAccountName: rewrite-reconciler' "$F"
}

@test "reconciler rbac is a resourceNames-scoped ClusterRole for the single traefik-ts service (cross-ns edge SA)" {
  # edge-namespaced kustomization의 namespace 트랜스포머가 네임스페이스드 Role을 edge로 강제(cross-ns 불가)하므로
  # ClusterRole + resourceNames로 traefik-ts 단일 서비스만 겨냥(최소권한 — get by name, list/watch 아님).
  grep -q 'kind: ClusterRole' "$R"
  grep -q 'resources: \["services"\]' "$R"
  grep -q 'resourceNames: \["traefik-ts"\]' "$R"
  grep -qE 'verbs: \["get"\]' "$R"
  grep -q 'kind: ClusterRoleBinding' "$R"
  # edge SA를 바인딩(subject namespace edge — 트랜스포머가 SA ns로 정정).
  grep -q 'name: rewrite-reconciler' "$R"
  grep -q 'namespace: edge' "$R"
}

@test "reconciler egress is locked: apiserver node-subnet + vmsingle + DNS, no internet (F13)" {
  grep -q '192.168.117.0/24' "$F"   # apiserver=노드서브넷(ClusterIP egress 불가 함정)
  grep -q '6443' "$F"
  grep -q '8428' "$F"               # vmsingle import
  grep -q 'k8s-app: kube-dns' "$F"  # DNS
  # F13: 인터넷 egress 없음 — 실제 ipBlock 규칙(cidr: 0.0.0.0/0) 부재 단언(설명 주석의 언급은 허용).
  run grep -qE 'cidr:[[:space:]]*[{]?[[:space:]]*0\.0\.0\.0/0' "$F"; [ "$status" -ne 0 ]
}

@test "reconciler is wired into kustomization" {
  grep -q 'rewrite-reconciler.yaml' "$ROOT/platform/adguard/prod/kustomization.yaml"
  grep -q 'rewrite-reconciler-rbac.yaml' "$ROOT/platform/adguard/prod/kustomization.yaml"
}
