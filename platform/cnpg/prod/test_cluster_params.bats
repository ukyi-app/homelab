#!/usr/bin/env bats
f=platform/cnpg/prod/cluster.yaml

@test "single instance, HA off" { grep -qE 'instances:\s*1' "$f"; }

@test "tuned params exactly match the design" {
  grep -q 'shared_buffers: "256MB"' "$f"
  grep -q 'effective_cache_size: "512MB"' "$f"
  grep -q 'work_mem: "8MB"' "$f"
  grep -q 'maintenance_work_mem: "128MB"' "$f"
  grep -q 'max_connections: "50"' "$f"
  grep -q 'archive_timeout: "5min"' "$f"
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
  [ "$status" -ne 0 ]
}

@test "Cluster CR carries sync-wave -1 (Ready before app migrations)" {
  grep -qE 'argocd.argoproj.io/sync-wave:\s*"-1"' "$f"
}

@test "pg bootstraps by RECOVERY from the Mac archive, not initdb (G6)" {
  # 계획서 G6: "NUC의 primary pg가 initdb가 아니라 **recovery로** 기동 + serverName 분리".
  # ⚠️ restore_canary는 더 이상 git으로 시드하지 않는다 — recovery 스키마에 postInitApplicationSQL이
  #    **없고**(CNPG 1.29.1 CRD 실측), canary는 Mac base backup에 들어 있어 복구와 함께 딸려온다.
  src="$(yq -e '.spec.bootstrap.recovery.source' "$f")"
  printf '%s' "$src" | grep -qxF -- 'pg-mac'
  run yq -e '.spec.bootstrap.initdb' "$f"
  [ "$status" -ne 0 ]
}

@test "the archive WRITE serverName differs from the recovery READ serverName (archive separation — PERMANENT, not a cutover revert item)" {
  # ⚠️ 이 레포에서 되돌리기가 가장 비싼 불변식이다. 같아지면 라이브 Mac과 NUC 두 primary가 같은 R2
  #    prefix에 아카이브해 타임라인이 섞이고, 오프사이트 PITR 경로(restore.md 경로 A)가 망가진다.
  #    R2에 버저닝이 없어(infra/cloudflare/r2.tf) 되돌릴 수 없다. 계획서 §3.4의 ❌ 항목.
  w="$(yq -e '.spec.plugins[] | select(.name == "barman-cloud.cloudnative-pg.io") | .parameters.serverName' "$f")"
  r="$(yq -e '.spec.externalClusters[] | select(.name == "pg-mac") | .plugin.parameters.serverName' "$f")"
  [ -n "$w" ]
  [ -n "$r" ]
  # ⚠️ `[ "$w" != "$r" ]`를 중간에 쓰면 bats가 침묵 통과시킨다(bash 3.2 errexit 면제).
  #    printf|grep -qxF 형태로 "같지 않음"을 마지막 명령 부정으로 단언한다.
  printf '%s' "$r" | grep -qxF -- 'pg'
  ! printf '%s' "$w" | grep -qxF -- "$r"
}

@test "the recovery source is READ-ONLY (isWALArchiver on externalClusters is explicitly false)" {
  # 켜면 복구 원본(=Mac 아카이브)에도 쓰기가 붙어 아카이브 분리가 통째로 무의미해진다.
  # ⚠️ 불변식은 "미기재"가 아니라 **명시적 false**다. externalClusters는 listType 미지정(SSA atomic)이라
  #    webhook 주입 기본값이 매니페스트에 없으면 ArgoCD가 영구 OutOfSync를 낸다 — 2026-08-14 NUC 실측:
  #    cnpg-data가 Healthy인 채 5분마다 partial sync를 반복했고, 라이브와의 diff는 이 두 필드뿐이었다.
  # ⚠️ 여기서 `yq -e`를 쓰지 말 것 — `-e`는 **값이 false면 exit 1**이라(null과 구별하지 않는다)
  #    올바른 매니페스트에서 테스트가 red가 된다. `-e` 없이 읽고 정확 일치로 단언하면
  #    미기재(`null`)와 `false`가 갈린다.
  v="$(yq '.spec.externalClusters[] | select(.name == "pg-mac") | .plugin.isWALArchiver' "$f")"
  printf '%s' "$v" | grep -qxF -- 'false'
}

@test "externalClusters plugin spells out the webhook-injected defaults (SSA atomic list — permanent OutOfSync otherwise)" {
  # plugins[] 리스트는 이미 enabled/isWALArchiver를 명시하고 있었는데 **형제인 externalClusters[]만
  # 빠져 있었다**. 같은 클래스의 결함이므로 두 자리를 함께 잠근다.
  e="$(yq -e '.spec.externalClusters[] | select(.name == "pg-mac") | .plugin.enabled' "$f")"
  printf '%s' "$e" | grep -qxF -- 'true'
  pe="$(yq -e '.spec.plugins[] | select(.name == "barman-cloud.cloudnative-pg.io") | .enabled' "$f")"
  printf '%s' "$pe" | grep -qxF -- 'true'
  pw="$(yq -e '.spec.plugins[] | select(.name == "barman-cloud.cloudnative-pg.io") | .isWALArchiver' "$f")"
  printf '%s' "$pw" | grep -qxF -- 'true'
}
