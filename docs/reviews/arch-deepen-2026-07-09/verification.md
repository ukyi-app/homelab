# Verification — arch-deepen-2026-07-09 (image-pin 커널)

실행 HEAD: `2628e411e73a7c39d11d7be0e61da6dc46a27a6e` (R-1 · R-2 · R-3 전부 포함, 워킹트리 클린)
실행일: 2026-07-12 · perf 핀 명령: 없음(플랜 명시 — 순수 함수 리팩터, 측정 지표 없음이 Rule 0 전제)

> 재검증 사유: `origin/main` 리베이스로 브랜치 커밋 SHA가 전부 재작성되어 최초
> 증거(`d87481c`)가 존재하지 않는 커밋을 가리켰다. 트리 내용은 동일하나
> capturing-evidence 하드룰(검증 후 변경 = 재검증)에 따라 4 claim을 새 HEAD에서
> 신선 재실행했다. baseline은 등가 커밋 `75e4d33`(lock 백필)으로 갱신됨.

## Claim 1 — behavior lock testCmd green (characterization-lock.json의 정확한 핀 명령)

```bash
bats tools/tests/test_poll-ghcr.bats tools/tests/test_bump.bats tools/tests/test_digest-exporter-lib.bats tools/tests/test_create-app.bats tools/tests/test_bump-poll-toctou.bats tools/tests/test_image-pin-charlock.bats
```

출력(원문 — TAP plan + 꼬리, `not ok` 0건 · rc=0):

```
1..85
...
ok 82 bump-tag B10: tag format boundary — sha-+7/40 hex accept, sha-+6/41 hex and uppercase reject
ok 83 bump-tag B10: digest format boundary — sha256:+64 hex accept, 63/65 hex and uppercase reject
ok 84 poll-ghcr B10: inline pin non-greedy (.+?) fixes current.tag/current.digest at the :sha- boundary
ok 85 bump-tag B10: inline non-greedy (.+?) preserves a colon-containing repo across the rewrite
```

**판정: PASS** — 85/85(`not ok` 0), baseline(`75e4d33`, 리팩터 전) 대비 동일 스위트·동일 green.
lock 6개 스위트 파일은 baseline 이후 무수정(anti-cheat — 각 증분에서 diff 0 확인).

## Claim 2 — 커널 lib 스위트 green (증분 신규 테스트)

```bash
bats tools/tests/test_image-pin-lib.bats
```

출력(원문 — 꼬리, `not ok` 0건 · rc=0):

```
1..10
...
ok 8 parseDescriptor propagates a throw on malformed json (no swallow)
ok 9 descriptorAutoDeploy is fail-closed: only boolean true yields true
ok 10 no inline pin regex literals reappear in kernel consumers
```

**판정: PASS** — 10/10 (커널 직접 단언 9 + 안티드리프트 grep-guard 1).

## Claim 3 — 전체 bats 게이트 0 실패

```bash
./scripts/run-bats.sh
```

출력(원문 — 꼬리, `not ok` 0건 · rc=0):

```
1..1166
...
ok 1164 bun type deps present (types:[bun] needs @types/bun)
ok 1165 no pnpm workspace or lockfile remains
ok 1166 bun lockfile is text format and committed
```

**판정: PASS** — 1166/1166 (baseline 1156 + 이 리팩터의 신규 10: charlock는 baseline에 포함, lib 9+guard 1 추가분 반영).

## Claim 4 — make verify (skeleton + 원장 + sops 라운드트립)

```bash
make verify
```

출력 꼬리(원문 · rc=0):

```
check-app-deploy: 배포 계약(필수 산출물 + checksum/secrets↔봉인본 정합) OK
check-resource-limits OK (20 워크로드 매니페스트 스캔, cpu·memory request + memory limit 위반 0)
check-alert-rules OK (41 룰 스캔, 모드 A/B 위반 0)
check-app-netpol OK (0 app-owned NetworkPolicy 검사, 위반 0)
스캔된 platform/apps 런타임 이미지 전부 digest 핀됨 (스캔 36건). [helm 차트 내부=Renovate·substrate=versions.env 관할]
2 tests, 2 passed, 0 warnings, 0 failures, 0 exceptions
1..2
ok 1 sops encrypts a prod-path secret to two recipients
ok 2 sops decrypt round-trips to the original plaintext
```

**판정: PASS** — rc=0.
