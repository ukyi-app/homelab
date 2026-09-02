# infra/cloudflare

**역할** — Cloudflare terraform 루트: DNS·tunnel·R2 상태 버킷·WAF·cache·rate-limit. `apps.json`이 앱 공개(DNS) SSOT(`active` 플립).

**적용 방식** — **CI apply**(좁은 DNS/tunnel 스코프라 안전): `iac.yaml`(push apply) + `tf-reconcile.yaml`(30분 드리프트 수렴). create-app PR 머지가 앱 공개 승인(`apps.json active:true`)이며, 머지 후 CI가 DNS/tunnel을 노출한다. **예외** — tf-destroy-guard가 `blocked-delete`를 내면 CI가 apply를 건너뛰므로 owner가 로컬에서 apply한다(`tf-reconcile.yaml`의 telegram ident가 그 경로를 지시). backend에 state 잠금이 없으므로(`backend.tf` 헤더) 로컬 apply 전에 `gh run list -w tf-reconcile.yaml --status in_progress`가 비어 있는지 확인할 것.

**라이브 디버그** — terraform plan/apply 로그(CI). 상태 버킷·bootstrap 절차는 런북 `docs/runbooks/02-cloud-iac-bootstrap.md`.

**함정 SSOT** — docs/traps-detail.md: 무료 플랜 rate-limit entitlement(period·mitigation_timeout 둘 다 10초 고정 등)는 plan 통과해도 apply에서만 400으로 드러남(cache.tf matches 함정 동일 계열). R2 Object R&W 토큰은 ListBuckets/HeadBucket 불가(rclone `no_check_bucket=true`; s3 백엔드는 무관). provider lock은 라이브 state writer 버전 이상으로 핀.
