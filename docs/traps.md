# 함정 enforcement 원장 (additive)

`docs/traps-detail.md`가 함정의 **단일 SSOT**다(설명·근거 포함, doc-only 포함 전부; AGENTS.md엔 한줄 인덱스만).
이 원장은 그중 **실행 가능한 가드로 강제된 함정만** 추적해, 가드 파일이 삭제·리네임됐는데 함정이
다시 물리는 드리프트를 `make verify-traps`로 차단한다. 여기 없는 함정 = doc-only(traps-detail.md가 유일 SSOT).

- **검사 방향**: `scripts/verify-traps.sh`는 아래 `guard` 열의 백틱 경로가 **실재하는지** + `docs/traps-detail.md`의
  `> 가드:` 주석 경로가 **이 원장에도 추적되는지**(역방향 guard-path-tie — SSOT↔원장 내용 드리프트 차단)를 본다(enforced인데
  파일 없음 = 거짓 안심 → 실패). 가드의 *내용 정확성*은 각 가드 테스트 자신이 책임진다.
- **where**: `gate`=ci.yaml job `gate`가 수집 · `verify`=verify.yaml(pre-commit/sops/ledger) · `iac`=iac/tf-reconcile · `local`=make/pre-commit 로컬.
- 새 가드 테스트를 추가하면 이 표에도 한 줄 추가한다(리네임 시 verify-traps가 강제로 알려준다).

| 함정 (traps-detail.md) | where | guard |
|---|---|---|
| ArgoCD sync-wave 순서/교착 + 원장 드리프트 | gate | `platform/cnpg/prod/test_sync_wave_ordering.bats`, `platform/argocd/root/test_sync_wave_ledger.bats` |
| SSA atomic 리스트(HTTPRoute group/kind/weight) 영구 OutOfSync | gate | `platform/adguard/prod/test_adguard_route.bats` |
| PSA baseline가 hostPath/hostPID 금지(privileged 전용) | gate | `platform/namespaces/prod/test_psa.bats` |
| NetworkPolicy ipBlock pod-CIDR → default-deny 무력화 | gate | `platform/network-policies/prod/test_netpol.bats`, `platform/cnpg/prod/test_networkpolicy.bats` |
| CNPG Pooler 예약 파라미터(pool_mode) → poolMode 필드 | gate | `platform/cnpg/prod/test_pooler.bats` |
| CNPG pg_hba replication(postgres) — pg_basebackup 허용 | gate | `platform/cnpg/prod/test_basebackup.bats` |
| busybox nc에 -q 없음(relay 리스너) | gate | `platform/victoria-stack/prod/test_relay.bats` |
| vmalert configCheckInterval 없으면 룰 자동 reload 안 함 | gate | `tests/gates/test_vmalert-config.bats` |
| Alertmanager telegram: 자동 HTML-escape(이중 escape 금지) + 계약 | gate | `tests/gates/alertmanager-render-e2e.sh`, `tests/gates/test_telegram-notify.bats`, `tests/gates/test_telegram-alert-korean.bats`, `tests/gates/test_telegram-callsites.bats` |
| GitHub Actions 비신뢰 입력(env 경유+regex) | gate | `tools/tests/test_mutation-dispatch.bats`, `tools/tests/test_validate-mutation.bats` |
| concurrency queue:max ↔ cancel-in-progress 병용 불가(변이 디스패처 직렬화) | gate | `tools/tests/test_mutation-dispatch.bats` |
| 워크플로 YAML colon-in-unquoted-name 문법 깨짐 | gate | `tests/gates/test_workflow-yaml.bats` |
| 메모리 원장 예산(limit 합계 ≤ 10240Mi) | gate | `policy/ledger.rego`, `tools/tests/test_ledger-gate.bats` |
| 상주 워크로드 자원 limit 블라인드스팟(cpu·memory request + memory limit) | gate | `tools/check-resource-limits.ts`, `tests/test_resource_limits.bats` |
| AdGuard setcap 바이너리 ↔ allowPrivilegeEscalation 양립불가 | gate | `platform/adguard/prod/test_adguard_auth.bats` |
| enc.yaml 평문 직접 수정 금지(SOPS MAC) | gate+verify | `scripts/sops-guard.sh`, `.claude/hooks/manifest-guard.sh`, `tests/gates/test_manifest-guard.bats`, `tests/gates/test_verify-secrets.bats` |
| SOPS 왕복(암호화 후 복호 동일) | local | `tests/test_sops-roundtrip.bats` |
| `.claude/` 선택적 un-ignore(하네스 추적/런타임 무시) | gate | `tests/gates/test_claude-harness-tracked.bats` |
| make ci ↔ ci.yaml gate 8스텝 패리티 | gate | `tests/gates/test_make-ci-parity.bats` |
| DR drill 안전 불변식(R5, 라이브 파괴 없이) | gate | `tests/test_dr-drill.bats` |
| R2 pg 아카이브 reset --purge 가드(④) | gate | `tests/test_reset-pg-r2-archive.bats` |
| sealing key 백업 체인 DR fail-closed 게이트 | gate | `tests/test_sealed-secrets-restore.bats` |
| tf-reconcile 무인 apply 안전 불변식(destroy 가드 등) | iac | `infra/_tests/test_tf_reconcile.bats` |
| ArgoCD AppProject 권한경계 + appset finalizer/exclude/default-lockdown 거버넌스 | gate | `platform/argocd/root/test_projects.bats` |
| bats @test 이름 한글/CJK 디렉토리실행 침묵스킵 | gate | `tests/gates/test_check-skeleton-cjk.bats`, `tests/gates/test_check-skeleton-gate.bats` |
| homepage EROFS(RO config)·apiserver egress(노드서브넷:6443 not ClusterIP) | gate | `platform/homepage/prod/test_homepage_render.bats`, `platform/homepage/prod/test_homepage_netpol.bats` |
| GHA run 기본 셸 pipefail 부재(bash -e {0}) — tee 파이프 fail-open | gate | `tests/gates/test_workflow-pipefail.bats` |
| PG 메이저 업그레이드 3-이미지 동시 갱신(pg-tools digest 일관성) | gate | `tests/gates/test_pgtools-digest.bats`, `tests/test_dr-drill.bats` |
| 로컬 자산 백업 체인(런북 tarball age 백업·인덱스 양방향) | gate | `scripts/backup-local-asset.sh`, `scripts/verify-runbook-index.sh`, `tests/test_backup-local-asset.bats` |
| 재부팅 IP churn — instance 라벨 불안정(increase 누적 누출·on() 조인 422) | gate | `tools/check-alert-rules.ts`, `tests/test_alert_rules.bats` |
