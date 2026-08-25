# design — lib-convergence

> deepen 패스 산출물. 스캔(2026-08-25) → 그릴링 2라운드로 확정된 설계.
> 티켓 작성 기준 문서 — 여기 없는 결정은 티켓에서 새로 내리지 않는다.

## 주제와 선택

스캔의 횡단 관찰: 결함 클래스에 **lib으로 대응한 자리**(scan-floor.sh · host-port.sh ·
vmalert-e2e.sh)는 재발이 멈췄고, **탐지기·복붙으로 대응한 자리**는 같은 클래스가
반복됐다(awk fail-open 처방은 #525가 클래스를 명명하고도 #532에서 재발). 이 패스는
그 반복 지점 여섯을 deep module로 수렴한다.

**제외한 후보와 사유**:
- Verb descriptor 파생(동사당 편집 ~10곳) — homelab-cli structure 게이트 확정 사항의
  재론이라 기각. **ADR-0001** 참조. 동사 추가가 반복 비용으로 실증되면 재개.
- bats 스텁 커널 승격(`tests/helpers/stub.bash` — cli_stub의 PATH 대체·argv 원장·
  fail-closed 3처방을 손수 스텁 12파일에 공급) — **차기 패스 후보**. deepening 6 착지 후
  범위를 재평가한다.
- 짝 알림 양방향 실재 강제(check-alert-rules 모드 E) — **차기 패스 후보**. 현재 짝 규약은
  룰 주석 산문뿐(core.yaml:58·267).
- ensure-bump-pr ②결정 구간 export — **차기 패스 후보**(1909줄 파일 수술은 자체 패스 감).

## Deepening 1 — TS 가드 실행 커널

**신규 module 2개** (별도 유지 — 원장 없는 가드도 커널은 쓴다):

- `tools/lib/scan-floor.ts`: `guardMain({label, domains, output, check})` —
  `domains`는 **명명 스캔 도메인 컬렉션**(`[{name, min, enumerate}]`, 도메인별 독립
  floor), `output`은 **명시적 방출 정책**(기본 stdout 마커, `--json` 같은 기계 출력
  모드는 마커 억제를 선언적으로 — stdout 순수성 계약 보존). seam 뒤로 들어가는 순서:
  **전 도메인 열거 → 전 floor 판정 → (전부 통과 시에만) SCAN 일괄 방출 → 검사 →
  종료코드**. 단수 label/min 모델은 기각(design r1-3) — check-alert-rules(도메인 4)와
  check-guard-authority(도메인 2 + `--json`)를 표현하지 못해, 잔여 floor·마커가 check
  안으로 새면 커널이 없애겠다던 순서 드리프트가 재유입된다. 셸 커널
  `scripts/lib/scan-floor.sh`(소비자 15, 콜사이트↔방출 대조 테스트 보유)의 TS 이식이다.
- `tools/lib/policy-ledger.ts`: `readLedger({path, container, entrySchema})` —
  **축소 범위**(design r1-4): fail-closed 로딩(빈 원장 = red) + 컨테이너 shape 통일
  > 구현 정정(티켓 10): "빈 원장 = red"는 부재·파싱 실패에만 무조건 적용하고, **항목 수
  > 바닥값은 `minEntries`(기본 0)로 소비자가 소유**한다 — image-ownership의 빈 unowned는
  > 정당한 상태(무소유 0)로 실측됐고, "정당한 0건 vs 붕괴 0건"의 구별은 도메인 지식이라는
  > 셸 커널의 기존 규율과 정합해야 했다.
  (현행 4가지 → 1가지, 주석 키 `_readme`/`$comment` 통일) + `schema-check.ts` 재사용
  항목 검증**까지만** 소유. **미선언·죽은-선언 양방향 대조는 콜사이트에 남긴다** —
  소비자 3곳의 대조 의미론이 실질적으로 다르다(중첩 워크플로/job 신원 · CI-step
  커버리지 규칙 · 이미지 wildcard/면제 매칭). 공통 대조 interface는 공통형이 실증될
  때 추출한다(adapter 하나 = 가설 seam).

**이동하는 콜사이트** (7개): check-alert-rules · check-disk-caps · check-resource-limits ·
check-image-ownership · check-guard-authority · check-ci-parity · check-workflow-readiness.

**바닥값 어휘 일괄 전환**: `--min-scan`/`--min-refs`/`MIN_SCAN`/`MIN_STEPS`/`DISK_CAP_MIN_FLAGS`
5가지 → 커널 인자 1가지. 소비자는 Makefile·ci.yaml뿐(인레포)이라 **호환층 없이** 전환.

**선행 티켓 (tracer bullet — 실재 버그 2건 + 회귀 단언)**:
- `check-disk-caps.ts:120-125` — 위반 `exit(1)`이 SCAN 방출보다 먼저라, 위반 실행이
  "미실행"으로 읽힌다. 한 줄 이동.
- `check-alert-rules.ts:986-999` — SCAN이 바닥값 판정보다 먼저라, 열거 붕괴 실행이
  SCAN을 내고 죽는다(자기 주석 `:984`와 반대). 블록 이동.
- 두 건 모두 **순서를 재는 회귀 단언 동반** — 기존 test_scan-floor.bats는 TS 쪽 마커
  *모양*만 대조하고 순서는 무측정이었다.

**살아남는 테스트**: test_scan-floor.bats의 로스터 대조·마커 shape 단언은 유지하고
순서 축을 추가. 가드별 bats는 CLI 인터페이스 경유라 생존.

## Deepening 2 — 셸 가드 프롤로그 커널 `scripts/lib/guard.sh`

**interface 3함수**:
- `guard_init <가드이름>` — `set -euo pipefail` + `export LC_ALL=C` + `ROOT` 산출 +
  scan-floor source. 현행 프롤로그 4줄 × 15+파일(실측 비대칭 2건: check-image-pins만
  `$0`, `LC_ALL` 8/15) 흡수.
- `guard_skip <가드> <이유>` — SKIP 마커 stdout + `exit 4` 원자 방출. 현행 손조립 4곳
  (verify-credential-inventory · verify-runbook-index · secret-cert-check ×3 · Makefile) 중
  셸 3곳 흡수. TS 쪽은 `tools/lib/cli.ts`에 `skip(guard, reason): never` 신설(현행 주석
  산문 SSOT를 함수로).
- `detect_run <라벨> <awk프로그램> <파일...>` — 읽기가능성 프리체크 + rc 포착 +
  READFILES 열거수 대조. awk fail-closed 처방 22줄 × 3파일(check-host-ports:185 ·
  check-bats-style:55 · check-locale-collation:82) 흡수. 콜사이트는 awk 프로그램 본문만
  소유.

**검사 축 교체**: `check-skip-signalling.sh`의 "마커와 exit 4가 같은 줄" 검사를
**"헬퍼를 경유했는가"**로 교체(셸=guard_skip, TS=skip()). 언어별 awk 분기와
self-exclusion 소멸. **Makefile 레인만** 기존 형태 검사로 잔존(함수를 쓸 수 없는 자리).
CONTRIBUTING.md의 규약 문구(48-66행) 동반 갱신. `check-locale-collation.sh`에
"가드 자신이 guard_init를 부르는가" 레인 추가 — 새 가드의 프롤로그 누락이 정적 red.

## Deepening 3 — bump 계약 module `tools/lib/bump-plan.ts`

**interface**: plan 항목은 **런타임 디코드되는 판별 union**(design r1-1) —
`Change {target, lane, candidate, current, …} | Noop {target, reason} | Refusal {target, reason}`.
`Lane` union(`"bump" | "propose-pr"`)은 **Change에만** 있다 — 플래너는 noop·refuse도
적법하게 내므로 2-레인으로 좁히면 그 결과가 표현 불능이 된다. plan은 JSON 경계를
건너므로 TS 타입만으로는 부족하다: `decodePlan()`이 fail-closed로 검증하고, 미지
action·형식 위반은 조용한 skip이 아니라 red다.

target은 **판별 신원** `{kind: "app" | "bespoke", name}`(design r1-2) — apps 레인
(`.bindings.json`)과 베스포크 레인(`.image-pin.json`)은 인가 소스가 다르므로, kind 없는
이름은 동명 충돌 시 다른 target의 autoDeploy 정책을 적용하거나(승인 요구 PR을 자동
arm 포함) 브랜치를 공유해 PR을 덮어쓸 수 있다. `branchFor(target, tag)` +
`commitMessage(target, tag)` + `WRITER_IDENT` + `resolveLane(root, target)`(현행
`planApp`/`probeLane`의 **유일 구현**)이 전부 target 신원을 받는다.

**신원은 프로세스 경계를 관통해야 한다**(design r2-1) — module 안에서만 판별하고
argv에서 잃으면 원래의 모호성이 경계에서 재생된다:
- **CLI 계약**: run-bump-plan → ensure-bump-pr 호출은 `--kind app|bespoke --name <name>`
  으로 target을 온전히 전달한다. 어느 한쪽이라도 부재하면 **fail-closed**(현행
  `--app` 무한정 이름 계약은 폐지 — 파일시스템 정책 소스 추측 금지).
- **왕복 소유**: bump-plan이 브랜치 **인코딩(`branchFor`)과 역디코딩(`parseBranch`)을
  둘 다** 소유한다 — ensure-bump-pr의 형제 스윕·소유 증명 검증이 브랜치명에서 target을
  복원할 때 같은 module을 지나므로, 인코딩·디코딩이 어긋날 자리가 없다.
- **레거시 이행**: 기존 무한정 브랜치명(구 명명으로 열려 있는 bump PR)은 이행 판정을
  bump-plan이 소유한다 — 구형은 app으로만 해석하되 동명 bespoke가 실재하면 fail-closed.
- **e2e**: 동명 app/bespoke 시나리오가 runner → ensure-bump-pr → reconcile-only 경로를
  관통하는 테스트를 신설한다.

**흡수하는 중복**: plan.json 계약 3벌 독립 선언(poll-ghcr:96 `Plan` ·
run-bump-plan:61 `PlanItem` — optionality 상이 · ensure-bump-pr:232 `LANES`),
명명 계약 6개의 생산자↔검증자 복제(브랜치 run-bump-plan:101↔ensure-bump-pr:326 ·
커밋 문구 :127↔:499 · writer 신원 :30↔:220,485,502), 그리고 ensure-bump-pr:1224의
**복붙-주석 seam**(poll-ghcr 소스를 주석으로 붙여넣어 동기화하던 것) 제거.

**이동 콜사이트**: poll-ghcr.ts · run-bump-plan.ts · ensure-bump-pr.ts · bump-tag.ts.
`action` 오타·미지 값은 `decodePlan()`의 런타임 red — 컴파일 red(TS)와 이중이다.

**살아남는 테스트**: test_ensure-bump-pr.bats 118건 중 **호출 계약이 바뀌는 행
(`--app` → `--kind`/`--name`)은 갱신**하고 나머지는 argv 인터페이스 경유라 생존
(design r2-1 정정 — "전량 생존" 주장은 CLI 계약 변경과 모순이었다).
계약 module 단위 bats 신설(명명 왕복: `branchFor` 산출을 `parseBranch`가 복원).

## Deepening 4 — 앱 표면 module `tools/lib/app-surface.ts`

**interface**: `appPaths(root, app)`(경로 SSOT) + `readAppSurface` + `writeAppSurface` +
`removeAppSurface`. **함수 API 형태**(표면 목록의 데이터화는 기각 — 표면마다 쓰기
로직이 달라 데이터에 욱여넣게 된다). autoDeploy 해석·파일 부재 처리 단일화
(`image-pin.ts:descriptorAutoDeploy`는 값 해석 SSOT로 재사용).

**대칭 강제**: create가 쓰는 표면 집합 = teardown이 지우는 집합. module 테스트의
집합 동일성 단언으로 강제(현행: create 8표면 명시 vs teardown 4표면 + rmSync).

**이동 콜사이트**: create-app:182 · teardown-app:46 · lib/status.ts:60 · poll-ghcr:139 ·
ensure-bump-pr:1266 · lib/verbs.ts surfacePath · audit-orphans · bump-tag —
`deploy/prod` 경로 리터럴 16파일/36곳.

## Deepening 5 — 발화 e2e `vme_scenario` + bulkssd 흡수

**interface**: `vme_scenario <net> <stack> <rules> <fixture>` 하나가
workspace → derive → start → import 순서를 내부 소유. **전역 `VME_*` 출력 변수는 유지**
(마찰의 근원은 전역이 아니라 암묵 순서 — #395·#392 둘 다 순서 사고).

**bulkssd 흡수 — 실측 확정 범위** (구조적 장애물 없음, 순전히 역사적 미이관: lib
골격 함수가 bulkssd 생성 다음 날 #355에서 생겼고 #413이 drift만 이관):
- `vme_workspace`·`vme_derive_stack_params` 채택 — drift가 #413에서 쓴 2줄 alias 기법
  (`TMP="$VME_TMP"`) 재사용.
- `alert_expr`/`rollup_windows` byte-identical 사본(:118-124) 삭제.
- **lib 주석 거짓 서술 정정**(lib:276-278 "프리미티브는 전부 여기로 흡수됐다" —
  bulkssd에 대해 거짓. #413이 백로그 마커를 지우며 잘못 다시 쓴 것).
- **로컬 유지가 정당한 것**: `fault`/`contract`/`fail`/`pass`(문서화된 하네스-로컬 정책 —
  `(preflight)` 라벨 + 로컬 집계가 진단의 절반, drift:52-55·lib:276 교차 근거),
  2-피연산자 rollup preflight(:158-186, `vme_assert_rollup_ok`가 표현 불가).

**단언 확장**: test_vmalert-e2e-replay-timing.bats의 "lib 밖 사본 0"을 expr·rollup
헬퍼까지 확대. **판정 어휘는 측정 도메인에서 명시 제외**(정당한 로컬 정의).

## Deepening 6 — 실행 seam: `exec.ts` → 4 명명 adapter

**interface**: `gh()` · `git()` · `kubeseal()` · `sh()` + 결과에 `errKind`(ENOENT 등 실행
실패 종류) + env 주입 지점 1개(테스트 원장). **판정 정책은 콜사이트 소유 유지** —
exec.ts 헤더의 기존 원칙. doctor의 자체 `gh()`(미설치 ENOENT 판별)는 adapter의
`errKind`로 흡수하되 판별 로직은 doctor 콜사이트에 남는다.

**두 adapter가 seam을 real로**: prod spawnSync + 테스트 인-프로세스 원장.
장기적으로 cli_stub.bash(478줄) PATH-대체 하네스의 축소 경로.

**이관은 클러스터 단위 티켓** (30곳/20파일 일괄 금지 — 리뷰 불능):
① seam 신설 → ② bump 계열(deepening 3 착지 후) → ③ check 계열(deepening 1 착지 후)
→ ④ 나머지.

## 티켓 체인과 블로킹 엣지

```
체인 A (d1): 순서 버그 2건+회귀 단언 → guardMain → policy-ledger → 가드 7개 이관
체인 B (d2): guard.sh 신설 → 셸 가드 15+ 이관 → skip-signalling 축 교체+CONTRIBUTING 갱신
체인 C (d3→d4→d6): bump-plan → app-surface → exec seam 신설 → bump 클러스터 이관
                    → check 클러스터 이관 → 나머지 이관
체인 D (d5): vme_scenario → bulkssd 흡수+주석 정정 → 단언 확장
교차 엣지: 체인 A 완료 → 체인 C의 "check 클러스터 이관"
          (같은 check-*.ts를 두 티켓이 동시에 열지 않게)
A·B·D는 상호 병렬. B와 A는 파일이 겹치지 않는다(TS vs 셸).
```

## 테스트 생존 요약

- 가드별·CLI별 bats는 전부 인터페이스(argv/CLI) 경유라 생존.
- test_scan-floor.bats: 유지 + TS 순서 축 추가.
- test_ensure-bump-pr.bats 118건: 생존(argv seam 불변).
- test_vmalert-e2e-replay-timing.bats: 유지 + 사본-0 도메인 확장(판정 어휘 제외 명시).
- 신설: bump-plan 명명 왕복 · app-surface 집합 대칭 · policy-ledger shape/fail-closed
  로딩 · guardMain 순서 · guard.sh 3함수.
- 신설(design r1 수용분의 설계 수준 케이스): noop/refuse plan 디코드 왕복 ·
  malformed 직렬화 plan의 fail-closed 거부 · 동명 app/bespoke target의 브랜치·인가
  분리 · 다중 도메인 스캔의 "전 floor 통과 후 일괄 방출" 순서 · `--json` 모드
  stdout 순수성(마커 미오염).
