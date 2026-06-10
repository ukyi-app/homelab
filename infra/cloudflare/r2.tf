# NOTE: homelab-tfstate is created manually in Task 2.0 and deliberately
# NOT managed by Terraform — it stores this state file (would self-reference).

# Offsite copy-3 of Postgres (barman-cloud WAL + base + pg_dump hedge).
resource "cloudflare_r2_bucket" "pg_backups" {
  account_id = var.cloudflare_account_id
  name       = "homelab-pg-backups-prod"
  location   = "WEUR"
}

# 14d offsite retention (matches CNPG ScheduledBackup retention in M4).
resource "cloudflare_r2_bucket_lifecycle" "pg_backups" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.pg_backups.name
  rules = [{
    id         = "expire-14d"
    enabled    = true
    conditions = { prefix = "" }
    delete_objects_transition = {
      condition = { type = "Age", max_age = 1209600 } # 14 days in seconds
    }
  }]
}

# Durable origin for the media service (local SSD is the hot cache, §7).
resource "cloudflare_r2_bucket" "media" {
  account_id = var.cloudflare_account_id
  name       = "homelab-media-prod"
  location   = "WEUR"
}
