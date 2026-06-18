# infra/cloudflare

**역할** — Cloudflare terraform 루트: DNS·tunnel·R2 상태 버킷·WAF·cache·rate-limit. `apps.json`이 앱 공개(DNS) SSOT(`active` 플립).

**적용 방식** — **CI apply 전용**(좁은 DNS/tunnel 스코프라 안전): `iac.yaml`(push apply) + `tf-reconcile.yaml`(30분 드리프트 수렴). 앱 공개는 `tools/activate-app.ts` 게이트가 `active:true` 플립 → CI가 노출.

**라이브 디버그** — terraform plan/apply 로그(CI). 상태 버킷·bootstrap 절차는 런북 `docs/runbooks/02-cloud-iac-bootstrap.md`.

**함정 SSOT** — AGENTS.md "라이브에서 검증된 함정": 무료 플랜 rate-limit entitlement(period·mitigation_timeout 둘 다 10초 고정 등)는 plan 통과해도 apply에서만 400으로 드러남(cache.tf matches 함정 동일 계열). R2 Object R&W 토큰은 ListBuckets/HeadBucket 불가(rclone `no_check_bucket=true`; s3 백엔드는 무관). provider lock은 라이브 state writer 버전 이상으로 핀.
