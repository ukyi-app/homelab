# 테마4 설계: CI/CD 공급망 + gate 의미검증

- 날짜: 2026-06-20
- 상태: 설계 승인됨(사용자 확정 2026-06-20) — Phase B(writing-plans) 진입 대상
- 워크트리: `.claude/worktrees/feat+cicd-supply-chain` (브랜치 `worktree-feat+cicd-supply-chain`, origin/main `37e4d19` 분기)
- 출처: 2026-06-19 홈랩 10차원 심층 감사 8테마 로드맵의 테마4 ("CI/CD 공급망+gate 의미검증", 고/저·M)

## 1. 배경 / 문제

GitHub Actions CI/CD가 **공급망 핀과 gate 의미검증에 4개 갭**이 있다. 라이브(ArgoCD)엔 무영향(.github 미싱크)이나, required `gate`가 머지 권위라 갭이 누출/우회 표면이 된다. 4발견 전부 라이브 grounding:

| # | 발견 | 라이브 근거 |
|---|---|---|
| 1 | App토큰은 **SHA-pin**(`create-github-app-token@bcd2ba4…`)·setup-bun·setup-node도 SHA-pin인데, **mutable `@vN` 액션 다수**가 같은 워크플로/잡에 — `actions/checkout@v4`(30회/19파일)·`hashicorp/setup-terraform@v3`(6)·`docker/login-action@v3`·`docker/build-push-action@v6`·`docker/setup-buildx-action@v3`·`actions/cache@v4`·`actions/{up,down}load-artifact@v4`. 토큰/시크릿/레지스트리 민팅 잡의 mutable 액션이 태그 이동 시 **민팅된 토큰을 변조 액션에 넘긴다** — SHA-pin 방어 무력화. repo의 "액션은 full SHA 핀" 규약과 불일치. | `grep -rE 'uses: …@v[0-9]' .github/` |
| 2 | required `gate`(ci.yaml job `gate`, 유일 required check)에 **actionlint 부재** — `run:` 셸인젝션·워크플로 문법/표현식 오류가 정적 미검출. shellcheck는 추적 `.sh`만(ci.yaml:72), 워크플로 인라인 `run:`·`uses:`는 사각. | ci.yaml 전체에 actionlint 0건 |
| 3 | **4 공개 디스패처(+dns-drift)가 setup-bun 인라인 복붙** — version SSOT 컴포지트(`./.github/actions/setup-bun`) 미사용. reusable(_create-*)·ci·bump·audit은 컴포지트 사용. | create-app:29·create-cache:26·create-database:26·update-secrets:26·dns-drift:19 = `oven-sh/setup-bun@SHA` 인라인 |
| 4 | gitleaks 버전 추출이 **`grep -A2` 라인오프셋 의존** — `.pre-commit-config.yaml` 포맷 드리프트 시 빈 버전 → gate 깨짐. yq는 이미 같은 잡에 설치됨(setup-toolchain). | ci.yaml:39 `grep -A2 'gitleaks/gitleaks' … | grep -oE 'rev: v…'` |

## 2. 목표 / 비목표

### 목표
- mutable third-party 액션을 **SHA-pin**하고 가드 테스트로 회귀 차단(공급망 표면 제거).
- required `gate`에 **actionlint**를 추가해 워크플로 `run:` 셸인젝션·문법 오류를 정적 게이트.
- 디스패처의 setup-bun 복붙을 **version SSOT 컴포지트로 수렴**(동작보존).
- gitleaks 버전 추출을 **구조적(yq)**으로 — 라인오프셋 취약 제거.

### 비목표
- **github-actions Renovate 활성화는 범위 밖**(D2) — writer App `workflows:write`(owner-local Terraform github 루트) + renovate config 필요. 기존 SHA 핀(setup-bun/node/app-token)도 manual 관리이므로 manual 일관. 활성화는 별도 owner-local follow-up.
- 워크플로 로직/동작 변경 없음 — 핀·정적검사·DRY·버전추출만. 각 워크플로의 트리거·권한·잡 구조는 불변.
- 1st-party만 골라 면제하지 않는다 — repo는 이미 setup-node(actions/\*)도 SHA-pin. 전 third-party 일관.

## 3. 설계: 4개 수정

### 수정 1 — mutable 액션 SHA-pin (comprehensive, 가드)
- **스코프=comprehensive**(사용자 결정 D1): 전 third-party mutable `@vN`을 현재 태그가 가리키는 commit SHA로 핀 + `# vN.N.N` 주석(기존 핀 스타일). 로컬 `./.github/actions/*`는 핀 대상 아님(repo 내부).
  - 대상 클래스: `actions/checkout`(30)·`hashicorp/setup-terraform`·`docker/login-action`·`docker/build-push-action`·`docker/setup-buildx-action`·`actions/cache`·`actions/{up,down}load-artifact`. (이미 SHA-pin: `create-github-app-token`·`oven-sh/setup-bun`·`actions/setup-node` — 불변.)
  - SHA 해석: 각 `owner/action@vN`의 vN 태그 → `gh api repos/<owner>/<action>/git/ref/tags/<vN>` 또는 release commit. **mutable 태그가 가리키는 그 시점 SHA**를 핀.
- **가드 테스트**(신규 bats): `.github/`에 `uses: <non-local>@v[0-9]` 잔존 0 + 로컬 `uses: ./` 면제. 회귀(누가 새 워크플로에 `@v4` 추가) 차단. SHA-pin은 `# vN` 주석과 무관(주석은 `@` 직후 아님).
- **freshness=manual**(D2): 기존 SHA 핀과 동일 관리. (Renovate 활성화는 비목표.)

### 수정 2 — actionlint를 required gate에
- `setup-toolchain` 컴포지트에 `actionlint` 입력 추가(`curl`+공식 checksum, 기존 도구 패턴 — placeholder 금지, 실 SHA256). `rhysd/actionlint` 릴리스 linux_arm64.
  - 체크섬 강제 테스트(setup-toolchain checksum 가드)에 actionlint 항목 추가.
- ci.yaml `gate` 잡에 스텝 추가: `actionlint`(전 `.github/workflows/*.yaml` 검사 + `run:` 블록 shellcheck 통합).
- ★**actionlint가 기존 워크플로의 잠복 이슈를 처음 드러낼 수 있다** — 추가 시 드러난 것(셸인젝션·표현식 오류·미사용 등)을 **함께 수정**해야 gate green. 무시(`# actionlint-disable`)는 정당화된 경우만.

### 수정 3 — setup-bun 컴포지트로 디스패처 수렴 (동작보존)
- `setup-bun` 컴포지트에 `install` 입력 추가(기본 `'true'` — 기존 컴포지트 사용처 무영향). `install != 'true'`면 `bun install --frozen-lockfile` 스킵.
- 4 디스패처(create-app/create-cache/create-database/update-secrets) + dns-drift의 인라인 `oven-sh/setup-bun@SHA`(+bun-version)를 `uses: ./.github/actions/setup-bun` `with: { install: 'false' }`로 교체.
  - **`install: false` 필수**: 디스패처 validate 잡은 `bun tools/validate-mutation.ts`만 실행하고 deps(yaml 등) 불요 — 컴포지트 기본(install:true)을 쓰면 불필요한 `bun install`이 추가됨(동작보존 위배). dns-drift도 현재 동작 확인 후 맞춤.
- 효과: bun 버전 핀이 단일 SSOT(컴포지트)로 — 디스패처별 인라인 핀 드리프트 제거.

### 수정 4 — gitleaks 버전 추출을 yq 구조 쿼리로
- ci.yaml:39 `ver=$(grep -A2 'gitleaks/gitleaks' … | grep -oE 'rev: v…' | grep -oE '[0-9.]+')` → yq(mikefarah, setup-toolchain이 같은 잡에 설치):
  ```
  ver=$(yq '.repos[] | select(.repo == "https://github.com/gitleaks/gitleaks") | .rev' .pre-commit-config.yaml | sed 's/^v//')
  ```
  (또는 `.rev | sub("^v"; "")`.) 라인오프셋 무관·포맷 드리프트 견딤. 빈 결과면 `set -e`/명시 체크로 fail-loud(현재도 빈 버전이면 curl 404로 깨지나, 명시 가드 권장).
- ★순서 확인: gitleaks 스텝(L34-51)은 setup-toolchain(yq 설치, L24-33) **뒤**라 yq 사용 가능.

## 4. 검증 전략

- **수정1**: 가드 bats(잔존 0) + 핀 후 워크플로 문법 유효(actionlint/`gh workflow` 또는 수정2의 actionlint가 동시 검증).
- **수정2**: actionlint를 로컬 설치 실행 → 드러난 이슈 0(또는 수정 완료) 확인. 체크섬 가드 통과.
- **수정3**: 컴포지트 `install` 분기 동작 — 디스패처 validate가 `bun install` 없이 validate-mutation 실행(동작보존). 컴포지트 렌더/문법.
- **수정4**: `.pre-commit-config.yaml`에서 yq가 `8.18.4` 정확 추출 단언(현재 grep과 동일 결과 + 라인 이동시에도 견딤) 테스트.
- **게이트**: `make ci`(gate 미러) — 단 **actionlint/yq/gitleaks는 CI 러너 도구**라 로컬은 setup-toolchain 경로 또는 설치본으로 검증. ★**gate는 유일 required check** — 깨지면 전 머지 차단이므로 PR 전 actionlint·yq 추출·gitleaks 스텝을 로컬에서 실행해 green 증명.
- bats: 한글 `@test` 금지·중간 단언 `[ ]`·`test_` 접두(검증된 함정).

## 5. 위험 / 롤백

- 라이브(ArgoCD) 위험 **0** — .github 미싱크.
- **CI gate 위험 실재**: actionlint 추가가 기존 이슈를 red로 만들거나, yq/checksum 오류가 gate를 깰 수 있음 → 머지 전 로컬 검증 필수. 단일 PR이라 revert 단순(`git revert`).
- SHA 핀은 mutable 태그의 **현재** SHA로 — 잘못된 SHA는 액션 resolve 실패(즉시 red, 안전). 핀 후 워크플로가 실제 도는지 1건 스모크 권장.
- 디스패처 컴포지트 교체: `install:false` 누락 시 불필요 install만 추가(무해, 그러나 동작보존 위배라 테스트로 강제).

## 6. 결정사항

- **D1 (발견1 스코프)** → **comprehensive**(사용자 결정 2026-06-20). 전 third-party mutable 액션 SHA-pin + 단순 가드(`@v[0-9]` 잔존 0). repo SHA-pin 규약 일관·회귀 차단 단순.
- **D2 (발견1 freshness)** → **manual 핀**(기존 setup-bun/node/app-token과 동일). github-actions Renovate 활성화(writer App workflows:write, owner-local)는 **별도 follow-up**.
- **D3 (발견3 동작보존)** → 컴포지트 `install` 입력(기본 true) 추가, 디스패처 `install:false`로 no-install 보존.

## 7. 범위 밖 (명시)

- github-actions Renovate 활성화 / writer App 권한 변경(owner-local Terraform).
- 워크플로 트리거·권한·잡 구조·로직 변경.
- 이미 SHA-pin된 액션(app-token/setup-bun/setup-node) 재핀.
- 벤더/외부(reusable-app-build가 외부 앱 레포 계약인지 등은 핀만, 계약 변경 없음).
