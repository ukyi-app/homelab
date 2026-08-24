# homelab CLI — 릴리스 검증 증거

Stage 5(Ship) 검증 스윕. 이 문서는 릴리스 게이트(release 렌즈)가 "커밋된 증거가 diff를 커버하는가"를
감사하는 대상이다. 아래 명령·결과·핀은 이 커밋 시점 HEAD에서 실측한 값이다.

## 검증된 상태 (핀)

| 항목 | 값 |
|---|---|
| 브랜치 | `homelab-cli` |
| base(main merge-base) | `969cb05384d2f3b187756e9c2dbbb92cd47b2c0d` |
| 도구 코드 최종 | 이 verification.md를 담은 커밋(release r2 수정 반영 — MCP 전체 입력검증·짧은 식별 deadline·url envelope 화이트리스트). 이후 커밋은 문서/게이트 아티팩트만 |

> **재핀 이력(release r2-4)**: 초판 verification.md는 `97e8f6f`에 핀됐으나 이후 `a19f466`(release r1 수정)이
> MCP·mutation·tests 코드를 바꿔 증거가 stale이 됐다(r2 적대 렌즈 포착). 이 판은 r1·r2 수정을 모두 담은
> 트리에서 전 명령을 **재측정**한 값이다. verification.md 자체를 커밋하면 HEAD가 한 칸 전진하지만 그 커밋은
> 문서만 바꾸며, 도구 코드(tools/)·테스트는 이 커밋의 트리가 최종이다.

## 실행한 명령과 결과 (전부 이 HEAD에서 실측, exit code)

| 명령 | 결과 |
|---|---|
| `bun run typecheck` (`tsc --noEmit`) | **exit 0** |
| `make verify` (check-skeleton + 원장 conftest + sops 라운드트립) | **exit 0** |
| `./scripts/run-bats.sh` (gate 도메인 전체 bats) | **exit 0 — 237 파일 / 2092 `@test` 전건 통과** (`set -e` 하 비-0이면 즉시 실패하므로 exit 0 = 전건 green) |
| `bun run verify:ledger` (메모리 원장 OPA) | **exit 0** |
| `bun tools/audit-orphans.ts --ci` | **exit 0** |
| `./scripts/check-skeleton.sh` | **exit 0** |
| `bun tools/check-guard-authority.ts` | **exit 0** |
| `bun tools/check-image-ownership.ts` | **exit 0** |
| `bun tools/check-workflow-readiness.ts` | **exit 0** |
| `bun tools/check-ci-parity.ts` | **exit 0** |
| `bash scripts/check-doc-index.sh` | **exit 0** |
| `bash scripts/check-bats-accounting.sh` | **exit 0** (2092건 스캔, 제외 16/16) |
| `bash scripts/check-app-deploy.sh` | **exit 0** |

CI 전용 스텝(`make ci` 상의 typecheck·verify:ledger·audit-orphans·check-skeleton·check-guard-authority·
check-image-ownership·check-workflow-readiness·check-ci-parity·check-doc-index·check-bats-accounting·
check-app-deploy) 전부 개별 실측 green.

## 이 피처가 추가/변경한 테스트 (149 `@test`, 10 파일)

CLI 프로세스 경계(PATH stub + NUL argv 원장) + 시간 주입 심 + 실물 git 픽스처로 라이브 무의존 검증.

| 파일 | @test | 대상 동사 |
|---|---|---|
| `test_homelab-cli.bats` | 14 | 라우팅·계약 스키마 SSOT(verb→variant→result 결합, exitCode 결합) |
| `test_homelab-doctor.bats` | 15 | doctor 진단(관측 전용, 템플릿 계약 공유 술어) |
| `test_homelab-status.bats` | 23 | status(목록/앱/핸들, omitted 축) |
| `test_homelab-db.bats` | 20 | db create(공유 변이 엔진·대기 매트릭스) |
| `test_homelab-cache.bats` | 10 | cache create(엔진 2번째 인스턴스) |
| `test_homelab-appcreate.bats` | 7 | app create(수동 머지 레인) |
| `test_homelab-secrets.bats` | 15 | app secrets(이중 모드·seal 연쇄) |
| `test_homelab-appteardown.bats` | 13 | **app teardown**(confirm 가드·converge:absence·pty TTY) |
| `test_homelab-appinit.bats` | 15 | **app init**(멱등 재개·마커 소유·시크릿 원자·private key 비노출) |
| `test_homelab-mcp.bats` | 17 | **mcp**(JSON-RPC·teardown 부재·명시 경로·-32602/-32600) |

## 릴리스 선행 조건 — 템플릿 amd64 (스펙 "크로스레포 티켓" 요구 증거)

스펙은 릴리스 수용 증거에 **amd64 스캐폴드→빌드→스모크 결과**를 요구한다(템플릿 arm64 하드코딩 수리가
amd64 NUC에서 실기동해야 init 산출 앱이 exec format error로 죽지 않는다). 증거:

| 항목 | 값 |
|---|---|
| 템플릿 수리 PR | `ukyi-app/homelab-app-template#31` — **머지됨**(merge commit `924feb9`, 2026-08-24) |
| 반영 실측 | 라이브 `homelab doctor`의 `template-targetarch` 검사가 머지 전 **fail** → 후 **pass**(컴파일 아키타입 3종 api·fullstack·worker Dockerfile TARGETARCH 파라미터화 확인) |
| amd64 스모크 증거 | `docs/reviews/homelab-cli/ticket-03-amd64-smoke.md`(커밋 `a37834c`) — red(exec format error) 실측→green 스모크 4/4 + 바이너리 검증 6종, template-ci 9/9 |
| doctor 템플릿 호환성 검사 | init preflight와 **같은 술어**(`lib/template-contract.ts`) 공유 — 장래 템플릿 드리프트를 지속 방어 |

## 게이트 이력 (adversarial)

- **plan 게이트**: r2까지, WAIVED by user(decisions.md `### plan r2`).
- **structure 게이트**: r2 완주(ok:true), 회수본 트리아지 종결, WAIVED by user(`### structure r2`).
- **release 게이트**: ticket 12 슬라이스(full-branch 558KB가 herdr 96KB 상한 초과 — 최대 fitting suffix,
  사용자 결정). r1(2인 패널)·r2(적대 렌즈) 모두 pane 판독 손상/타임아웃으로 정식 ok:false → codex 세션
  로그 무손실 회수(HRG 토큰·count 일치, 회수본 `release-r1-salvaged.json`). r1 5쟁점·r2 4건 전건 실코드
  확증 후 수용·수정(전 수정 mutation 판별성 검증). decisions.md `### release r1`·`### release r2`.
- **per-ticket /code-review(2축)**: 12장 전부. 티켓 10·11·12는 추가로 **4렌즈 적대 red-team**
  (Standards·Spec + 엔진/계약(또는 신뢰경계/JSON-RPC) red-team) — 확정 결함 반영 후 재검증 green.
  - 티켓 10: 확정 결함 0(엔진 red-team 관찰 1건 진단 정확화 반영).
  - 티켓 11: 5건 반영(private key 유출 가드 vacuous green·ensureClone owner-aware·스캐폴드 스킵 2부 사후조건), mutation 판별성 검증.
  - 티켓 12: 3쟁점 반영(required 서버측 강제·비-오브젝트 라인 크래시 방어·동시성 테스트 정정), mutation 판별성 검증.

## 알려진 외부 장애 (이 피처 범위 밖 — 커버리지에서 명시 제외)

`make ci`의 `tests/gates/skopeo-timeout-smoke.sh`가 `quay.io/skopeo/stable:v1.22.2@sha256:02053f3c…`를
**라이브 pull**하다 실패한다(HARNESS FAULT). 이는 quay가 v1.22.2 태그를 재푸시하며 구 digest manifest를
GC하는 재발 장애다(2026-08-18 최초 → cb8699d 재핀 → 재발, **3번째**). 핀은 관측성 매니페스트
(`platform/victoria-stack/prod/digest-exporter.yaml`·`gha-liveness-exporter.yaml`)에 있고 **이 피처(tools/
전용)와 무관**하다. 재핀은 owner의 관측성 인프라 유지보수 사안(cb8699d 선례처럼 별도 커밋). 이 라이브
스텝을 제외한 `make ci`의 전 스텝은 위 표대로 개별 green이며, required CI 게이트(`gate` = run-bats)는 green이다.
