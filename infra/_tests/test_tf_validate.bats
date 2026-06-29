#!/usr/bin/env bats

@test "make tf-validate exits 0 across all roots" {
  run make tf-validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloudflare: validated"* ]]
  [[ "$output" == *"tailscale: validated"* ]]
  [[ "$output" == *"github: validated"* ]]
}

@test "DR R2 buckets are guarded by prevent_destroy (offsite backup + media origin)" {
  # pg_backups(오프사이트 3차 사본)·media(유일 내구 origin)는 무인 apply의 destroy로부터 보호돼야 한다.
  [ "$(grep -c 'prevent_destroy = true' infra/cloudflare/r2.tf)" -eq 2 ]
}

@test "app DNS is a distinct resource (cloudflare_dns_record.app) — destroy-guard allow targets app hosts only" {
  # apex/www=cloudflare_dns_record.public(site_hosts, 구조적·가드 보호), 앱 host=cloudflare_dns_record.app
  # (app_hosts, 자동 관리). allow 정규식 ^cloudflare_dns_record\.app\[ 가 앱 DNS만 자동 허용하는 전제.
  d=infra/cloudflare/dns.tf
  grep -qE 'resource "cloudflare_dns_record" "app"' "$d" \
    && grep -qE 'resource "cloudflare_dns_record" "public"' "$d" \
    && grep -qE 'for_each = local\.site_hosts' "$d" \
    && grep -qE 'for_each = local\.app_hosts' "$d"
}
