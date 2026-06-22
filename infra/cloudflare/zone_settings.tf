# Cloudflare zone-level 엣지 하드닝을 GitOps SSOT로 코드화 (보안 감사 후속 #3: WAF-1 + SEC-2).
# zone setting이 terraform 밖이면 콘솔 수동값/약한 기본값에 의존하고, 드리프트가 git 리뷰·
# tf-reconcile(30분 수렴)로 감지되지 않는다 — 핵심 TLS/HTTPS 토글을 코드화해 드리프트 수렴 대상에 편입한다.
#
# 무료 플랜 entitlement: 아래는 전부 free-tier 지원 설정이라 rate-limit·cache의 Business 전용 함정
# (apply에서만 드러나는 400 "not entitled")과 달리 거부되지 않는다. provider v5의 cloudflare_zone_setting은
# setting별 단일 리소스(v4의 zone_settings_override 대체)다.
#
# ssl 모드(Flexible/Full/Strict)는 의도적으로 비관리: 공개 호스트는 전부 cloudflared 터널 CNAME이라
# CF→origin 직접 풀이 없고 터널 leg가 독립 암호화되므로 ssl 모드는 무의미하다(감사 SEC-1 판정).

# 평문 http → https 강제 리다이렉트.
resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = data.cloudflare_zone.this.zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# 레거시 TLS 1.0/1.1 다운그레이드 차단 — 최소 1.2 협상.
resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = data.cloudflare_zone.this.zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

# TLS 1.3 협상 활성화.
resource "cloudflare_zone_setting" "tls_1_3" {
  zone_id    = data.cloudflare_zone.this.zone_id
  setting_id = "tls_1_3"
  value      = "on"
}

# opportunistic encryption 비활성 — always_use_https와 정합(평문 폴백 표면 제거).
resource "cloudflare_zone_setting" "opportunistic_encryption" {
  zone_id    = data.cloudflare_zone.this.zone_id
  setting_id = "opportunistic_encryption"
  value      = "off"
}

# 응답 HTML 내 http:// 링크를 https://로 재작성(mixed-content 완화).
resource "cloudflare_zone_setting" "automatic_https_rewrites" {
  zone_id    = data.cloudflare_zone.this.zone_id
  setting_id = "automatic_https_rewrites"
  value      = "on"
}

# 무료 플랜의 1차 봇/스크레이퍼 방어선 — 의심스러운 클라이언트(악성 UA 등)에 챌린지.
resource "cloudflare_zone_setting" "browser_check" {
  zone_id    = data.cloudflare_zone.this.zone_id
  setting_id = "browser_check"
  value      = "on"
}

# 보안 수준 baseline을 명시 고정(콘솔에서 essentially_off로 낮춰지는 무성 회귀 차단).
resource "cloudflare_zone_setting" "security_level" {
  zone_id    = data.cloudflare_zone.this.zone_id
  setting_id = "security_level"
  value      = "medium"
}

# HSTS — 브라우저가 *.ukyi.app을 HTTPS로만 접속하도록 강제(SSL-strip 다운그레이드 차단).
# include_subdomains로 내부 *.home.ukyi.app(traefik LE 와일드카드 cert, 항상 HTTPS 서빙)까지 커버.
# preload는 브라우저 프리로드 리스트 등재(되돌리기 어려운 영구 커밋)라 false 유지 — 운영 안정 후 별도 검토.
resource "cloudflare_zone_setting" "security_header" {
  zone_id    = data.cloudflare_zone.this.zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      include_subdomains = true
      max_age            = 15552000 # 180일
      nosniff            = true
      preload            = false
    }
  }
}
