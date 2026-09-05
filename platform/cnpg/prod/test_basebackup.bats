#!/usr/bin/env bats
pvc=platform/cnpg/prod/basebackup-pvc.yaml
cj=platform/cnpg/prod/basebackup-cronjob.yaml
@test "staging PVC is on bulk-ssd (external SSD), never standard" {
  grep -q 'storageClassName: bulk-ssd' "$pvc"
}
@test "cronjob runs pg_basebackup and prunes to 7 days" {
  grep -q 'pg_basebackup' "$cj"
  grep -qE 'mtime \+7' "$cj"
  grep -qE 'schedule:\s+"30 2 \* \* \*"' "$cj" # k8s 5-field cron, 02:30
}
@test "cronjob runs non-root 26 and mounts only bulk-ssd PVC" {
  grep -q 'runAsUser: 26' "$cj"
  grep -q 'claimName: pg-basebackup-local' "$cj"
  # ⚠️ 위 존재 단언은 volumes 집합의 상한이 아니다 — 다른 volume을 추가해도 무증인이었다
  # (감사 6라운드 티켓64 c64-7 실측: emptyDir `scratch` volume을 더해도 이 @test는 초록이었다).
  vols="$(yq '[.spec.jobTemplate.spec.template.spec.volumes[].name] | sort | join(",")' "$cj")"
  [ "$vols" = "backup" ]
}
@test "cronjob emits the local-basebackup breadcrumb metric M5 alerts on" {
  grep -q 'cnpg.io/backupRole: local-basebackup' "$cj"
}
@test "the manifest is wired into the kustomization (prune would delete it otherwise)" {
  # ⚠️ cnpg-data App은 prune:true + selfHeal:true라 resources에서 한 줄이 사라지는 것이 곧
  #    클러스터에서의 삭제다. 위 @test들은 파일을 직접 grep할 뿐 배선을 안 봐서, 배선을 지워도
  #    PR 게이트가 전건 초록이었다(실측). 사후 검출은 LocalBasebackupStale뿐이다.
  # ⚠️ 원문 grep이 아니라 파싱된 resources를 본다 — 주석 줄·들여쓰기 어긋난 줄이 통과한다
  #    (tests/gates의 victoria-stack 배선 대조 @test가 세운 레포 관례).
  run yq '.resources | contains(["basebackup-cronjob.yaml"])' platform/cnpg/prod/kustomization.yaml
  printf '%s' "$output" | grep -qxF -- 'true'
}

@test "cronjob waits for pg-rw to be reachable before pg_basebackup (kube-router rule-install gap)" {
  # libpq는 첫 연결 거부에서 즉시 포기 — 새 파드의 첫 ClusterIP 접속이 kube-router 룰 설치 전
  # 갭에 떨어지면 RST(Connection refused)로 job이 실패한다(라이브 검증). 도달 대기 루프가 필요.
  grep -q '/dev/tcp/pg-rw.database.svc/5432' "$cj"
}
@test "cronjob container is hardened (no privesc, all caps dropped, seccomp RuntimeDefault)" {
  grep -q 'allowPrivilegeEscalation: false' "$cj"
  grep -qF 'drop: [ALL]' "$cj"
  grep -q 'type: RuntimeDefault' "$cj"
}

@test "cluster pg_hba allows postgres replication so pg_basebackup can connect" {
  # CNPG 기본 pg_hba는 replication을 streaming_replica(cert)만 허용 — postgres 유저의 replication
  # 연결이 거부돼 pg_basebackup이 실패한다(라이브 함정). cluster.yaml의 두 줄이 사라지면 여기서 잡힌다.
  cluster=platform/cnpg/prod/cluster.yaml
  grep -qE 'hostssl replication postgres' "$cluster"
  grep -qE '\bhost replication postgres' "$cluster"
  # 존재 2줄은 원소를 못박지만 집합 상한이 없어 `host all all 0.0.0.0/0 trust` 같은 3번째
  # 줄이 더해져도 무증인이었다(2026-09-03 실측) — length 2로 닫는다.
  h="$(yq '.spec.postgresql.pg_hba | length' "$cluster")"; printf '%s' "$h" | grep -qxF -- '2'
  # spec-others-1(round8, 심각도 high→medium — 현재 노출 0·자동 writer 없음·도달 경로는 리뷰
  # 통과 손 편집 1건): 위 grep들은 부분 문자열 매치라 CIDR·인증방식이 뒤에 뭘 붙여도 통과한다.
  # `10.42.0.0/16 scram-sha-256` -> `0.0.0.0/0 trust`로 뮤테이션해도 이 파일(8/8)·
  # test_cluster_params.bats(10/10) 전건 초록이었다(2026-09-05 격리 재현) — CIDR/인증방식 값
  # 자체는 어느 가드도 안 쟀다. 형제 관용구(test_object_store.bats:44 "yq로 값 뽑아 grep -qxF")로
  # 원소 값까지 고정한다(raw 파일 grep보다 들여쓰기/따옴표 표기 변화에 안 깨진다).
  p0="$(yq '.spec.postgresql.pg_hba[0]' "$cluster")"; printf '%s' "$p0" | grep -qxF -- 'hostssl replication postgres 10.42.0.0/16 scram-sha-256'
  p1="$(yq '.spec.postgresql.pg_hba[1]' "$cluster")"; printf '%s' "$p1" | grep -qxF -- 'host replication postgres 10.42.0.0/16 scram-sha-256'
}
