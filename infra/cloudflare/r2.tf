# 주의: homelab-tfstate는 Task 2.0에서 수동으로 생성하며, 일부러
# Terraform으로 관리하지 않는다 — 이 state 파일을 저장하는 버킷이라 자기참조가 된다.

# Postgres의 오프사이트 3번째 사본 (barman-cloud WAL + base + pg_dump 헤지).
resource "cloudflare_r2_bucket" "pg_backups" {
  account_id = var.cloudflare_account_id
  name       = "homelab-pg-backups-prod"
  location   = "WEUR"

  # DR 핵심 자산 — 실수 리네임/리팩터가 destroy로 산출돼도 terraform이 거부(무인 apply 보호).
  lifecycle {
    prevent_destroy = true
  }
}

# 오프사이트 보존 14일 (M4의 CNPG ScheduledBackup retention과 일치).
# ⚠️ `prefix = ""`는 **버킷 전체**다 — `pg/`(Mac 아카이브)·`pg-nuc/`·`pgdump-nuc/`를 가리지 않고 지운다.
#    위 `prevent_destroy`는 **버킷 삭제**를 막지 객체 만료를 막지 않는다. 즉 "옛 prefix를 아카이브로
#    남겨 둔다"는 계획은 여기에 예외를 적지 않는 한 성립하지 않는다(docs/decisions/0006의 정정 문단 —
#    그 ADR이 `pg/`를 "마지막 독립 사본"으로 전제했는데 이 규칙이 ≈14일 뒤 지웠다).
#    보존할 prefix가 생기면 이 rules에 조건을 나눠 적을 것.
resource "cloudflare_r2_bucket_lifecycle" "pg_backups" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.pg_backups.name
  rules = [{
    id         = "expire-14d"
    enabled    = true
    conditions = { prefix = "" }
    delete_objects_transition = {
      condition = { type = "Age", max_age = 1209600 } # 14일(초 단위)
    }
  }]
}

# Valkey 캐시의 오프사이트 RDB 스냅샷 (cache-backup CronJob → rclone rcat).
# PG/미디어와 달리 캐시는 재구축 가능(유일 내구 사본 아님)이라 prevent_destroy 미설정 —
# 캐시 teardown 시 버킷도 정리 가능해야 한다.
resource "cloudflare_r2_bucket" "cache_backups" {
  account_id = var.cloudflare_account_id
  name       = "homelab-cache-backups-prod"
  location   = "WEUR"
}

# 오프사이트 보존 14일 (cache-backup CronJob의 `rclone delete --min-age 14d`와 정합).
resource "cloudflare_r2_bucket_lifecycle" "cache_backups" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.cache_backups.name
  rules = [{
    id         = "expire-14d"
    enabled    = true
    conditions = { prefix = "" }
    delete_objects_transition = {
      condition = { type = "Age", max_age = 1209600 } # 14일(초 단위)
    }
  }]
}

# 미디어 서비스의 내구성 있는 origin (로컬 SSD가 핫 캐시, §7).
resource "cloudflare_r2_bucket" "media" {
  account_id = var.cloudflare_account_id
  name       = "homelab-media-prod"
  location   = "WEUR"

  # 미디어 origin은 R2가 유일 내구 사본(로컬은 캐시) — 우발적 destroy 거부.
  lifecycle {
    prevent_destroy = true
  }
}
