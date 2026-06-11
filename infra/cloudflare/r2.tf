# 주의: homelab-tfstate는 Task 2.0에서 수동으로 생성하며, 일부러
# Terraform으로 관리하지 않는다 — 이 state 파일을 저장하는 버킷이라 자기참조가 된다.

# Postgres의 오프사이트 3번째 사본 (barman-cloud WAL + base + pg_dump 헤지).
resource "cloudflare_r2_bucket" "pg_backups" {
  account_id = var.cloudflare_account_id
  name       = "homelab-pg-backups-prod"
  location   = "WEUR"
}

# 오프사이트 보존 14일 (M4의 CNPG ScheduledBackup retention과 일치).
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

# 미디어 서비스의 내구성 있는 origin (로컬 SSD가 핫 캐시, §7).
resource "cloudflare_r2_bucket" "media" {
  account_id = var.cloudflare_account_id
  name       = "homelab-media-prod"
  location   = "WEUR"
}
