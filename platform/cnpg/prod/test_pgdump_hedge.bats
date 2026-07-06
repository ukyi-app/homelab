#!/usr/bin/env bats
f=platform/cnpg/prod/pgdump-hedge-cronjob.yaml
@test "hedge uses pg_dump piped to rclone, not barman" {
  grep -q 'pg_dump' "$f"
  grep -q 'rclone rcat' "$f"
  run grep -q 'barman' "$f"
  [ "$status" -ne 0 ]
}
@test "hedge writes a SEPARATE R2 prefix and prunes to 14 days" {
  grep -q 'r2:homelab-pg-backups-prod/pgdump/' "$f"
  grep -qE 'rclone delete .*--min-age 14d' "$f"
}
@test "hedge pulls rclone+aws creds from cnpg-r2-creds secret" {
  grep -q 'name: cnpg-r2-creds' "$f"
}

@test "hedge dumps as the managed superuser so it captures all objects (not just app-owned)" {
  # app 롤은 postgres 소유 객체(restore_canary 등)를 LOCK/덤프하지 못해 실패한다(라이브 검증).
  # 완전한 논리 백업은 superuser로 떠야 한다 — pg-app-credentials가 아니라 pg-superuser를 쓴다.
  grep -q 'name: pg-superuser' "$f"
  run grep -q 'name: pg-app-credentials' "$f"
  [ "$status" -ne 0 ]
}
@test "hedge uses the M6-built pg-tools image" {
  grep -q 'ghcr.io/ukyi-app/pg-tools:18-rclone' "$f"
}

@test "hedge dumps every logical Database CR plus bootstrap app (no silent coverage gap)" {
  # 헤지는 DB 단위 논리 백업이다 — databases/*.yaml의 Database CR이 DBS 목록에 빠지면
  # 그 DB는 barman 실패 시 복구 불가인데 알림은 녹색(job 완료 기반)인 무성 갭이 된다.
  # 새 DB 온보딩 시 이 테스트가 DBS 갱신을 강제한다.
  dbs=$(sed -n 's/^ *DBS="\([^"]*\)".*/\1/p' "$f")
  [ -n "$dbs" ]
  # 부트스트랩 app DB(restore_canary 보유)는 항상 포함
  case " $dbs " in *" app "*) ;; *) echo "missing: app"; return 1;; esac
  for y in platform/cnpg/prod/databases/*.yaml; do
    grep -q '^kind: Database$' "$y" || continue
    name=$(sed -n 's/^  name: \(.*\)$/\1/p' "$y" | head -1)
    [ -n "$name" ]
    case " $dbs " in *" $name "*) ;; *) echo "missing: $name ($y)"; return 1;; esac
  done
}

@test "hedge waits for pg-rw to be reachable before pg_dump (kube-router rule-install gap)" {
  # libpq는 첫 연결 거부에서 즉시 포기 — 새 파드의 첫 ClusterIP 접속이 kube-router 룰 설치 전
  # 갭에 떨어지면 RST(Connection refused)로 job이 실패한다(라이브 검증). 도달 대기 루프가 필요.
  grep -q '/dev/tcp/pg-rw.database.svc/5432' "$f"
}
@test "hedge container is hardened (no privesc, all caps dropped, seccomp RuntimeDefault)" {
  grep -q 'allowPrivilegeEscalation: false' "$f"
  grep -qF 'drop: [ALL]' "$f"
  grep -q 'type: RuntimeDefault' "$f"
}
