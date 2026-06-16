#!/usr/bin/env bats
# Valkey 백업 체인(Task 5.2b) — 공용 backup CronJob manifest의 정적 검증.
# 라이브 검증 함정 반영: R2 R&W 토큰은 HeadBucket 불가(no_check_bucket 필수),
# CronJob은 VM TZ(Asia/Seoul)로 발화, 신선도 메타는 teardown --delete-data의 게이트 소스.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CJ="$ROOT/platform/cache/prod/backup-cronjob.yaml"
}

@test "backup cronjob disables rclone bucket checks (R2 R&W token cannot HeadBucket)" {
  grep -q "RCLONE_CONFIG_R2_NO_CHECK_BUCKET" "$CJ"
  grep -A1 "RCLONE_CONFIG_R2_NO_CHECK_BUCKET" "$CJ" | grep -q '"true"'
}

@test "backup cronjob triggers BGSAVE and waits for completion before pulling the rdb" {
  grep -q "BGSAVE" "$CJ"
  grep -q "LASTSAVE" "$CJ"   # BGSAVE 완료 대기(LASTSAVE 변화 폴링) — 미완료 스냅샷 업로드 방지
  grep -q -- "--rdb" "$CJ"   # 네트워크 풀 — 인스턴스 PVC를 마운트하지 않는다
}

@test "backup cronjob records freshness metadata (timestamp + sha256) to R2" {
  grep -q "last_success.json" "$CJ"   # teardown --delete-data가 읽는 신선도 게이트 소스
  grep -q "sha256" "$CJ"
}

@test "backup cronjob documents Asia/Seoul firing and serializes runs" {
  grep -q "Asia/Seoul" "$CJ"                 # k3s VM TZ — UTC로 읽지 말 것
  grep -q "concurrencyPolicy: Forbid" "$CJ"
  grep -q "activeDeadlineSeconds" "$CJ"
}

@test "backup auth comes from per-instance acl secrets via env, never cli args" {
  grep -q "REDISCLI_AUTH" "$CJ"              # -a 인자는 ps에 노출된다 — env로만
  [ "$(grep -cE 'valkey-cli[^#]* -a ' "$CJ")" -eq 0 ]
  grep -q -- "-acl" "$CJ"                    # 인스턴스별 <name>-acl secret에서 자격 추출
}
