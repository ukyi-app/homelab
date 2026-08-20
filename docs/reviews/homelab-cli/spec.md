# Spec — homelab CLI (앱 배포·리소스 조작 통합 CLI)

Status: ready-for-agent

## Problem Statement

앱 하나를 배포하려면 owner가 여러 표면을 오가야 한다: 템플릿에서 앱 레포를 만들고 스캐폴드를
직접 돌리고, GitHub 웹 UI에서 변이 디스패처(workflow_dispatch) 폼을 열어 입력하고, run 결과와
PR·auto-merge·ArgoCD 상태를 각각 따로 확인한다. 시크릿 갱신은 seal→커밋→push→디스패치 4단계가
쪼개져 있다. DB·valkey 캐시 추가도 같은 웹 폼 경로다. 절차가 느리고 실수 여지가 있으며, 무엇보다
추후 aiops 환경에서 에이전트가 이 플랫폼을 조작할 표준화된 도구 표면이 없다 — 웹 폼은 에이전트가
쓸 수 없는 인터페이스다.

## Solution

`homelab` 서브커맨드 CLI를 만든다. 변이는 전부 **기존 변이 디스패처를 `gh workflow run`으로
트리거하는 래퍼**다 — actor 가드·전역 직렬화(homelab-mutation)·계약표 검증·PR-first를 그대로
통과하므로 신뢰 경계가 하나도 바뀌지 않는다. 여기에 앱 레포 스캐폴드(`app init`), 시크릿 원스텝
(`app secrets`), 상태 관찰(`status`), 전제 진단(`doctor`), 그리고 파괴 동사를 제외한 전 동사를
MCP tool로 노출하는 서버 모드(`mcp`)를 더한다. 전 동사가 `--json` 구조화 출력과 레포 종료코드
규약을 지원해 사람과 에이전트가 같은 도구를 쓴다.

## User Stories

1. 홈랩 owner로서, 정적앱(site 아키타입)을 명령 한 줄로 스캐폴드하고 첫 push까지 마치고 싶다. 빌드가 즉시 트리거되어 배포 선행 조건이 준비되도록.
2. 홈랩 owner로서, 서버 앱(fullstack 또는 api 아키타입)을 같은 방식으로 시작하고 싶다. 아키타입만 바꾸면 같은 절차가 되도록.
3. 홈랩 owner로서, 워커 앱(worker 아키타입)을 같은 방식으로 시작하고 싶다. 세 kind 전부가 한 도구로 커버되도록.
4. 홈랩 owner로서, 새 앱 레포가 기본 private으로 생성되기를 원한다. 코드 공개 여부를 내가 명시적으로 결정하도록.
5. 홈랩 owner로서, `app init`에 옵션 플래그를 주면 새 앱 레포에 디스패치 시크릿 쌍이 배선되기를 원한다. 빌드 완료 시 bump-poll 크론 10분 지연 없이 즉시 배포 체인이 돌도록.
6. 홈랩 owner로서, 빌드된 앱을 `app create` 한 줄로 homelab에 등록(create-app 디스패치)하고 싶다. 웹 폼을 열지 않도록.
7. 홈랩 owner로서, 변이 동사가 기본으로 디스패치 run 완료까지 추적하고 PR URL을 보여주기를 원한다. 변이가 받아들여졌는지(검증 통과·PR 생성) 그 자리에서 알도록.
8. 홈랩 owner로서, `--wait`를 주면 auto-merge와 ArgoCD healthy까지 기다려주기를 원한다. "실제 배포됐다"를 한 명령으로 확인하도록.
9. 홈랩 owner로서, DB를 확장 목록과 함께 `db create`로 생성하고 싶다(예: pg_trgm, vector). 웹 폼의 체크박스 대신 플래그로.
10. 홈랩 owner로서, valkey 캐시를 maxmemory와 함께 `cache create`로 생성하고 싶다.
11. 홈랩 owner로서, 앱 레포 안에서 `app secrets` 한 동사로 seal→커밋→push→디스패치가 이어지기를 원한다. 4단계 수동 체인이 사라지도록.
12. 홈랩 owner로서, 앱 레포 밖에서 `app secrets`를 부르면 디스패치만 수행되기를 원한다. 이미 push된 봉인본을 재배선할 때 쓸 수 있도록.
13. 홈랩 owner로서, 앱 철거를 `app teardown`으로 트리거하되 머지는 기존 정책대로 수동으로 남기고 싶다. 파괴 경계의 사람 확인이 유지되도록.
14. 홈랩 owner로서, teardown이 앱 이름 재입력 confirm을 요구하기를 원한다(플래그 또는 TTY 프롬프트). 오타·복붙 실수가 파괴로 이어지지 않도록.
15. 홈랩 owner로서, 비-TTY 환경에서 confirm 플래그 없는 teardown이 거부되기를 원한다. 스크립트가 우발적으로 파괴를 트리거하지 못하도록.
16. 홈랩 owner로서, `status <app>`으로 배포 핀·최근 run·열린 PR·ArgoCD sync/health를 한 화면에서 보고 싶다. 세 표면을 오가지 않도록.
17. 홈랩 owner로서, `status`(앱 미지정)로 전체 앱 목록과 요약 상태를 보고 싶다.
18. 홈랩 owner로서, KUBECONFIG가 없는 환경에서도 status가 레포+GitHub 정보만으로 동작하고 라이브 구간은 생략으로 표시되기를 원한다. 어디서든 부분 정보라도 얻도록.
19. 홈랩 owner로서, `doctor`로 gh 인증 계정이 owner와 일치하는지·필요 도구·템플릿 접근성을 사전 진단하고 싶다. 디스패치가 actor 가드에서 죽고 나서야 아는 일이 없도록.
20. 홈랩 owner로서, run이 실패하면 실패한 잡 이름과 run URL이 출력되기를 원한다. 원인 추적을 바로 시작하도록.
21. 홈랩 owner로서, `homelab --help` 한 번으로 전 동사를 발견하고 싶다.
22. 홈랩 owner로서, db·cache의 로컬 접속 URL 기록(기존 db:url/cache:url)도 같은 진입점에서 쓰고 싶다. 도구가 한 곳에 모이도록.
23. 홈랩 owner로서, 앱 레포 디렉토리 등 homelab 레포 밖에서도 CLI를 실행하고 싶다.
24. 홈랩 owner로서, 종료코드로 실패 원인 계층(검증 실패/사용법 오류/race/skip)을 구분하고 싶다. 셸 스크립트에서 분기하도록.
25. aiops 에이전트로서, 전 동사의 `--json` 출력을 원한다. 파싱 없이 기계 판독하도록.
26. aiops 에이전트로서, MCP tool로 생성·갱신·관찰·진단 동사를 호출하고 싶다. CLI 프로세스 조작 없이 표준 프로토콜로 플랫폼을 다루도록.
27. aiops 에이전트로서, 파괴 동사(teardown)가 MCP에 노출되지 않기를 원한다. 내 오판 한 번이 철거 디스패치가 되지 않도록.
28. aiops 에이전트로서, MCP tool 호출이 길게 블로킹하지 않고 status 재호출로 진행을 확인하는 형태이기를 원한다. 도구 호출 타임아웃에 걸리지 않도록.
29. aiops 에이전트로서, doctor를 첫 호출로 환경 전제를 검증하고 싶다. 이후 호출들의 실패를 전제 문제와 구분하도록.
30. 홈랩 owner로서, 잘못된 플래그·인자가 fail-closed로 거부되고 사용법이 출력되기를 원한다. 기존 도구들과 같은 규율이 유지되도록.
31. 홈랩 owner로서, 지금 템플릿으로 만든 새 앱이 amd64 NUC에서 실제로 기동하기를 원한다(템플릿 arm64 하드코딩 수리). init이 만들어낸 앱이 exec format error로 죽지 않도록.
32. 홈랩 owner로서, CLI가 시크릿 값을 채팅·로그·stdout에 절대 출력하지 않기를 원한다. 기존 시크릿 규율이 CLI에서도 유지되도록.

## Implementation Decisions

- **디스패처 래퍼 원칙**: 모든 변이는 기존 변이 디스패처(create-app·create-database·create-cache·
  update-secrets·teardown-app)를 `gh workflow run`으로 트리거한다. 로컬 직접 변이 경로는 만들지
  않는다("직접 실행 금지" 규약 유지). CLI는 디스패처 입력 계약(앱 이름, DB 확장 불리언 5종 +
  ext_extra, maxmemory 등)으로 플래그를 매핑하는 어댑터다.
- **동사 계층**: `app init|create|secrets|teardown` · `db create|url` · `cache create|url` ·
  `status` · `doctor` · `mcp`. 명령 이름은 `homelab`.
- **run 특정·추적 (correlation 수령증)**: workflow_dispatch는 run id를 돌려주지 않고, 시각 창·
  스냅샷 차분 매칭은 동시 호출의 staggered visibility에서 남의 run을 채택할 수 있다(plan r1 a1·b2,
  r2 s1 — 이 레포 함정 원장의 "GitHub API는 낡은 스냅샷을 200으로 돌려준다"와 같은 계열). 따라서
  관측 차분을 신원 메커니즘으로 쓰지 않는다: **각 변이 디스패처에 옵션 `correlation` 입력**(기본
  빈값 — 웹 UI 수동 실행과 하위호환)을 추가하고 워크플로 `run-name`에 에코해, CLI가 호출마다 생성한
  유일 nonce로 자기 run을 API에서 권위 있게 특정한다(validate-mutation 계약표에 허용 입력 행 추가).
  같은 nonce의 run이 정확히 1개일 때만 채택 — 0개(미출현)는 재조회 후 타임아웃, 그 외 불일치는
  exit 3(race)로 fail-closed. 채택된 run URL이 이후 추적·상관의 핸들이다. 추적은 run conclusion까지가
  기본이고, 실패 시 실패 잡 이름과 run URL을 보고한다.
- **대기 시맨틱 (동사별 매트릭스)**: 기본 = run 완료 + 산출 PR URL 출력. `--wait`의 완료 판정은
  동사별 상태기계로 갈린다(plan r1 a3·b1·b3 — 라이브 검증: create-app reusable은 auto-merge false,
  update-secrets·create-database는 true):
  - **자동 머지 동사**(update-secrets·create-database·create-cache): auto-merge 완료(required check
    `gate` 단일 — ADR 0003)를 확인하고 **머지 SHA를 기록**한 뒤, 그 동사의 **명명된 Application
    집합 전체**가 수렴해야 성공이다(plan r2 s2 — 워크플로 검증 완료): update-secrets = 해당 앱
    Application · create-database = `cnpg-data` + `data-conn-prod` · create-cache = `cache-prod` +
    `data-conn-prod`. 각 Application의 **관측된 sync revision이 머지 SHA이거나 그 후손**이면서
    Synced + Healthy이고, **그 관측 리비전에서 동사별 desired-state 표면이 여전히 요청값**(plan r2
    s6: update-secrets=봉인본 checksum, db/cache=리소스 매니페스트 존재·내용)일 때만 "배포됨"으로
    판정한다. 표면이 이미 다른 값이면 성공이 아니라 **superseded/reverted 별도 variant**로 보고한다.
    health 단독 판정 금지 — 이전 리비전으로 Healthy인 채 OutOfSync일 수 있다(activate-app 게이트와
    같은 원칙). **정당한 no-op 예외**(plan r2 r2-a1): update-secrets는 봉인본이 기존과 동일하면
    PR 없이 끝나는 멱등 no-op run이 정상이다 — 이때 wait는 머지 SHA를 요구하지 않고 **no-op
    variant**를 반환하며, 검증은 현재 synced revision에서 봉인본 checksum 일치 확인으로 대체한다.
  - **create-app**(수동 머지 — 머지가 곧 공개 승인): `--wait`는 승인 경계를 약화하지 않는다. PR URL +
    "사람 머지 대기" 상태의 **바운디드 pending 결과**를 반환하고, 대기 중 사람이 머지한 것이 관측되면
    위 자동 머지 동사와 같은 라이브 추적(해당 앱 Application + 표면 확인)을 이어간다. auto-merge를
    켜는 어떤 경로도 없다.
  - **teardown-app**(수동 머지 — 머지가 곧 파괴 승인): 종결 상태가 다르다(plan r2 s5 — 삭제 대상
    Application은 Healthy가 될 수 없다). 성공 = 머지 관측 + **생성됐던 Application의 부재**(appset
    finalizer cascade prune 완료). DNS 회수는 iac/tf-reconcile 소관임을 결과에 명시한다(관측 대상
    아님).
  - 공통: 타임아웃 시 부분 결과(pending variant)로 종료. KUBECONFIG 부재 시 머지까지만 확인하고
    라이브 구간 생략을 결과에 명시한다(생략과 성공을 구분). 폴링 간격·데드라인은 주입 가능(테스트 심).
- **app init 체인 (멱등·재개 가능)**: 템플릿 레포에서 새 레포 생성(기본 private, `--public` 옵트인)
  → 클론 → 스캐폴더 비대화형 실행(`--archetype fullstack|api|site|worker` — kind는 아키타입 유도값,
  CONTEXT.md 용어) → 커밋 → 첫 push. `--dispatch-secrets` 지정 시에만 App 키 경로를 받아 새 레포에
  디스패치 시크릿 쌍을 설정한다(기본 미배선 = 크론 백스톱). 체인이 불가역 외부 부수효과를 여럿
  건너므로(plan r1 a4·b4) 다음을 계약으로 한다:
  - **preflight**: 생성 전에 레포명 충돌·조직 권한·스캐폴더 계약 호환성을 검사하고, 하나라도 실패면
    아무 부수효과 없이 거부한다.
  - **재개**: 순서는 "존재하는 레포 → 소유 술어 평가 → 미완성이면 재개 / 아니면 거부"다. 소유
    증명은 계보(템플릿 출처)가 아니라 **invocation marker**다(plan r2 r2-a2 — 계보는 다른 템플릿
    레포를 입양할 수 있다): init이 첫 스캐폴드 커밋에 도구 식별자+앱명을 담은 마커를 기록하고,
    재개는 **마커가 확인된 레포에서만** 자동 진행한다. 미완성 판정은 첫 push 이후 실패도 포괄한다
    (plan r2 s3): **스캐폴드 미완 또는 첫 push 부재 또는 — `--dispatch-secrets` 요청 시 — 디스패치
    시크릿 쌍 불완전(gh secret 목록 조회로 판정)**. 마커가 없는 기존 레포는 fail-closed로 거부하며,
    명시적 입양 플래그(사용자 확인)로만 이어갈 수 있다.
    각 단계는 멱등(같은 단계 재실행 = no-op 또는 수렴)이고, 단계별 사후조건(스캐폴드 완료 마커·
    원격 첫 push 존재·시크릿 2건 존재)이 재개 판정의 근거다.
  - **시크릿 쌍 원자성**: 디스패치 시크릿 2개는 한 쌍으로 취급 — 하나만 설정된 채 실패하면 결과에
    절반 상태를 명시하고 재실행이 나머지를 수렴시킨다(절반 상태 = 알려진 무효 구성, 위 재개 술어가
    이 상태를 미완성으로 식별한다).
- **app secrets 이중 모드 (선행 조건 강제)**: 실행 디렉토리가 대상 앱 레포이면 seal(기존 seal 도구
  위임)→커밋→push→update-secrets 디스패치를 연쇄하고, 아니면 디스패치만 한다. 디스패처는 앱 레포
  **main HEAD**의 봉인본을 읽으므로(plan r1 a2), 연쇄 모드는 디스패치 전에 다음을 전부 증명해야
  한다 — 하나라도 실패면 디스패치 없이 거부:
  - remote가 canonical 앱 레포(`ukyi-app/<app>`)와 일치하고, 현재 브랜치가 main이며, 트리가 깨끗하다
    (봉인본 갱신 외 변경 없음). 커밋은 **봉인본 파일만** 스테이징한다.
  - push 후 원격 main에서 그 커밋이 도달 가능함을 확인한 뒤에만 디스패치한다.
  - push 성공·디스패치 실패 경계는 재실행으로 수렴한다(같은 봉인본이면 디스패치만 재시도 — 멱등).
  평문은 kubeseal stdin 전용 — 값은 어떤 출력에도 나타나지 않는다(봉인 계약 규율 유지).
- **teardown confirm 가드**: `--confirm <앱이름>` 플래그가 디스패처의 confirm 입력으로 전달된다.
  플래그 부재 시 TTY면 재입력 프롬프트, 비-TTY면 거부. auto-merge를 켜는 어떤 경로도 두지 않는다
  (머지는 수동 = 기존 파괴 경계 정책).
- **status 계층**: 레포(배포 핀·바인딩·원장) + GitHub(최근 run·열린 PR)가 기본. KUBECONFIG가 있으면
  ArgoCD Application sync/health를 덧붙이고, 없으면 그 구간을 생략으로 표시한다(빈 값과 구분).
- **doctor 점검 항목**: gh 인증 존재·로그인 계정 = owner 변수 일치(actor 가드 사전 검증)·gh 스코프,
  bun·kubeseal 존재, KUBECONFIG 유무(경고 수준), 템플릿 레포 접근성, **템플릿 호환성**(스캐폴더
  비대화형 계약 + TARGETARCH 파라미터화 존재 — 비호환이면 init을 거부할 근거). 각 항목
  pass/fail/warn 구조화.
- **--json 계약 (체크인 스키마 = SSOT)**: 출력 계약은 산문이 아니라 **레포에 체크인되는 버전 있는
  JSON 스키마**가 SSOT다(plan r1 a5·b6). 스키마는 판별 가능한 variant(성공 · 검증/게이트 실패 ·
  skip · race · **pending**(수동 머지 대기·타임아웃 부분 결과) · **no-op**(정당한 무변경) ·
  superseded/reverted · 라이브 구간 생략)를 갖고, 종료코드
  규약(0/1/2/3/4)과 variant의 매핑, stdout 순수성(`--json`이면 stdout은 그 오브젝트 하나뿐, 사람용
  텍스트·진행 표시는 stderr), MCP 에러 매핑을 함께 정의한다. 동사별 결과 필드의 구체 정의는 워킹
  스켈레톤 티켓의 산출물이며, 이후 티켓은 그 스키마에 variant를 추가할 뿐 기존 필드를 깨지 않는다.
  MCP tool 결과도 같은 오브젝트를 재사용한다(계약 한 벌).
- **종료코드**: 기존 도구 규약(0=성공 · 1=검증/게이트 실패 · 2=사용법 오류 · 3=race · 4=skip +
  SKIP 마커) 준수.
- **인자 파싱**: 기존 파싱 커널(fail-closed: unknown 플래그 거부·값 삼킴 거부)을 서브커맨드
  (위치 인자 어휘) 지원으로 신중히 확장한다. 기존 소비자의 의미론은 불변.
- **MCP 서버 모드 (명시 입력·동기 바운디드)**: stdio transport. 노출 = 파괴 제외 전부(app
  init/create/secrets, db create/url, cache create/url, status, doctor). teardown은 CLI 전용.
  stdio 서버는 작업 디렉토리가 하나로 고정되므로(plan r1 b7) 디렉토리 추론에 의존하는 tool은 없다:
  secrets는 앱 레포 경로를, init은 대상 부모 디렉토리를 **명시 입력**으로 받는다. 각 tool 호출은
  동기·바운디드다 — `--wait`류 장기 대기는 MCP에 노출하지 않고, 결과의 run URL·PR URL이 상관
  핸들이다. **status는 핸들 조회 모드를 갖는다**(plan r2 s4): run URL 또는 PR URL을 입력으로 받아
  그 오퍼레이션 단위의 상태를 보고한다(CLI 플래그와 MCP tool 입력이 같은 계약) — 같은 앱의 동시
  오퍼레이션도 각자 핸들로 독립 조회된다. init은 run 핸들이 없는 로컬 체인이므로 타임아웃 시
  **도달한 체크포인트를 결과로 반환**하고, 같은 입력의 재호출이 재개 술어로 이어간다.
- **설치·위치**: CLI 코드는 homelab 레포의 도구 디렉토리에 살고, bun bin 링크로 전역 PATH에
  노출된다(앱 레포 디렉토리에서의 실행이 요구사항). 자격은 저장하지 않는다 — gh 로그인 계정이
  곧 신원이고, actor 가드가 서버 측 강제를 유지한다.
- **출력 언어**: 사람용 출력은 한국어(레포 규약), 기술 고유명사·플래그는 영문.
- **크로스레포 티켓 — 템플릿 arm64 수리 (릴리스 blocking)**: 템플릿 아키타입들의 빌드 대상 하드코딩
  (bun-linux-arm64)을 TARGETARCH 파라미터화로 수리한다(선행 수정된 기존 앱 2곳과 같은 방식). 이
  작업은 템플릿 레포에서 수행되며 homelab 브랜치 게이트 범위 밖이지만, **이 피처의 릴리스 선행
  조건**이다(plan r1 a6·b5): 티켓 그래프에서 init 동사 티켓의 blocking 의존으로 명시하고, 릴리스
  수용 증거에 amd64 스캐폴드→빌드→스모크 결과를 포함한다. 가변 외부 템플릿의 장래 드리프트에는
  doctor의 템플릿 호환성 검사(아래)로 방어한다.

## Testing Decisions

- **좋은 테스트 = 외부 행동만**: CLI가 어떤 외부 명령을 어떤 인자·순서로 불렀는가(argv 원장),
  무엇을 stdout에 냈는가(`--json` 계약), 어떤 종료코드로 끝났는가. 내부 함수·모듈 구조는 단언하지
  않는다.
- **주 심 = CLI 프로세스 경계** (사용자 승인): bats가 `homelab <동사>`를 통째로 실행, PATH stub이
  gh·git·kubeseal·kubectl argv를 NUL 구분 원장에 기록하고 준비된 응답을 반환. 선행 사례:
  ensure-bump-pr bats(PATH stub + argv 원장), run-bump-plan bats(진짜 git 픽스처 + stub seam).
- **보조 심 1 = 시간 주입**: 폴링 간격·데드라인 플래그/env 주입으로 테스트를 밀리초 단위로.
  선행 사례: poll-ghcr `--fixtures`, dns-drift-check `--fixture`.
- **보조 심 2 = 앱 레포 픽스처**: init·secrets의 앱 레포 조작은 임시 실물 git 레포 픽스처에서 검증.
- **MCP**: 같은 프로세스 경계에서 stdio JSON-RPC 왕복(초기화·tool 목록에 teardown 부재·tool 호출
  결과가 --json 계약과 동일함을 단언).
- **테스트 대상 모듈**: 각 동사 전부 + 파싱 커널의 서브커맨드 확장(기존 소비자 비회귀 포함) +
  MCP 왕복 + confirm 가드(TTY/비-TTY 양쪽) + 종료코드 계층.
- **plan 게이트 수용 결정이 요구하는 시나리오** (전부 주 심에서):
  - run 특정: correlation nonce 매칭 정확히 1개만 채택, staggered visibility(남의 run이 먼저
    보이는 창) 픽스처에서 오귀속 없음, 불일치 시 exit 3 fail-closed.
  - 대기 매트릭스: stale-Healthy(이전 리비전 Healthy + OutOfSync) 픽스처에서 성공 오판 없음,
    **Application 집합 부분 수렴**(cnpg-data만 수렴, data-conn-prod 미수렴) 픽스처에서 성공 오판
    없음, **superseded 픽스처**(관측 리비전에서 표면이 이미 다른 값) → superseded variant,
    create-app의 bounded pending variant, **teardown의 Application 부재 종결**, 타임아웃 부분 결과.
  - init: 각 외부 부수효과 직후 실패 주입(레포 생성 후·push 후·시크릿 1개 설정 후) → 재실행 수렴
    (특히 push 후 시크릿 실패 상태가 재개 술어에 잡히는지).
  - secrets: 피처 브랜치·더러운 트리·remote 불일치에서 디스패치 없이 거부, push 성공·디스패치
    실패 후 재실행 수렴.
  - JSON 계약: 스키마의 전 variant를 골든 JSON으로 고정(성공/실패/skip/race/pending/no-op/superseded/생략).
  - no-op: 봉인본 동일 update-secrets 픽스처 → PR 부재에서 행 없이 no-op variant + checksum 검증.
  - init 소유: 마커 없는 동명 레포 픽스처 → fail-closed 거부, 마커 있는 미완성 레포 → 재개.
  - MCP: 동시 호출의 핸들 분리 + 핸들 조회 모드, 서버 재시작 후 재호출 정상.
- **레포 함정 준수**: bats `@test` 이름은 영어(인코딩 함정), 열거형 단언에는 바닥값(vacuous green
  차단), 시크릿 값은 픽스처에서도 실값 금지.
- **크로스레포 티켓 검증**: 템플릿 수리는 템플릿 레포의 template-ci(주간 스캐폴드→빌드→스모크)와
  수동 멀티아치 빌드 확인이 소유 — homelab 심 밖.

## Out of Scope

- bump-poll 수동 트리거 동사, `logs` 동사, rollback 동사, `status --watch` (라운드 1·3에서 제외 결정).
- MCP에 teardown 노출 (파괴는 CLI 전용).
- 로컬 직접 변이 경로 (디스패처 우회 없음).
- teardown-resource·activate-app 래핑 (owner-local 정책·상태머신 그대로 유지).
- 원샷 풀 파이프라인 메가커맨드 (이산 동사 조합으로 충분).
- 공유 차트·reusable 워크플로의 계약 변경. 디스패처도 원칙적으로 불변이나, **옵션 `correlation`
  입력 추가(하위호환 확장 + validate-mutation 행)만 예외**로 이 피처에 포함한다(plan r2 s1 —
  run 신원의 권위 있는 수령증이 필요해서이고, 기존 입력·동작은 변경하지 않는다).
- 앱 레포들의 CI 변경 (템플릿 arm64 수리 제외).

## Further Notes

- **그린필드**: 현재 온보딩된 외부 앱이 0개(`apps.json` 빈 배열)다. 이 CLI가 첫 온보딩부터 쓰이는
  도구가 되므로, 첫 실전 사용 자체가 e2e 검증을 겸한다.
- **템플릿 조사**: 템플릿은 완성 앱이 아니라 스캐폴더(비대화형 플래그 계약 보유, 아키타입 4종,
  스캐폴드 후 즉시 빌드 가능 hello-world)임이 조사로 확인됐다. 조사 전문은 로컬 research 노트
  (`.scratch/homelab-cli/research-app-template.md`, gitignored)에 있다.
- **aiops 확장 지점**: 동사 계층과 `--json` 계약이 MCP tool로 1:1 승격되는 구조라, 추후 에이전트
  운영 환경에서 tool 추가는 동사 추가와 등가가 된다.
- **ADR 0004(rule-of-two)와의 관계**: 이 CLI는 골든패스 표면을 확장하지 않는다 — 기존 디스패처의
  소비자를 하나 추가할 뿐이다.
