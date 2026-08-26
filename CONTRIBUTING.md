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
- 방출은 **헬퍼 경유만** — 셸은 `guard_skip`(scripts/lib/guard.sh), TS는 `skip()`(tools/lib/cli.ts).
  마커와 `exit 4`의 같은-줄 원자성은 이 구현 두 곳이 소유하므로, 콜사이트의 직접 방출은 짝이
  맞아도 위반이다(손조립 하나가 살아 있으면 원자성 주장이 두 번째 진실을 얻는다 —
  `scripts/check-skip-signalling.sh`가 강제, 게이트는 `tests/gates/test_guard-skip-signalling.bats`).
  **Makefile 레인만** 함수를 쓸 수 없어 옛 같은-줄 짝 검사로 잔존한다.
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
- 가드는 커널이 대신 낸다 — 바닥값을 통과하면 자동으로 나가고, 바닥값 없는 카운트 자리는 신호
  함수를 직접 부른다. 커널은 실행 환경별 **두 adapter**다: 셸 `scripts/lib/scan-floor.sh`
  (`scan_floor`·`scan_signal`) · TypeScript `tools/lib/scan-floor.ts`(`scanFloor`·`scanSignal`).
  규약(마커 형태·방출 순서·억제·SKIP 배타)은 하나이고 구현만 갈린다.
  ⚠️ 이는 위 "같은 검사의 셸·TS **이중 구현** 금지"의 대상이 **아니다** — 그 조항의 주어는 같은
  *검사*이고 괄호가 "파서·계산은 TS 한 곳에만"으로 못박는다. 스캔 커널은 도메인 판정이 없는 신호
  기계이고 임계값은 양쪽 다 콜사이트에 남으므로, 그 조항이 막는 해악(판정 드리프트) 밖이다.
  ⚠️ 셸이 TS 커널을 **부를 수 없어서**가 아니다 — `repo-walk.ts`는 `import.meta.main` CLI를 두고
  셸 가드 셋이 실제로 그렇게 부른다(`check-image-pins.sh` · `check-app-deploy.sh` · `check-app-netpol.sh`).
  스캔 커널이 그 길을 안 쓰는 이유는 **의미론**이다: 신호는 가드 실행마다 여러 번 나가 호출당 프로세스
  기동이 붙고, 무엇보다 바닥값 실패의 종료가 **호출자를 죽여야** 하는데 서브프로세스의 exit은 그러지
  못한다(셸 콜사이트의 `|| exit N` 관용구가 성립하지 않는다). 열거는 값을 돌려주면 끝이라 프로세스
  경계를 건널 수 있지만, 종료 제어는 건너지 못한다.
  두 adapter가 갈라지지 않는 근거는 대조가 실행 기반이라는 것이다:
  `tests/gates/test_scan-floor.bats`가 양쪽을 **실제로 실행해** 같은 정규식으로 방출을 파싱한다.
  ⚠️ 그 대조가 고정하는 것은 **마커 형태**뿐이다 — 바닥값 의미론과 종료 기전은 각 adapter의 자기
  테스트가 맡는다.
  ⚠️ TypeScript adapter는 셸에 없는 `parseFloor(raw, source)`를 하나 더 갖는다. `Number("")`가 0이고
  `n < NaN`이 항상 false라, 임계값 검증이 **coercion 앞에** 서지 않으면 오타 하나가 바닥값을 조용히
  끈다(실측: `DISK_CAP_MIN_FLAGS=abc` → 마커 방출 + rc=0). 셸엔 그 병이 없다 —
  `[ "$got" -lt "$min" ]`이 수가 아닌 값에 에러를 낸다.
- 한 실행이 **두 도메인**을 검사하면 라벨을 나눈다(`check-skeleton:bats` · `check-skeleton:platform`).
  같은 라벨로 두 줄을 내면 소비자가 어느 쪽인지 모른다.
- 기계 판독 stdout을 내는 모드(`--json`)에선 마커를 내지 않는다 — 출력을 오염시킨다.

**`SKIP:`과 배타적이다.** 한 실행이 둘을 같이 내면 안 된다: `SKIP:`은 “평가하지 않았다”(exit 4),
`SCAN:`은 “n건 평가했다”(정상 경로)다. 바닥값 **실패** 경로도 마커를 내지 않는다 — 그때의 건수는
“검사했다”가 아니라 “붕괴했다”는 뜻이라 같은 마커로 내면 정반대로 읽힌다.

**⚠️ 커버리지는 완전하지 않다** — 가드 전부가 신호를 내지는 않는다.

⚠️ **여기에 건수를 적지 않는다.** 예전엔 "28종 중 12종 · 라벨 17개"라고 적혀 있었는데 실측은
13종/31종 · 라벨 21개였고, `scripts/lib/scan-floor.sh`와 `PROGRESS.md`에는 **또 다른 숫자**가 박혀
있었다 — 아무도 대조하지 않는 손 관리 주장은 반드시 드리프트한다(티켓 09의 "원장 텍스트도 검증
대상"과 같은 모양). 현재값이 필요하면 세어라:

```
grep -lE '^[^#]*\b(scan_floor|scan_signal) ' scripts/*.sh
grep -lE '^[^/]*scan(Floor|Signal)\(' tools/*.ts
```

정합은 `tests/gates/test_scan-floor.bats`가 **정적 콜사이트 집합 == 런타임 방출 집합**으로 강제한다
(셸·TS 두 adapter 모두. 런타임 전용 라벨 `:accounted`도 그 모드를 실제로 호출해 덮는다 — 제외 목록 금지).

⚠️ **그 등식만으로는 커널 우회를 막지 못한다.** 정적 로스터와 실행 파일 목록이 같은 패턴에서 파생되므로,
한 가드가 직접 `console.log`로 되돌아가면 양쪽에서 동시에 빠져 등식이 그대로 성립하고 바닥값의 여유가
그 손실을 덮는다. 그래서 **거부 가드** `scripts/check-scan-producers.sh`가 따로 있다 — 추적
`tools/**/*.ts`·`*.mts`의 코드 줄(주석을 걷어낸 뒤)에서 **출력 동사의 인자가 마커 리터럴로 시작**하면 red
(`console.log("SCAN: …`, 여러 줄 호출 포함). 마커를 *다루는* 코드(`/^SCAN: /` 정규식·`startsWith("SCAN: ")`
소비자·마커 형태를 인용하는 진단문)는 그 선 밖이라 제외 목록이 필요 없다. 마커를 내는 코드는
`tools/lib/scan-floor.ts` 하나뿐이고, 그 파일도 건너뛰지 않는다 — 커널의 생산자 줄이 검출기에 보이는 것(≥1)이
"검출기가 코드를 읽고 있다"는 양성 대조다(파일 수 바닥값은 줄 단위 붕괴를 못 본다). 탐지기는 프록시다 —
조립한 문자열·동사 목록 밖 출력 경로는 보지 않는다(드리프트 거부가 목적이지 적대 우회 차단이 아니다).
거부 가드가 못 보는 손실이 하나 있다: 콜사이트 **삭제**(바닥값도 함께 사라진다)는 로스터 등식의 여유 안에서
조용히 통과하므로, 각 가드의 도메인 테스트가 자기 바닥값·마커를 단언하는 것이 그 자리의 방어다.
소비자는 “SCAN 없음”을 “픽스처”나 “0건”으로 읽으면 **안 된다** — 그건 **미지(unknown)** 다.
신호가 없는 가드에 대한 판정은 종전대로 과다 계상(있는 호출을 권위로 셈)에 머문다.

### 워크플로 준비상태 회계 — 원장 + 게이트 밖 accounting job

**병.** 자격/설정이 없어 GHA job이 통째로 skip되면 run은 **초록**이다. GHA job conclusion 어휘
(`success|failure|cancelled|skipped`)에는 "안 돌았다"가 없고, **스텝-레벨로 게이트된 job은 스텝을
전부 skip해도 `success`로 끝난다**. 게다가 skip된 job은 스텝을 0개 실행하므로 그 안의 실패 알림은
`if: always()`여도 함께 죽는다 → owner 신호가 정확히 **0**이다. 실측(2026-07-27): `tf-reconcile`의
`drift-github`·`drift-tailscale`은 시크릿 미등록으로 **한 번도 실행된 적이 없는데** 매 30분 초록이었다.

**규약.**
- 준비상태 게이트 = **자격 변수의 공백 검사**로 job/스텝을 끄는 것(`secrets.*`/`vars.*` env를
  `[ -n "$X" ]`로 재고 `<key>=false`를 `$GITHUB_OUTPUT`에 씀). 이 게이트를 가진 job은 **반드시**
  `policy/workflow-readiness.json`에 선언한다 — `required`(severity `error`/`warning`) ·
  `unconfigured`(알려진 갭, `since`+`owner_action` 필수) · `optional`(백스톱이 따로 있어 정당).
  **선언되지 않은 미설정은 정적 가드가 red로 막는다.**
- 스텝-레벨 게이트는 job에 `outputs.executed`를 승격한다. 승격 없이는 job이 항상 success라
  회계가 **원리적으로** 아무것도 관측할 수 없다.
- 각 워크플로는 게이트 **밖**에 `accounting` job을 둔다: `if: ${{ !cancelled() }}`(상태함수가 없으면
  기본 `success()`가 걸려 감시자가 감시 대상과 함께 skip된다) + 선언된 전 job을 `needs` + 
  `bun tools/check-workflow-readiness.ts --workflow <file>`.
- 알림 스텝은 **절대 감시 대상 job 안에 두지 않는다**(위 병의 정의 그 자체다).
- 선언된 갭(`unconfigured`)은 telegram을 울리지 않는다 — 매 주기 재발해 진짜 신호를 덮는다. 갭의
  venue는 run 로그 + job summary + 원장이다. 반대로 갭이 **닫히면**(선언은 unconfigured인데 실제로
  실행됨) 회계가 exit 1을 낸다: 현실과 어긋난 원장은 다음 사람에게 "원래 안 도는 것"으로 읽힌다.

**skip 신호(exit 4)를 쓰지 않는 이유.** 워크플로 계층엔 그 채널이 없다. `exit 4`를 낼 스텝 자체가
실행되지 않기 때문이다 — 관측은 job 밖에서만 가능하다.

**도메인-크기 게이트는 이 규약의 대상이 아니다.** "검사 대상이 0건이라 skip"은 자격 부재가 아니라
열거 붕괴 클래스이고 처방이 다르다(**바닥값** — 위 '가드 스캔 신호' 절). `dns-drift`가 그 예다:
`active&&public + platform_hosts == 0 → clean skip`이던 게이트를 없애고 `--min-reserved`(기본 1,
fail-closed) 바닥값으로 대체했다. 예약 platform host는 구조적으로 항상 ≥1이라 0은 "대상 없음"이
아니라 SSOT 부재/키 변경이기 때문이다.

### 이미지 소유권 회계 — freshness 소유자 ≠ digest 소유자

**병.** "핀이 있는가"(`scripts/check-image-pins.sh`)와 "핀이 **일치**하는가"와 "그 digest를 **누가
갱신하는가**"는 서로 다른 질문인데 하나로 뭉뚱그려져 있었다. 실측(2026-07-28): `pg-tools:18-rclone`이
두 digest로 갈렸는데 핀 게이트는 **둘 다 통과**시켰고, 갱신 도구는 하드코딩 4파일만 재핀하면서
성공을 보고했다. 그 4파일을 다시 하드코딩한 bats가 "단일 digest"를 확인해 초록이었다.

**규약.**
- 이미지 참조를 추가하면 **소유자가 계산되어야** 한다: ops 미러 이미지→`repin-ops-image` ·
  `apps/*/deploy/prod/values.yaml`·`.image-pin.json` descriptor→`bump-poll` · 그 외 추적 매니페스트→
  **Renovate 도달성 실측**(`managerFilePatterns` 매치 ∧ `ignorePaths` 비매치 — 분류표를 믿지 않는다).
- **소유자 없음은 결함이 아니라 선언 대상**이다. `policy/image-ownership.json`에 why·freshness·since·
  owner_action과 함께 적는다. **선언되지 않은 무소유는 통과할 수 없고**, 매치되지 않는 선언도 red다.
- **소비처 목록을 하드코딩하지 않는다.** 하드코딩은 자기 자신에 대해서만 정확하다 — 위 사례에서
  산출물 셋(도구 상수·bats 목록·헤더 주석)이 서로는 일치하고 레포와는 어긋났다. 레포에서 파생하고
  열거 붕괴는 바닥값으로 막는다.
- **freshness 소유자와 digest 소유자를 구별해 적는다.** helm 차트 내부 이미지는 차트 버전이 Renovate
  소유(freshness 있음)지만 렌더 시점 mutable tag라 digest 소유자가 없다. "Renovate 관할"이라고만
  적으면 그 차이가 지워진다.
- 벤더 파일도 **포함해** 본다. 수정 금지여도 소유자 질문에는 답(re-vendor 절차)이 있어야 하고,
  답이 없으면 그게 곧 결함이다.

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
make ci              # ci.yaml job 'gate'(유일 required check) 재현 — 차이는 policy/ci-parity.json에 계상
make verify          # (보조) skeleton + 메모리 원장 + sops 왕복 — 로컬 age 키 필요
pre-commit run -a    # (보조) 평문 시크릿 가드 + gitleaks
```
`make ci`가 통과하면 머지를 막는 required check는 통과한다(branch protection `contexts=[gate]`).

### 패리티 회계 — "재현한다"는 주장은 검증 대상이다

`make ci`가 gate를 재현한다는 **주장**은 오랫동안 검증되지 않았다. 대조하던 것이
`test_make-ci-parity.bats`의 **하드코딩된 5개 토큰**뿐이라, 목록에 없는 게이트 스텝은 아무리 늘어나도
보이지 않았다 — 실측 시점에 gate의 run 스텝 19건 중 **8건**이 `make ci`에 없었는데 전 검사가 초록이었다
(하필 그 5개가 전부 미러된 것들이라 우연히 통과했다). 티켓 07의 하드코딩 소비처 목록과 같은 클래스다.

이제 `tools/check-ci-parity.ts`가 **스텝 목록을 `ci.yaml`에서 파생해** 원장(`policy/ci-parity.json`)과
대조한다. **게이트 스텝을 추가하면 원장에 계상하기 전까지 red**다. 상태는 셋:

| status | 뜻 | 검증 방식 |
|---|---|---|
| `mirrored` | `make ci`가 같은 것을 돈다 | 선언한 `local` 문자열이 **`make -n ci` 실제 출력**에 있어야 한다 |
| `covered` | 로컬의 **다른 수단**이 덮는다 | `covered_by.file`에 `contains`가 실재해야 한다 |
| `excluded` | 로컬에선 안 돈다 | `why`·`since`·`owner_action` 전부 필수 |

⚠️ 이 원장은 "차이가 없다"가 아니라 **"모든 차이가 의도된 것이다"**를 강제한다. 완전 일치를 요구하면
docker 없는 환경에서 `make ci`가 못 돌고, 그러면 아무도 안 쓴다 — 그게 패리티가 실제로 무너지는 경로다.

⚠️ 도구가 없는 스텝은 `SKIP:` 마커를 내고 넘어간다(`actionlint`·docker·`node`). **조용히 건너뛰지 않는
이유**는 "로컬 초록"이 gate가 잡을 것을 못 본 채 push되는 것을 막기 위해서다.

⚠️ **`git add` 전에 `make ci`를 돌리면 새 파일은 측정되지 않는다.** 게이트가 `git ls-files`로 열거하기
때문이다 — untracked 파일은 로컬에서 대상 밖인데 커밋되면 CI에서는 측정된다. 실측: 새 `tools/*.ts`를
add 전에 검증해 1671건 전건 초록을 받고 커밋했더니 CI가 shebang 규약 위반으로 red를 냈다. `make ci`의
첫 전제(`ci-guard-tracked`)가 이 상태를 마커 + exit 4로 끊는다.

⚠️ **`make` 레시피에서 `$(MAKE)`를 쓰지 마라.** GNU make는 `$(MAKE)`가 있는 레시피 줄을 `-n`에서도
**실제로 실행한다**. 이 레포는 `make -n ci` 출력을 데이터로 읽으므로(패리티 미러 대조 ·
`check-guard-authority`의 venue 수집) 서브-make 하나가 드라이런을 부수효과로 바꾼다 —
실측: 게이트 스텝을 서브-make로 묶었더니 `make -n ci` 한 번에 docker e2e가 통째로 돌았다.
verify·pre-commit은 sops/시크릿 안전망이다. `make ci`는 시스템 PATH의 `bun`(1.3.14 핀)을 쓴다 —
설치는 `docs/runbooks-public/toolchain-setup.md` 참고(`m6-tools`가 버전 게이트).

## 문서 관례

### conductor 파이프라인 산출물 — 착지와 함께 지운다

`feature`/`bugfix`/`deepen` 컨덕터는 `docs/reviews/<slug>/`에 게이트 아티팩트(`<kind>-r<n>.json` ·
`decisions.md` · `verification.md` 등)를 쌓는다. 이건 **작업 중 상태**이지 레포의 산출물이 아니다.

- **gitignore하지 마라.** 컨덕터의 `plan-not-in-diff` preflight가 문서를 diff에서 찾는데, ignored
  파일은 diff에 영원히 안 나타난다(`--scope branch` 라운드는 오히려 전 bookkeeping 커밋을 요구한다).
  산출물은 tracked·커밋된 채로 살아야 파이프라인이 돈다.
- **PR 머지 직후 같은 브랜치에서 삭제한다** — 랜딩 체크리스트의 마지막 항목. 지우지 않으면
  라운드 수만큼 파일이 누적된다(실측: 한 슬러그에 `structure-r1`~`r18` + `bugfix-verify-*` 62파일).
- **삭제 전에 내구 지식을 승격한다.** 목적지는 셋 중 하나뿐: 되돌림이 쓰여질 바로 그 **코드 지점의
  주석** / `docs/traps-detail.md`(라이브에서 검증된 함정) / `docs/decisions/`(ADR). 어디에도 안 맞으면
  그건 과정 서사이므로 승격하지 않는다.
- 승격하지 않은 것은 git 히스토리에만 남는다. 그걸 감수한다는 뜻이다.

산출물 복구는 **삭제 커밋의 부모**에서 꺼낸다 — 삭제 커밋 자신에는 그 경로가 없다:

```bash
git log --diff-filter=D --name-only --format='%h %s' -- 'docs/reviews/**'   # 무엇이 언제 지워졌나
sha=$(git rev-list -n1 HEAD -- docs/reviews/<slug>/decisions.md)
git show "$sha^:docs/reviews/<slug>/decisions.md"                          # ^ 없으면 "path does not exist"
```
