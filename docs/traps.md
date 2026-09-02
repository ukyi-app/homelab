# 함정 enforcement 원장 (additive)

`docs/traps-detail.md`가 함정의 **단일 SSOT**다(설명·근거 포함, doc-only 포함 전부; AGENTS.md엔 한줄 인덱스만).
이 원장은 그중 **실행 가능한 가드로 강제된 함정만** 추적해, 가드 파일이 삭제·리네임됐는데 함정이
다시 물리는 드리프트를 `make verify-traps`로 차단한다. 여기 없는 함정 = doc-only(traps-detail.md가 유일 SSOT).

- **검사 방향 3가지**: `scripts/verify-traps.sh`가 전부 강제한다. 가드의 *내용 정확성*은 각 가드 테스트 자신이 책임진다.
  1. 아래 `guard` 열의 백틱 경로가 **실재하는지**(enforced인데 파일 없음 = 거짓 안심 → 실패).
  2. `docs/traps-detail.md`의 `> 가드:` 주석 경로가 **이 원장에도 추적되는지**(SSOT → 원장).
  3. 이 원장의 각 행이 가리키는 가드가 **SSOT의 어느 `> 가드:` 줄에든 있는지**(원장 → SSOT).
     ⚠️ 1·2는 이 갭을 **원리적으로 못 본다** — 1은 파일 실재만, 2는 반대 방향만 본다. 실측 2026-08-21
     도입 시점에 **9행**이 SSOT에도 AGENTS 인덱스에도 없이 enforced를 주장하고 있었다.
- **where**: `gate`=ci.yaml job `gate`가 수집 · `iac`=iac/tf-reconcile · `local`=make/pre-commit 로컬 ·
  `app-build`=앱 레포의 pr/release가 호출하는 reusable(이 레포엔 caller가 없어 `gate`가 수집하지 않는다).
  방향 3의 면제는 여기에 **사유와 함께 명시**한다(하드코딩 목록이 아니라 마커라 새 행에도 같은 규칙이 적용된다):
  - `SSOT없음(불변식)` — 함정 서사가 아니라 불변식·규약을 지키는 가드다. traps-detail에 들어갈 대상이 아니다.
  - `SSOT없음(승격대상)` — 함정인데 traps-detail 서사가 아직 없다. **부채를 침묵시키지 않고 계상한다.**
- 새 가드 테스트를 추가하면 이 표에도 한 줄 추가한다(리네임 시 verify-traps가 강제로 알려준다).

| 함정 (traps-detail.md) | where | guard |
|---|---|---|
| ArgoCD sync-wave 순서/교착 + 원장 드리프트 | gate | `platform/cnpg/prod/test_sync_wave_ordering.bats`, `platform/argocd/root/test_sync_wave_ledger.bats`, `platform/traefik/prod/test_gateway_sync_wave.bats` |
| SSA atomic 리스트(HTTPRoute group/kind/weight · CNPG plugins) 영구 OutOfSync | gate | `platform/adguard/prod/test_adguard_route.bats`, `platform/cnpg/prod/test_cluster_params.bats` |
| 상주 워크로드 OOM 진단 — 코어 수는 그럴듯한 오답이다 (D-e) | gate | `platform/victoria-stack/prod/test_concurrency_pin.bats` |
| PCIe correctable RxErr 폭주는 ASPM L1이다 — 유휴에서만 나고 열화가 아니다 | gate | `infra/k3s-bootstrap/tests/test_03-host-config.bats` |
| hostPath 백엔드 PV에는 fsGroup 미적용 — root가 만든 파일을 non-root가 못 연다 | gate | `platform/adguard/prod/test_adguard_auth.bats` |
| `yq -e`는 값이 false면 exit 1 — null과 구별하지 않는다 | gate | `platform/cnpg/prod/test_cluster_params.bats` |
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
| SOPS 왕복(암호화 후 복호 동일) | local · SSOT없음(불변식) | `tests/test_sops-roundtrip.bats` |
| `.claude/` 선택적 un-ignore(하네스 추적/런타임 무시) | gate · SSOT없음(불변식) | `tests/gates/test_claude-harness-tracked.bats` |
| make ci ↔ ci.yaml gate 스텝 패리티(건수는 policy/ci-parity.json이 계상 — 여기에 적지 않는다) | gate | `tests/gates/test_make-ci-parity.bats` |
| DR drill 안전 불변식(R5, 라이브 파괴 없이) | gate | `tests/test_dr-drill.bats` |
| 파괴 프리미티브는 전용 파일 + 확인 env로 분리한다(드릴 본문의 한 줄이면 '그 줄만 떼어 돌려보는' 경로가 생긴다) · bulk 안전은 경로가 아니라 **bind 소스**로 판정한다 | gate · SSOT없음(불변식) | `tests/test_destroy-node.bats` |
| 한시 억제의 자기 만료(시각 상수 ↔ 창 SSOT 양방향 정합) + 억제한 알림을 vacuity 대조군으로 쓰던 e2e 동반 사망 | gate | `tests/gates/test_files-backup-phase-a.bats` |
| R2 pg 아카이브 reset --purge 가드(④) | gate · SSOT없음(불변식) | `tests/test_reset-pg-r2-archive.bats` |
| sealing key 백업 체인 DR fail-closed 게이트 | gate | `tests/test_sealed-secrets-restore.bats` |
| tf-reconcile 무인 apply 안전 불변식(destroy 가드 등) | gate | `infra/_tests/test_tf_reconcile.bats` |
| ArgoCD AppProject 권한경계 + appset finalizer/exclude/default-lockdown 거버넌스 | gate · SSOT없음(불변식) | `platform/argocd/root/test_projects.bats` |
| bats @test 이름 한글/CJK 디렉토리실행 침묵스킵 | gate | `tests/gates/test_check-skeleton-cjk.bats`, `tests/gates/test_check-skeleton-gate.bats` |
| homepage EROFS(RO config)·apiserver egress(노드서브넷:6443 not ClusterIP) | gate | `platform/homepage/prod/test_homepage_render.bats`, `platform/homepage/prod/test_homepage_netpol.bats` |
| GHA run 기본 셸 pipefail 부재(bash -e {0}) — tee 파이프 fail-open | gate | `tests/gates/test_workflow-pipefail.bats` |
| GNU make가 recipe 종료코드를 자기 Error 2로 뭉갬 — make 계층 skip 신호는 마커+비-0까지 | gate | `tests/gates/test_guard-skip-signalling.bats` |
| PG 메이저 업그레이드 3-이미지 동시 갱신(pg-tools digest 일관성) | gate | `tests/gates/test_pgtools-digest.bats`, `tests/test_dr-drill.bats` |
| 로컬 자산 백업 체인(런북 tarball age 백업·인덱스 양방향) | gate | `scripts/backup-local-asset.sh`, `scripts/verify-runbook-index.sh`, `tests/test_backup-local-asset.bats` |
| 재부팅 IP churn — instance 라벨 불안정(increase 누적 누출·on() 조인 422) | gate | `tools/check-alert-rules.ts`, `tests/test_alert_rules.bats` |
| push 주기 > instant 룩백(기본 5m) → 룰 시리즈 구멍 → `for:` 영구 리셋 = 무발화(fail-open) | gate | `tests/gates/vmalert-drift-firing-e2e.sh`, `tests/gates/vmalert-bulkssd-firing-e2e.sh`, `tests/gates/vmalert-digest-stale-firing-e2e.sh`, `tests/gates/test_digest-exporter.bats`, `tests/gates/test_digest-exporter-producer.bats`, `tests/gates/skopeo-timeout-smoke.sh`, `tools/check-alert-rules.ts`(모드 C: 레포 전역 정적 lint + push 생산자 완전성 가드), `tests/test_alert_rules.bats` |
| rollup 윈도 상한(라벨-값 상태 게이지는 W < `for:`) — bump phantom 오발화 + 우변 존재 가드 | gate | `tests/gates/vmalert-drift-firing-e2e.sh` |
| bump-poll/** writer App 예약(인터록≠인증·R-46 수용 잔여·정적 가드=best-effort 변경감지기·Seam C 권위) | gate | `tests/gates/test_bump_poll_ruleset.bats` |
| emptyDir sizeLimit vs 런타임 다운로드 페이로드(부팅↔evict 루프·DiskPressure=False·로그 파이프라인 연쇄) | gate | `platform/victoria-stack/prod/test_grafana_plugin_budget.bats` |
| 열거 붕괴 → vacuous green(프로세스 치환 rc 미전파·커맨드 치환 stderr 삼킴·부정 카운트 rc=2·bats 부재 단언은 `-eq 1` + 재귀/루프 자리의 바닥값·양성 대조 한 쌍) | gate+verify | `tests/gates/test_scan-floor.bats`, `scripts/lib/scan-floor.sh`, `tools/lib/scan-floor.ts`, `scripts/check-scan-producers.sh`, `policy/ledger.rego`, `tests/test_ledger.bats`, `scripts/check-bats-style.sh`, `tests/gates/test_bats-style.bats` |
| PreToolUse 훅 종료코드(0=허용·2=차단·그 외=비차단) — 1/4 복사 시 fail-open | local | `tests/gates/test_manifest-guard.bats` |
| GHA job-level skip은 run conclusion에 안 보인다(스텝 전부 skip이어도 job은 success) | gate | `tools/check-workflow-readiness.ts`, `policy/workflow-readiness.json`, `tests/gates/test_workflow-readiness.bats`, `infra/_tests/test_tf_reconcile.bats` |
| 이미지 핀의 존재≠일치≠소유자(하드코딩 소비처 목록·base64 은닉·차트 내부 mutable tag) | gate | `tools/check-image-ownership.ts`, `policy/image-ownership.json`, `tests/gates/test_image-ownership.bats`, `tests/gates/test_pgtools-digest.bats` |
| vmalert replay rulesDelay = 게이트 시간의 전부(비율 아닌 절대 지연·체인 없으면 순수 낭비) | gate | `tests/gates/test_vmalert-e2e-replay-timing.bats`, `tests/gates/lib/vmalert-e2e.sh` |
| make -n은 드라이런이 아니다 — 레시피의 $(MAKE)는 -n에서도 실행(그 출력을 데이터로 읽는 가드 2종이 오염) | gate | `tests/gates/test_make-ci-parity.bats`, `tools/check-ci-parity.ts`, `policy/ci-parity.json` |
| tracked 열거 게이트는 untracked 파일을 안 본다(로컬 초록 ↔ CI red 양립 — `git add` 전 make ci는 무측정) | gate | `tests/gates/test_make-ci-parity.bats`, `Makefile` |
| 체이닝 레이스의 두 번째 얼굴 — record는 있는데 ALERTS 전무(대조 알림은 비체이닝이라 못 막음·병렬화가 깨운 flake) | gate | `tests/gates/vmalert-drift-firing-e2e.sh` |
| 소스의 리터럴 NUL 1바이트 → 그 파일이 모든 grep 가드에 투명(매치 수는 1이라 스캔한 것처럼 보인다) | gate | `scripts/check-skeleton.sh`, `tests/gates/test_scan-floor.bats` |
| 디스크 자기-상한 > 자기 볼륨 선언(GB=10⁹ vs Gi=2³⁰ 혼동·PVC는 축소 불가·존재 grep은 못 잡음) | gate | `tools/check-disk-caps.ts`, `tests/gates/test_disk-caps.bats` |
| 고아 PVC는 Bound다 — `phase == Released` 감사는 cascade=orphan 잔재를 원리적으로 못 잡는다 | local | `scripts/audit-orphan-pv.sh` |
| bats 중간 `[[ ]]`는 침묵 통과 — 거짓인데 ok (grep -qF 변환 시 `--` 종결자 필수) | gate | `scripts/check-bats-style.sh` |
| `grep -qv`는 부재를 재지 않는다 — 줄 단위 반전이 ∀¬를 ∃¬로 바꾼다(2줄 이상이면 토큰이 있어도 rc 0, 빈 입력이면 rc 1) | gate | `scripts/check-bats-style.sh`, `tests/gates/test_bats-style.bats` |
| 셸 문자열의 `$VAR한글` — bash 3.2만 죽고 CI(5.2)는 초록이라 게이트가 원리적으로 못 잡는다 | gate | `tests/gates/test_shell-bash32-traps.bats` |
| sshd_config.d는 먼저 읽힌 값이 이긴다(systemd와 반대) — 600 드롭인 때문에 실효값은 sudo 없이 못 읽는다 | gate | `infra/k3s-bootstrap/tests/test_03-host-config.bats` |
| Ubuntu 26.04에 /etc/timezone 부재 — 그 파일을 읽는 검사는 정상 호스트에서도 죽고 처방이 고치지 못한다 | gate | `infra/k3s-bootstrap/tests/test_02-host-preflight.bats` |
| tailscale `~.` 라우팅 도메인 → 노드 이름해석이 MagicDNS 경유 클러스터 의존(routable이라 loopback 검사는 통과) | gate | `infra/k3s-bootstrap/tests/test_02-host-preflight.bats` |
| `findmnt -T`는 마운트 여부를 증명 못 한다(감싸는 마운트로 resolve) + bind SOURCE의 `[subpath]` 미제거 시 디바이스 오판 | gate | `infra/k3s-bootstrap/tests/test_08-bulk-gate.bats` |
| 드릴의 정리가 EXIT trap뿐이면 고아가 남고, pre-flight 없는 apply가 그 고아를 재사용해 '검증된 복원'이 거짓말한다 | gate | `platform/cnpg/prod/test_restore_drill_behavior.bats` |
| 권한 부족이 드리프트로 위장한다 — terraform은 못 읽은 리소스를 "삭제됨"으로 읽어 `Plan: 1 to add`를 낸다 | gate | `infra/tailscale/test_provider_scopes.bats` |
| owner 로컬 apply 루트는 plan-only CI여도 terraform 핀 ≥ state writer여야 한다(핀 통일이 오히려 고장) | gate | `infra/tailscale/test_provider_scopes.bats` |
| GitHub API가 낡은 스냅샷을 200으로 반환 → push된 단조 타임스탬프가 역행 → `last_over_time`이 그 한 샘플로 오발화(rollup 함수 선택 축) | gate | `tests/gates/vmalert-gha-liveness-firing-e2e.sh`, `tests/gates/test_gha-liveness-exporter.bats`, `tests/gates/fixtures/r6-gha-lastovertime.yaml`, `tools/check-alert-rules.ts`, `policy/alert-supply-monotonicity.json`, `tests/test_alert_rules.bats` |
| 로케일 콜레이션이 게이트를 뒤집는다 — en_US `sort -u`가 `-1`과 `1`(그리고 `_`-접두 워크플로와 동명 공개 디스패처)을 같다고 보고 하나를 버려 fail-open | gate | `scripts/check-locale-collation.sh`, `tests/gates/test_locale-collation.bats`, `tests/gates/test_make-help.bats`, `platform/argocd/root/test_sync_wave_ledger.bats` |
| systemd 유닛 등 생산자 확장자 밖 파일의 인라인 push — 완전성 가드가 원리적으로 못 봐 죽은 알림이 초록으로 태어난다 | gate | `tests/gates/test_unit-failure-notify.bats` |
| bats가 fd 0을 상속시켜 스텁의 피연산자 없는 `cat`이 호출자 stdin에서 영구 블록 — red가 아니라 hang이고 `&`로 띄우는 CI는 우연히 면역이라 로컬만 밟는다 | local | `scripts/run-bats.sh`, `tests/test_sealed-secrets-restore.bats` |
| e2e 하네스의 호스트 포트 밴드가 커널 ephemeral·k8s NodePort와 겹침 — 전자는 하네스 자신의 curl과 경합하고 후자는 nat 규칙이라 어떤 bind 프로브로도 안 보여 `docker run`이 통과한 채 남의 서비스로 질의가 간다(+ `127.0.0.1` 프로브는 글로벌 인터페이스 전용 리스너를 FREE로 오답 · 처방이 한 소비자 lib에 갇히면 형제 표면은 원리적으로 못 받는다) | gate | `tests/gates/test_vmalert-e2e-port-allocation.bats`, `tests/gates/lib/vmalert-e2e.sh`, `tests/gates/lib/host-port.sh`, `scripts/check-host-ports.sh`, `tests/gates/test_host-ports.bats` |
| `&`로 띄운 헬퍼의 바인드 실패는 `set -e`에 안 걸린다 — readiness 줄이 없으면 30초를 태운 뒤 진단이 포트가 아니라 메시지 템플릿을 가리킨다 | gate | `scripts/check-host-ports.sh`, `tests/gates/test_host-ports.bats` |
| `Restart=always` 유닛은 시작 rate limit에 못 닿으면 `failed`로 확정되지 않아 systemd 상태 축이 원리적으로 못 본다 — 전역 스윕을 넣고 '이제 다 덮었다'로 읽는 것이 위험이다 | gate | `tests/gates/test_systemd-failed-sweep.bats`, `scripts/sweep-systemd-failures.sh` |
| ERE의 leftmost-longest가 `^A|B.*$` 한 방을 토큰 전체 삭제로 바꾼다 — 검출기가 자기 도메인의 실제 표기(따옴표형 publish)에 눈이 멀고, 픽스처가 그 표기를 안 쓰면 대조군까지 vacuous가 된다 | gate | `scripts/check-host-ports.sh`, `tests/gates/test_host-ports.bats` |
| heredoc 상태 기계가 주석 규칙보다 먼저 돌면 `<<PY`를 인용한 주석 한 줄이 파일의 나머지를 통째로 지운다 — 진짜 종료줄이 있으면 [E]도 침묵하고, 파일 수 축 회계(SCAN·READFILES)로는 원리적으로 안 보인다 | gate | `scripts/check-host-ports.sh`, `tests/gates/test_host-ports.bats`, `scripts/check-locale-collation.sh`, `tests/gates/test_locale-collation.bats`, `scripts/check-bats-style.sh`, `tests/gates/test_bats-style.bats` |
| 면제 판정이 주석 스킵보다 먼저 돌면 규약을 *설명한* 파일이 그 규약에서 면제된다 — 가드 자신이 자기 헤더 때문에 영구 면제였다(셸 주석·Makefile `##`·YAML `name:` 세 표면) | gate | `scripts/check-bats-fd0.sh`, `tests/gates/test_bats-fd0.bats` |
| SKIP(exit 4)을 모르는 대조는 gitignored 자산이 있는 로컬에서만 초록이다 — 로스터 대조가 그 rc를 실패로 읽어 로컬 `make ci` rc=0인데 PR gate만 FAILURE였다(SKIP은 양쪽 대칭 제외 + 상한 필요) | gate | `tests/gates/test_scan-floor.bats`, `scripts/verify-credential-inventory.sh` |
| `findings="$(awk … || true)"` — `|| true`가 awk fatal rc까지 삼켜 검출기가 죽어도 "0곳 OK" rc=0을 낸다(가드 본체 fail-open). 처방 세 겹(awk rc 포착 + 인자 사전 검증 + READFILES 대조)은 detect_run 커널이 소유하고 콜사이트는 awk 본문만 소유한다(check-scan-producers는 커널 도입 전 자체 3겹 — detect_run 이관 후보) | gate | `scripts/lib/guard.sh`, `tests/gates/test_guard-sh.bats`, `scripts/check-host-ports.sh`, `scripts/check-locale-collation.sh`, `scripts/check-bats-style.sh`, `scripts/check-scan-producers.sh`, `tests/gates/test_host-ports.bats`, `tests/gates/test_locale-collation.bats`, `tests/gates/test_bats-style.bats` |
| 상류 레지스트리의 릴리스 태그가 불변이 아니다 — 재푸시가 옛 매니페스트를 GC해(quay skopeo 6일 3회) image-pin-liveness가 브랜치와 무관하게 모든 PR gate를 red로 만든다. GC 안 하는 레지스트리(Docker Hub alpine)의 자기 소유 이미지로 옮긴다 | gate | `tests/gates/image-pin-liveness.sh`, `ops/skopeo/Dockerfile`, `tests/gates/skopeo-timeout-smoke.sh`, `tests/gates/test_pgtools-digest.bats`, `tests/gates/test_ci-build.bats` |
| TS 바닥값은 coercion 뒤에서 조용히 꺼진다(Number("abc")=NaN → n<NaN 항상 false · Number("")=0 → 빈 입력≠의도적 0 구별 불가) — parseFloor를 coercion 앞에 | gate | `tools/lib/scan-floor.ts`, `tests/gates/test_scan-floor.bats` |
| 스캔 신호를 콜사이트가 손으로 내면 순서가 드리프트한다(위반 exit이 신호보다 앞 → 마커 0건=미실행 오독 · 로스터 등식은 우회 못 잡음) — 커널 한 몸 + 직접 생산자 거부 | gate | `tools/lib/scan-floor.ts`, `scripts/check-scan-producers.sh`, `tests/gates/test_scan-floor.bats` |
| 정적 증인의 두 함정(`^[^/]*`는 `//`만 제외 — JSDoc 줄이 코드 · `run bash -c` 안의 bats 지역 변수는 빈 문자열 — grep 0건 항상 통과) | gate | `tests/gates/test_scan-floor.bats`, `scripts/check-scan-producers.sh` |
| QEMU amd64 leg의 bun 1.4는 RSS 24MB에서 "메모리 고갈"로 죽는다(JSC 주소공간 예약 실패 — BUN_JSC_useJIT=0·forceRAMSize 무효) — 크래시-재시도 루프가 release를 6시간 태우고, Dockerfile을 안 돌리는 앱 CI는 그동안 초록이다. timeout-minutes로 분 단위에 드러나게 한다. 같은 노출이 `homelab-mutation` 직렬화 그룹(queue:max FIFO)에도 있어 그 9 워크플로의 잡에도 상한을 건다 — route 잡(`uses:`)엔 못 걸어 reusable 잡까지 따라 내려가 검사한다 | app-build, gate | `.github/workflows/reusable-app-build.yaml`, `tools/tests/test_mutation-dispatch.bats` |
| `github.actor`는 재실행에서 **보존**된다(개시자는 `triggering_actor`) — 그리고 `actions:write`는 재실행 동사를 포함하므로 트리거 열거는 안전 판정이 못 된다. owner 가드 15사본이 actor만 봐서 전건이 `ACTOR=owner·TRIGGERING=타인`을 통과했다(실측). 두 신원을 **함께** 요구하고, env 바인딩 수와 술어 수의 등식을 증인이 진다(바인딩 누락=전 디스패치 잠금) | gate | `tools/tests/test_mutation-dispatch.bats`, `.github/workflows/create-app.yaml` |
| `grep -q`의 조기 종료가 pipefail 아래에서 writer를 SIGPIPE로 죽인다 — 매치가 있었는데 141이 거짓 FAIL이 된다 | gate | `scripts/check-sigpipe-writers.sh`, `tests/gates/test_sigpipe-writers.bats` |
| 프로브는 호출이 아니다 — `make -n` 출력의 `command -v X`와 미평가 라벨 `echo "X…" >> $(CI_UNEVAL)`이 X의 증인 노릇을 해, 실제 호출만 지워도 mirrored 대조가 초록이다(선언이 자기 자신을 증명한다). 대조 전에 그 두 **형태**를 지운다(변수명 의존 금지) — `--floor` 금지 검사는 원문 유지 | gate | `tools/check-ci-parity.ts`, `tests/gates/test_make-ci-parity.bats` |
| 서브쿼리 step이 스크레이프 간격보다 크면 peak가 조용히 과소평가된다(`[14d:5m]` ↔ 30초 스크레이프 = 샘플 90% 폐기 — peak는 격자에 걸릴 확률이 낮은 점이라 손실이 편향된다). 그 위에서 깎은 limit 둘이 같은 날 회귀했다(repo-server +60.3% · adguard +57.5% 과소평가). red를 내지 않는 결함이라 원장 마커와 스크레이프 간격의 정합을 가드가 진다 | gate | `tests/gates/test_verify-ledger-ssot.bats`, `docs/memory-ledger.md` |
| 네이티브 사이드카(`restartPolicy: Always` initContainer)의 limit은 KSM이 `kube_pod_init_container_resource_limits`로 내보낸다 — near-limit 알림 분모가 container 계열만 보면 캡을 씌우는 순간 "무캡·무알림"이 "캡·무알림·조용한 OOMKill"이 된다. 분모는 두 계열의 `or` | gate | `platform/victoria-stack/prod/rules/core.yaml`, `tools/check-resource-limits.ts`, `tests/gates/test_grafana-dashboards.bats` |
| `Container.args`는 patchMergeKey 없는 atomic []string이라 strategic-merge patch가 리스트를 통째로 교체한다(실측: `operator`+TLS 경로 전부 소실 → 기동 불가). resources 단언만 있는 증인은 이 사고를 원리적으로 못 잡는다 — 벤더 오버레이 증인에는 "건드리지 않은 필드가 살아남았다"가 필요하다 | gate | `platform/cnpg/barman-plugin/test_kustomize_cap.bats` |
| 파일 프리필터(`KIND_RE`)를 함께 넓히지 않으면 kind 추가가 vacuous green으로 착지한다 — 게이트는 초록, 위반 0, 스캔 카운트만 조용히 그대로(21→20). 새 kind는 (a)필드 삭제 red와 (b)프리필터 되돌림 카운트 감소 두 뮤테이션으로 함께 잠근다 | gate | `tools/check-resource-limits.ts` |
| A′는 회수 가능한 커널 slab을 분자에 싣는다 — 비중이 0.2~27.1%로 100배 갈리고, cadvisor가 cgroup v2에서 커널 계열을 안 채워 peak 시점 값은 소급 측정 불가다. 처방은 `shmem == 0` 확인을 조건으로 한 RSS 분자. 배수·압력·slab 비중이 서로 다른 세 순서다 | gate | `docs/memory-ledger.md`, `tools/check-resource-limits.ts` |
| 자기조절 워크로드의 자기참조는 **두 경로**로 산다 — GOMEMLIMIT(힙)과 `--memory.allowedPercent`(캐시). 하나만 끊으면 나머지로 되살아나고, fastcache는 mmap이라 GOMEMLIMIT이 캐시를 못 막는다. 둘 다 절대값으로 고정한다(`--memory.allowedBytes`). `≤ limit × 0.95` 게이트는 한쪽 상한만 보므로 이 결정을 강제하지도 막지도 않는다 | gate | `platform/victoria-stack/prod/vmsingle.yaml`, `docs/memory-ledger.md` |
| 측정 창이 기판 변경(노드 재부팅·커널·런타임 메이저)을 가로지르면 두 체제가 한 숫자에 섞인다 — 원장의 `vmagent 1.05x`가 이미 존재하지 않는 세대의 값이었다. 방향도 일정하지 않아(glances는 같은 재부팅에서 상승) 경험칙으로 뭉갤 수 없다 | gate | `docs/memory-ledger.md` |
