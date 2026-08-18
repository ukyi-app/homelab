#!/usr/bin/env bats
f=platform/cnpg/prod/pgdump-hedge-cronjob.yaml
@test "hedge uses pg_dump piped to rclone, not barman" {
  grep -q 'pg_dump' "$f"
  grep -q 'rclone rcat' "$f"
  run grep -q 'barman' "$f"
  [ "$status" -ne 0 ]
}
@test "hedge writes a CLUSTER-SPECIFIC R2 prefix and prunes only that prefix" {
  # ⚠️ 프루닝(`--min-age 14d`)이 prefix 전체를 훑는다. 라이브 Mac과 prefix를 공유하면 **상대편의
  #    덤프를 지운다** — 파일명이 `${DB}-${TS}`라 두 클러스터를 구별할 수 없다.
  #    계획서 §3.4의 공유 자원 표에 빠져 있던 충돌이다(pgdump·캐시 2건 누락).
  grep -qE '^[^#]*DUMP_PREFIX=' "$f"
  grep -q 'pgdump-nuc' "$f"
  grep -qE 'rclone delete .*\$\{DUMP_PREFIX\}.*--min-age 14d' "$f"
  # 공유 prefix로 되돌아가면 red — 비-주석 줄만 본다(주석이 옛 경로를 설명한다).
  run grep -nE '^[^#]*r2:homelab-pg-backups-prod/pgdump/' "$f"
  [ "$status" -ne 0 ]
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

@test "the r4 hedge alert names the SAME prefix the cronjob writes to (drift guard)" {
  # 2026-08-18: r4의 PgDumpHedgeStale description이 Mac 시대 `pgdump/`를 가리킨 채 남아 있었다.
  # #0006이 경로 B를 `pgdump-nuc/`로 정정할 때 런북은 고쳤지만 알림 문구는 놓쳤다 — 온콜이
  # 새벽에 읽는 문장이 존재하지 않는 prefix를 가리키면 "덤프가 하나도 없다"는 오진으로 이어진다.
  # 리터럴을 유지하되(문장 가독성) 정본에서 파생해 대조한다.
  seg=$(sed -n 's|^ *DUMP_PREFIX="[^"]*/\([^"/]*\)".*|\1|p' "$f" | head -1)
  [ -n "$seg" ]
  r4=platform/victoria-stack/prod/rules/r4-storage-backup.yaml
  desc=$(grep -n 'alert: PgDumpHedgeStale' -A8 "$r4" | grep 'description:')
  [ -n "$desc" ]
  case "$desc" in *"$seg/"*) ;; *) echo "r4 description이 DUMP_PREFIX의 마지막 세그먼트($seg/)를 안 담는다: $desc"; return 1;; esac
}
