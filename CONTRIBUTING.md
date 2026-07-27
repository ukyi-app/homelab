# 기여 가이드 — Homelab Platform

이 레포는 GitOps 모노레포(SSOT)다: git이 문자 그대로의 단일 진실 공급원이고,
ArgoCD가 클러스터를 수렴시킨다. 클러스터에서 손으로 바꾸는 것은 아무것도 없다.

## 황금률
1. **검증 우선.** 모든 변경은 "변경 전에는 실패하고 변경 후에는 통과하는" 체크와
   함께 나간다. push 전에 로컬에서 `make verify`를 실행한다.
2. **평문 시크릿은 절대 금지.** 플랫폼 시크릿은 `*.enc.yaml`이며, 두 age recipient
   (cluster + recovery, `docs/runbooks/age-keys.md` 참고 — gitignored, owner 로컬 전용이라
   신규 체크아웃에선 이 링크가 열리지 않는다)로 SOPS 암호화한다.
   앱 시크릿은 controller가 봉인하는 **SealedSecrets**를 쓴다(하이브리드 모델 —
   `docs/decisions/0001-secret-management-hybrid.md`). pre-commit 가드 + gitleaks가
   실수를 막는다. 개인키는 절대 커밋하지 않는다
   (`.gitignore`가 `*.agekey`, `keys.txt`, `.env*`를 커버).
3. **환경(env)은 경로에 산다.** `<env>`(`prod`, 이후 `staging`)는 디렉토리
   세그먼트다: `platform/<svc>/<env>/...`, `apps/<name>/deploy/<env>/values.yaml`.
   env 추가 = 디렉토리 추가 + `.sops.yaml` 규칙 블록 추가 — 리팩터링 불필요.
4. **메모리 원장을 존중한다.** 새 워크로드나 리소스 변경은
   `docs/memory-ledger.md`를 갱신한다; limit 합계가 예산을 넘으면 CI가 실패한다
   (`bun run verify:ledger`). 예산은 OOM에서가 아니라 경계에서 고친다.
5. **앱은 불투명한 컨테이너다.** 온보딩 = 공유 `platform/charts/app` 차트용
   `values.yaml`. 이미지 계약: `/health`(liveness·readiness), :8080 http, :9090 metrics(opt-in),
   non-root, 부팅 시 self-migrate. 런타임별 메모리는 강제 온보딩 게이트다.

## 새 코드 배치 규칙 — 셸 vs TS (게이트 언어 2원화)

게이트·도구가 bash+yq+python3처럼 한 파일 안에서 언어를 넘나들면 typecheck·lint·테스트가
전부 사각이 된다(구 `check-resource-limits.sh` 사례). 새 코드는 아래 기준으로 배치한다:

- **셸(`scripts/*.sh`)** — 라인 지향 검사(grep/yq/jq 필터, 파일 존재·인덱스 대조), 라이브 클러스터
  운영 절차(kubectl/argocd), 시크릿 봉인 파이프(kubeseal/sops stdin — 평문 비기록).
  bash 3.2 호환 + shellcheck clean 필수.
- **TS(`tools/*.ts`, bun 전용)** — 계약 검증(스키마·비즈니스 규칙), 구조 데이터 순회·계산
  (JSON/YAML 파싱·합산·레지스트리 조작), 산출물 생성. `bun run typecheck`에 자동 편입.
  공용 로직은 `tools/lib/`(SSOT) — 콜사이트 인라인 사본 금지(원장 행 파서 3벌 독립 구현 사례).
- **금지** — 셸 heredoc으로 python/node 등 제3 언어 내장(typecheck 사각), 같은 검사의 셸·TS
  이중 구현(원장 awk↔TS 파서 드리프트 사례 — 파서·계산은 TS 한 곳에만).
- **워크플로 인라인 셸 최소화** — run 스텝이 ~20줄을 넘거나 JSON/YAML 구조 파싱을 시작하면
  `tools/*.ts`(또는 `scripts/*.sh`)로 내려 테스트를 붙인다. **선례(해소됨)**: bump-poll의 while-loop이
  제4계층(항목 격리·errexit 관용구·트랜잭션 정리)으로 자라 있었다 → `tools/run-bump-plan.ts`로 내리고
  스텝은 **한 줄**이 됐다(F-1). 이관 원칙은 계약도 함께 옮기는 것이다: 워크플로 게이트가 강제하던
  실행 증인(순서·레인 verbatim·격리·소유권)은 러너 스위트로 가고, 워크플로엔 **경계**만 남는다
  (그 스텝의 명령이 러너 호출 하나뿐 — 남기지 않으면 계약이 조용히 증발한다).
- **종료코드 규약(가드·도구 공통)** — `tools/lib/cli.ts` 주석이 SSOT: 0=성공 · 1=검증/게이트 실패 ·
  2=사용법/플래그 파싱 · 3=race · **4=skip**(도메인 부재 — 아래 절).

### 가드 skip 신호 — `exit 4` + `SKIP:` 마커

**병.** 가드가 "검사할 도메인이 없어서 건너뜀"과 "검사했고 통과함"을 **둘 다 exit 0**으로 냈다.
호출자·CI·사람 누구도 구별할 수 없으니 가드가 실제 실행 경로를 잃어도 전 게이트가 초록이다.
실측: `scripts/verify-runbook-index.sh`는 `docs/runbooks/`가 gitignored라 CI에서 무조건 skip이었고,
그 bats 래퍼는 `[ "$status" -eq 0 ]`만 단언했다 — **skip 경로가 그 단언을 만족**했다.

**규약.**
- 도메인 부재로 불변식을 평가하지 못하면 `SKIP: <가드>: <이유>`를 stdout에 내고 **exit 4**.
- 마커와 `exit 4`는 **같은 줄**에 둔다. 짝을 정적으로 검증할 수 있게 하려는 제약이다
  (`tests/gates/test_guard-skip-signalling.bats`가 강제 — mutation 테스트로 load-bearing 실측).
- 평가한 실행은 마커를 내지 않는다: 0=평가·통과, 1=평가·실패.
- 각 가드의 bats 래퍼는 **두 갈래를 각각 단언**한다. `[ "$status" -eq 0 ]` 하나만 두면 skip이
  그 단언을 만족해 래퍼가 vacuous해진다. 도메인을 주입할 시임(픽스처 트리·`RUNBOOK_DIR` 같은
  변수 오버라이드)이 없으면 만들어서 두 갈래를 실증한다.

**왜 마커만으로 끝내지 않는가.** stdout 마커만 두면 기본 종료코드가 여전히 0이라 이 규약을 모르는
호출자에게는 병이 그대로 남는다. 4는 `set -e`·make·CI에서 저절로 드러난다. 실제로
`scripts/netpol-rehearsal.sh`는 candidate NetworkPolicy를 적용한 뒤 `make verify-posture`로 검증하는데,
skip이 0이던 동안 그 리허설은 **아무것도 검증하지 않고 PASS를 찍을 수 있었다**.

**왜 2를 재사용하지 않는가.** 2는 사용법/파싱 오류다. `scripts/secret-cert-check.sh`가 skip에 2를
쓰고 있었는데 같은 파일이 unknown-option에도 2를 쓴다 — 한 코드에 두 의미였다. 4로 갈랐다.

**make 계층 예외.** GNU make는 recipe 종료코드를 자기 Error 2로 뭉갠다. `make verify-posture` 같은
가드 타깃은 recipe에서 `exit 4`를 내지만 make 프로세스는 2로 끝난다 — 이 계층에서 관측 가능한 신호는
**마커 + 비-0**까지다(원래 코드는 make의 `Error 4` 메시지에만 남는다).

**적용 범위 = 가드 진입점.** 집계자(`make ci`·`make verify`)는 대상이 아니다. 자식을 조건부로
건너뛰는 것은 도메인 부재가 아니라 실행처 선택이고(`make ci`의 docker 분기는 gate가 실제로 평가한다),
집계자가 4를 내면 push 전 진입점이 못 쓰게 된다.

### 가드 스캔 신호 — `SCAN: <가드>: <n>`

**병.** 가드가 CI에서 **돈다는 사실**(권위 실행 경로 — `tools/check-guard-authority.ts`)과 그 호출이
**가드의 실제 도메인에 닿았다는 사실**은 다른데, 텍스트로는 갈리지 않는다. 실측 반례 둘:
`tests/test_alert_rules.bats:116`은 루트 인자가 **실 레포**를 가리키고(“인자가 있으면 픽스처”가 거짓),
`tools/tests/test_app-deploy.bats`는 한 파일 안에 픽스처 호출과 실 트리 호출이 섞여 있다.
그래서 회계가 과다 계상 쪽으로 기울어 있다 — 픽스처 전용 호출도 권위로 센다.

**규약.**
- 도메인을 평가한 실행은 `SCAN: <가드>: <건수>`를 **stdout**에 낸다(`SKIP:`과 같은 채널·같은 모양).
- 셸 가드는 커널이 대신 낸다 — `scan_floor`가 바닥값을 통과하면 자동, 바닥값 없는 카운트 자리는
  `scan_signal <라벨> <n>`을 직접 부른다(`scripts/lib/scan-floor.sh`).
- 한 실행이 **두 도메인**을 검사하면 라벨을 나눈다(`check-skeleton:bats` · `check-skeleton:platform`).
  같은 라벨로 두 줄을 내면 소비자가 어느 쪽인지 모른다.
- 기계 판독 stdout을 내는 모드(`--json`)에선 마커를 내지 않는다 — 출력을 오염시킨다.

**`SKIP:`과 배타적이다.** 한 실행이 둘을 같이 내면 안 된다: `SKIP:`은 “평가하지 않았다”(exit 4),
`SCAN:`은 “n건 평가했다”(정상 경로)다. 바닥값 **실패** 경로도 마커를 내지 않는다 — 그때의 건수는
“검사했다”가 아니라 “붕괴했다”는 뜻이라 같은 마커로 내면 정반대로 읽힌다.

**⚠️ 커버리지는 완전하지 않다.** 오늘 신호를 내는 것은 가드 27종 중 **11종**(셸 8 + TS 3),
라벨로는 **15개**(셸 10 + TS 5)다.
소비자는 “SCAN 없음”을 “픽스처”나 “0건”으로 읽으면 **안 된다** — 그건 **미지(unknown)** 다.
신호가 없는 가드에 대한 판정은 종전대로 과다 계상(있는 호출을 권위로 셈)에 머문다.

## 커밋 메시지 (한국어 conventional commits)
`type: 설명` — type ∈ `feat | fix | refactor | style | docs | test | chore`.
AI 마커 금지, Co-Authored-By 금지. 커밋 하나에 논리적 변경 하나.

## 로컬 셋업
- 호스트 툴 설치: **`docs/runbooks-public/toolchain-setup.md`**(tracked — 최소 핀/설치 가이드).
  전체 운영 런북 `docs/runbooks/toolchain.md`은 gitignored(owner 로컬 전용).
- `bun install`
- `pre-commit install`
- 로컬 복호화: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`

## push 전에
```
make ci              # ci.yaml job 'gate'(유일 required check)을 로컬에서 그대로 재현
make verify          # (보조) skeleton + 메모리 원장 + sops 왕복 — 로컬 age 키 필요
pre-commit run -a    # (보조) 평문 시크릿 가드 + gitleaks
```
`make ci`가 통과하면 머지를 막는 required check는 통과한다(branch protection `contexts=[gate]`).
verify·pre-commit은 sops/시크릿 안전망이다. `make ci`는 시스템 PATH의 `bun`(1.3.14 핀)을 쓴다 —
설치는 `docs/runbooks-public/toolchain-setup.md` 참고(`m6-tools`가 버전 게이트).

## 문서 관례
- **계획 문서 크기**: `docs/plans/`는 검색 노이즈를 줄이기 위해 간결히(권장 상한 ~1500줄/문서). 대형
  산출물은 요약 SSOT + 링크로 분리한다. 히스토리 재작성은 하지 않고 `.rgignore`가 검색에서 제외한다.
