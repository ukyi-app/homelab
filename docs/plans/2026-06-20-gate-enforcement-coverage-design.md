# 테마5 설계: gate enforcement 커버리지

- 날짜: 2026-06-20
- 상태: 설계 승인됨(사용자 확정 2026-06-20) — Phase B(writing-plans) 진입 대상
- 워크트리: `.claude/worktrees/feat+gate-enforcement-coverage` (브랜치 `worktree-feat+gate-enforcement-coverage`, origin/main `37e4d19` 분기)
- 출처: 2026-06-19 홈랩 10차원 심층 감사 8테마 로드맵의 테마5 ("gate enforcement 커버리지", 고/저·M, 즉시green)

## 1. 배경 / 문제 — "테스트 죽었는데 녹색"

required `gate`(ci.yaml job `gate`, 유일 required check)가 통과(녹색)해도 일부 테스트/가드가 실제로 안 도는 갭. 딥리뷰가 4갈래를 지목했으나, **Phase A grounding으로 2개를 정제**(false-positive/무력화):

| # | 딥리뷰 주장 | grounding 결과 |
|---|---|---|
| 1 | 한글 @test 침묵스킵(자동가드0) | ✅ **유효** — `check-skeleton.sh`는 `test_` 접두만 검사, @test 이름 CJK 검사 0. bats 디렉토리 실행 시 한글 @test는 조용히 스킵(검증된 함정). |
| 2 | check-bats-accounting CI 미배선(make verify 로컬만) | ❌ **이미 해소** — `tools/tests/test_bats-accounting.bats:6`이 실제 `check-bats-accounting.sh`를 run, 이 bats가 run-bats --list(97행)에 수집 → required gate가 이미 강제. 딥리뷰가 직접호출(make verify)만 보고 indirect(bats 경유)를 놓친 FP. |
| 3 | homepage kustomize render 테스트0(7 grep-only·인시던트2건) | ✅ **유효** — 7 bats 전부 소스 YAML grep, `kustomize build` 0. 인시던트 #65(EROFS)·#66(apiserver egress)를 놓침. |
| 4 | run-bats prune(`charts/*`) ↔ accounting credit(`charts/app/tests/*`) 비대칭 | ❌ **무력화** — accounting이 gate에 있으므로(#2), `charts/` 외부 테스트는 silent-green이 아니라 **accounting-RED**로 잡힘(=convention 강제). silent hole 아님. charts/ 외부 tracked test 현재 0건. |

**인접 갭(발견#2의 진짜 버전)**: `check-skeleton.sh`(test_ 접두 네이밍 + README dirmap 가드)는 **verify.yaml(job `verify`, non-required)** + `make verify`에만 → 위반해도 required gate가 녹색이라 머지 가능. 가드가 advisory에 그침("가드 죽었는데 녹색"). gate 미배선.

## 2. 목표 / 비목표

### 목표
- **한글/CJK @test 이름을 검출해 fail**시키는 자동 가드 추가(침묵스킵 차단).
- 그 가드를 포함한 `check-skeleton.sh`를 **required gate로 승격**(네이밍+dirmap+CJK 가드를 실제 강제).
- homepage에 **kustomize render 테스트** 추가(grep-only가 못 잡는 조립 출력·인시던트 불변식 검증).

### 비목표
- **발견2(accounting CI)·발견4(글롭 비대칭)는 작업 없음** — grounding상 이미 강제/무력(§1). 발견4의 글롭 "정렬"은 오히려 charts/ 외부 테스트를 gate-run시켜 chart-test 컨벤션을 깨므로 **하지 않는다**.
- 기존 7 homepage grep 테스트 재작성 없음 — render 테스트를 **추가**(보완).
- gate 로직/타 워크플로 구조 변경 없음(check-skeleton 승격 + verify.yaml 중복제거만).

## 3. 설계: 3개 수정

### 수정 1 — CJK @test 이름 가드 (`check-skeleton.sh`에 추가)
- 전 tracked `*test_*.bats`를 스캔해 **실제 `@test` 선언의 이름에 CJK 문자**가 있으면 fail.
- 검출(perl, `-CSDA` UTF-8) — **검증 완료**(Phase C 정제 F2·F7 반영):
  ```bash
  perl -CSDA -ne 'print "$ARGV:$.: $_" if /^\s*\@test\s+"([^"]*)"/ && $1 =~ /[\p{Han}\p{Hangul}\p{Hiragana}\p{Katakana}]/' "$f"
  ```
  - **이름만 캡처** `"([^"]*)"` 후 $1 검사(F2) — 닫는 따옴표 너머 trailing **한국어 주석** false-positive 차단(주석 컨벤션이 한국어라 필수).
  - **Unicode 스크립트 속성** `\p{Han}\p{Hangul}\p{Hiragana}\p{Katakana}`(F7) — Ext-A(㐀)·compat 이데오그래프·Hangul 확장까지 포함(하드코딩 범위 누락 방지). 주석의 `# (@test …)` 언급·**em-dash(—)·Latin 악센트는 제외**(메모리: em-dash OK, 한글만 깨짐).
- perl은 러너(ubuntu-24.04-arm)·macOS 기본 제공. 현재 레포 위반 **0건**(즉시green; 있으면 영어로 수정).

### 수정 2 — `check-skeleton.sh`를 required gate로 승격
- ci.yaml `gate` 잡에 스텝 추가: `bash scripts/check-skeleton.sh`(네이밍+dirmap+CJK 가드 강제). `make ci`에도 미러.
- **verify.yaml 중복제거**: verify.yaml job `verify`의 check-skeleton 호출 제거(W7 게이트중복 정리 패턴 — 단일 권위). verify.yaml은 고유 책임(sops 왕복·pre-commit)만 유지.
- check-skeleton은 `git ls-files`+grep+perl만(라이브/네트워크 무관) → CI-safe·gate 적합. 현재 통과 상태라 승격 시 즉시green.

### 수정 3 — homepage kustomize render 테스트
- `platform/homepage/prod/test_homepage_render.bats`(신규, run-bats 수집 → gate 강제). homepage는 plain kustomize(configMapGenerator + resources, **helm/KSOPS/exec 불요**)라 `kustomize build platform/homepage/prod`로 렌더.
- 검증(조립 출력 — grep-on-source가 못 잡는 것):
  - 렌더 성공(exit 0) + 핵심 리소스 존재(Deployment/Service/HTTPRoute/NetworkPolicy/ConfigMap).
  - **인시던트 #65(EROFS) 회귀가드**: Deployment에 initContainer(seed-config) + config가 writable emptyDir 마운트(RO configMap 직접 마운트 아님).
  - **인시던트 #66(apiserver egress) 회귀가드**: NetworkPolicy egress가 apiserver를 **노드 서브넷:6443**(예: 192.168.139.0/24)로 허용(ClusterIP 10.43.0.1/32 아님).
  - configMapGenerator 해시 접미사·`namespace: homepage` 주입 등 조립 불변식.
- gate에 kustomize 설치됨(setup-toolchain). 정확한 불변식 표현은 Phase B에서 deployment.yaml/networkpolicy.yaml 실 구조로 확정.

## 4. 검증 전략

- **수정1**: 픽스처(한글 @test → fail, em-dash/ascii/주석 → pass) + 현재 레포 0 위반.
- **수정2**: check-skeleton 로컬 실행 0 이슈 + gate 스텝 추가 후 `make ci` 통과 + verify.yaml에서 중복 제거 확인.
- **수정3**: `kustomize build platform/homepage/prod` 성공 + 인시던트 불변식 단언. 기존 7 grep 테스트 회귀 없음.
- **게이트**: `make ci`(gate 미러). check-skeleton·render는 CI 도구(perl/kustomize)로 로컬 검증.
- bats: 한글 `@test` 금지(본 작업이 바로 그 가드!)·중간 단언 `[ ]`·`test_` 접두.
- accounting: 신규 test_homepage_render.bats는 run-bats 수집(gate 도메인) → `check-bats-accounting`이 자동 credit(n=1). check-skeleton은 스크립트(bats 아님)라 accounting 무관.

## 5. 위험 / 롤백

- 라이브(ArgoCD) 위험 **0** — `.github`·`scripts`·`tests`·homepage 테스트는 CI 전용(homepage 매니페스트 자체는 불변, 테스트만 추가).
- **CI gate 위험**: check-skeleton 승격이 기존 위반을 red로 드러낼 수 있음 → 현재 0 위반 확인했으나 PR 전 `make ci` 재확인. render 테스트가 homepage 조립 이슈를 드러내면(현 라이브는 안정) 그 자체가 가치(수정). 단일 PR이라 revert 단순.
- 한글 가드 정밀도: CJK만(em-dash 제외) — 과탐 시 정당한 em-dash 테스트명이 막힘 → 픽스처로 경계 고정.

## 6. 결정사항

- **D1 (한글 가드 위치)** → **check-skeleton.sh 추가 + gate 승격**(사용자 결정 2026-06-20). standalone bats 대신 check-skeleton에 넣어 **인접 갭(check-skeleton non-required)도 함께 해소** — 네이밍+dirmap+CJK 가드가 모두 required가 됨.
- **발견2/4 제외** → grounding으로 이미 강제/무력 확인(§1). 작업 안 함.

## 7. 범위 밖 (명시)

- accounting 글롭 정렬(발견4) — convention 강제 의도라 변경 시 오히려 위배.
- check-skeleton `dirs[]` 배열의 homepage 누락(별개 드리프트 — README dirmap 루프가 homepage를 이미 커버하므로 무해, 본 테마 밖).
- 기존 homepage grep 테스트 재작성·gate 타 스텝 변경.
