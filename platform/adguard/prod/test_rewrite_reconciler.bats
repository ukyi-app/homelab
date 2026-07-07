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

@test "reconciler bounds every curl via a shared CURL var (connect/total timeout + connrefused retry)" {
  # F6/F12: 전 네트워크 호출이 타임아웃 바운드. 직접 curl 호출(라인 선두 공백 뒤 curl) 없음.
  grep -q 'connect-timeout 5' "$F"
  grep -q 'max-time 20' "$F"
  # 전이적 연결거부 재시도 — adguard/apiserver 롤링 중 ~2s 갭에 backoffLimit:0 Job이 Failed→Degraded로
  # 얼어붙던 라이브 함정 회피(4xx는 재시도 안 함).
  grep -q 'retry-connrefused' "$F"
  run grep -cE '^[[:space:]]*curl[[:space:]]' "$F"
  [ "$output" = "0" ] || [ "$status" -ne 0 ]
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
  grep -q '192.168.139.0/24' "$F"   # apiserver=노드서브넷(ClusterIP egress 불가 함정)
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
