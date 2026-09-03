#!/usr/bin/env bats
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
f=platform/cnpg/prod/pooler.yaml
@test "pooler is type rw on cluster pg" {
  grep -q 'type: rw' "$f"
  grep -qE 'name:\s+pg$' "$f"
}
@test "transaction pooling, sane sizing under max_connections=50" {
  grep -q 'poolMode: transaction' "$f"
  # 예약 파라미터 pool_mode가 parameters에 되살아나지 않게 가드 (webhook 거부 → sync 무한 루프)
  # 중간 위치라 `! grep`은 bats가 침묵 통과 → run+status로 강제(check-bats-style.sh).
  run grep -q 'pool_mode:' "$f"
  [ "$status" -eq 1 ]
  # ⚠️ 예전 판은 **키 존재**만 봤다 — default_pool_size를 500으로, max_client_conn을 20000으로
  #    올려도 3/3 초록이었다(실측). 레포 전역에서 이 두 값의 다른 증인도 0건이다.
  #    @test 이름이 명시한 「under max_connections=50」이라는 관계가 무증인이었다.
  # 사이징 SSOT: 상한은 Σ_pools(default_pool_size + reserve_pool_size) ≤ cluster.yaml의
  #   max_connections(50) − superuser_reserved(3). PgBouncer 풀은 **(user, db) 쌍 단위**이고
  #   CNPG Pooler는 와일드카드 DB 엔트리라 **증가 축은 instances가 아니라 앱 수**다
  #   (tools/provision-db.ts:155 — 앱마다 owner 롤이 POOLER_HOST 경유).
  #   현재 2풀 × (20+5) = 50 = 예산 상단이다.
  # ⇒ 그래서 `dp × instances ≤ mc − 예약분` 같은 파생 등식은 **쓰지 않는다** — 풀 다중도를 안 봐서
  #   오늘도 초록이고 앱이 3개가 되는 순간(create-database 자동 경로)에도 초록이라, 틀린 등식을
  #   코드로 굳히며 vacuous green을 새로 하나 세우는 꼴이 된다. 리터럴을 고정해 값 변경이 즉시
  #   red가 되게 하고, 사람이 위 등식을 다시 계산하도록 강제한다(형제 test_cluster_params.bats:12-17).
  # (예산이 이미 상단이라는 점 — 3번째 앱에서 초과 — 은 별건이다. 여기서 고치지 않는다.)
  grep -q 'max_client_conn: "200"' "$f"
  grep -q 'default_pool_size: "20"' "$f"
  grep -q 'reserve_pool_size: "5"' "$f"
}
@test "transaction pooler ignores client server-GUC startup params (libpq/node-pg compat)" {
  # statement_timeout 등을 무시하지 않으면 클라이언트 연결이 "unsupported startup parameter"로 거부됨
  grep -q 'ignore_startup_parameters:' "$f"
  grep -E 'ignore_startup_parameters:' "$f" | grep -q 'statement_timeout'
}
