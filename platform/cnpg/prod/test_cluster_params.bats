#!/usr/bin/env bats
# ⚠️ grep 부재 단언은 `[ "$status" -eq 1 ]`이다(피연산자가 단일 파일이라 그것으로 닫힌다).
#    아래 `yq -e` 자리는 **비대상**이다 — yq는 값이 false여도 exit 1이라 rc가 부재를 뜻하지 않는다
#    (이 파일 :82 @test의 주석이 그 함정의 원장 행이다).
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
f=platform/cnpg/prod/cluster.yaml

@test "single instance, HA off" { grep -qE 'instances:\s*1' "$f"; }

@test "tuned params exactly match the design" {
  grep -q 'shared_buffers: "256MB"' "$f"
  grep -q 'effective_cache_size: "512MB"' "$f"
  grep -q 'work_mem: "8MB"' "$f"
  grep -q 'maintenance_work_mem: "128MB"' "$f"
  grep -q 'max_connections: "50"' "$f"
  grep -q 'archive_timeout: "5min"' "$f"
  grep -q 'wal_compression: "on"' "$f"
  grep -q 'max_wal_size: "1GB"' "$f"
  grep -q 'min_wal_size: "256MB"' "$f"
  # 존재 9 + length 9 = 정확 집합(추가·삭제·치환 전부 red) — 하한 6줄만으로는 fsync/full_page_writes
  # 같은 원소 추가는 물론, 무증인 3키를 다른 키로 치환하는 편집도 무증인이었다(2026-09-03 실측).
  n="$(yq '.spec.postgresql.parameters | length' "$f")"; printf '%s' "$n" | grep -qxF -- '9'
}

@test "memory limit is 1Gi and shared_buffers is <= 1/4 of it" {
  grep -q 'memory: 1Gi' "$f"   # limit
  grep -q 'memory: 768Mi' "$f" # request
  # 256MB <= 256MB (= 1Gi/4) : limit 연동 불변식 성립
}

@test "PGDATA on standard SC, WAL on a SEPARATE standard PVC, never bulk-ssd" {
  grep -q 'storageClass: standard' "$f"
  grep -qE 'walStorage:' "$f"
  run grep -q 'bulk-ssd' "$f"
  [ "$status" -eq 1 ]
}

@test "Cluster CR carries sync-wave -1 (Ready before app migrations)" {
  grep -qE 'argocd.argoproj.io/sync-wave:\s*"-1"' "$f"
}

@test "pg bootstraps by INITDB with no external recovery source (post-cutover shape — audit 9)" {
  # ✅ 2026-08-17 컷오버: G6("NUC의 primary pg가 recovery로 기동")은 **1회성 목적**이었고 달성됐다
  #    — 라이브 pg는 2026-08-13에 pg-mac에서 복구돼 timeline=2로 살아 있다. 그 뒤로도 recovery
  #    블록을 남겨두면 재생성 시 **얼어붙은 Mac 아카이브로 조용히 복구**되어 그것을 pg-nuc/에
  #    아카이브한다 → 살아 있는 아카이브의 타임라인 오염. initdb면 빈 DB로 요란하게 뜬다. ADR 0006.
  # ⚠️ 이 @test는 방향이 뒤집힌 것이 아니라 **형태를 고정하는 자리**다 — recovery로 되돌아가면 red.
  run yq -e '.spec.bootstrap.recovery' "$f"
  [ "$status" -ne 0 ]
  run yq -e '.spec.externalClusters' "$f"
  [ "$status" -ne 0 ]
  db="$(yq -e '.spec.bootstrap.initdb.database' "$f")"
  printf '%s' "$db" | grep -qxF -- 'app'
}

@test "initdb seeds restore_canary so a cold rebuild leaves the weekly drill working" {
  # ⚠️ recovery 스키마엔 postInitApplicationSQL이 **없어서**(CNPG 1.29.1 CRD 실측) 이전 브랜치
  #    형태에서는 이 시드가 통째로 빠져 있었다. initdb로 돌아오면서 되살아난다.
  # ⚠️ 이 시드는 **1회성**이다 — 라이브 canary는 영구히 1행이고(실측 2026-08-17: EXPECTED_ROWS=1)
  #    아무도 INSERT하지 않는다. 즉 restore-drill의 행 수 비교는 상수 비교이고 아카이브 신선도를
  #    증명하지 못한다. 진짜 복구 여부는 그 스크립트의 SAW_NONHEALTHY 증인이 본다(M17/PR #482).
  sql="$(yq -e '.spec.bootstrap.initdb.postInitApplicationSQL | join(" ")' "$f")"
  printf '%s' "$sql" | grep -qF -- 'CREATE TABLE IF NOT EXISTS restore_canary'
  printf '%s' "$sql" | grep -qF -- 'INSERT INTO restore_canary'
}

@test "the archive WRITE serverName is pinned to pg-nuc and never falls back to the Mac prefix" {
  # ⚠️ 이 레포에서 되돌리기가 가장 비싼 불변식이다. 이 값 하나가
  #    s3://homelab-pg-backups-prod/<serverName>/{base,wals}/ 를 통째로 정하고, R2엔 버저닝이
  #    없어(infra/cloudflare/r2.tf) 섞인 타임라인을 되돌릴 수 없다. 계획서 §3.4의 ❌ 항목.
  # ✅ **계약 평행이동 (2026-08-17, ADR 0006).** 이 @test는 예전에 "쓰기 ≠ 읽기"를 단언했고 이름에
  #    PERMANENT를 달고 있었다. 컷오버로 externalClusters(읽기 원본)가 **물리적으로 사라져** 그 축은
  #    성립하지 않는다. 축소가 아니라 이전이다 — 남은 쓰기 축을 **리터럴로** 고정한다.
  #    (`check-pg-servername.sh` (B)의 값 고정은 CI가 main 진입 시에만 env를 채우므로 로컬·브랜치에선
  #     무방비다. 그 구멍을 이 @test가 메운다.)
  w="$(yq -e '.spec.plugins[] | select(.name == "barman-cloud.cloudnative-pg.io") | .parameters.serverName' "$f")"
  printf '%s' "$w" | grep -qxF -- 'pg-nuc'
  # Mac prefix로의 회귀를 명시적으로 거부한다(음성 단언 — 마지막 명령 부정으로만 쓴다).
  ! printf '%s' "$w" | grep -qxF -- 'pg'
}

@test "there is exactly ONE archive writer and no external recovery source remains" {
  # 아카이브 writer가 둘이 되는 순간 같은 prefix에 두 타임라인이 섞인다. 컷오버 이전에는
  # externalClusters의 isWALArchiver=false가 그 방어였는데, 이제 원본 자체가 없으므로
  # **writer 수가 정확히 1**임을 직접 센다(열거 붕괴 방지: 0건도 red).
  n="$(yq -e '[.spec.plugins[] | select(.isWALArchiver == true)] | length' "$f")"
  printf '%s' "$n" | grep -qxF -- '1'
  run yq -e '.spec.externalClusters' "$f"
  [ "$status" -ne 0 ]
}

@test "plugins spells out the webhook-injected defaults (SSA atomic list — permanent OutOfSync otherwise)" {
  # plugins[]는 listType 미지정(SSA atomic)이라 webhook 주입 기본값이 매니페스트에 없으면 ArgoCD가
  # 영구 OutOfSync를 낸다 — 2026-08-14 NUC 실측: cnpg-data가 Healthy인 채 5분마다 partial sync를
  # 반복했고 라이브와의 diff는 이 필드들뿐이었다. (형제인 externalClusters도 같은 클래스였는데
  # 컷오버로 그 리스트 자체가 사라졌다 — 되살릴 일이 생기면 거기도 반드시 명시할 것.)
  # ⚠️ `yq -e`는 **값이 false면 exit 1**이라(null과 구별하지 않는다) 불리언엔 `-e` **없이** 읽는다.
  #    `-e`로 읽으면 `enabled: false` 회귀에서 단언 실패가 아니라 **명령 치환 실패**로 죽어
  #    진단이 "false여야 하는데 true다"가 아니라 "yq가 죽었다"로 흐려진다. 미기재(null)와 false를
  #    가르는 것도 이 형태뿐이다 — `docs/traps.md`가 이 파일을 그 함정의 가드로 지목하고 있고,
  #    컷오버로 externalClusters가 사라지면서 **이 두 줄이 그 원장 행의 유일한 실행체가 됐다.**
  pe="$(yq '.spec.plugins[] | select(.name == "barman-cloud.cloudnative-pg.io") | .enabled' "$f")"
  printf '%s' "$pe" | grep -qxF -- 'true'
  pw="$(yq '.spec.plugins[] | select(.name == "barman-cloud.cloudnative-pg.io") | .isWALArchiver' "$f")"
  printf '%s' "$pw" | grep -qxF -- 'true'
}
