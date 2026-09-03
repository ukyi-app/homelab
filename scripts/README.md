# scripts/ — 운영 셸 스크립트 인덱스

부트스트랩·CI 게이트·시크릿 봉인·DR 운영 스크립트 모음. 이 인덱스가 소유하는 것은 **계산할 수 없는
것**이다 — 각 스크립트의 **목적**·**파괴성**·**불변식**·**위험**.

**가드는 어디서 실행되는지를 여기 적지 않는다.** 가드의 실행 경로는
`bun tools/check-guard-authority.ts --json`이 venue에서 **계산한다**(venue 집합의 정의는 그 도구의
헤더가 소유한다 — 여기 사본을 두지 않는다). 손으로 적은 사본은 반드시 드리프트한다. 2026-08-29
실측: 「CI 게이트」 절 26개 항목 중 **12곳이 틀렸다** — 11곳은 비권위 mirror를 권위처럼 적었고,
`sops-guard.sh`는 정반대 방향으로 적혀 있었다(어디에도 없다고 했는데 실제로는 required 스텝이
가진다). 같은 절의 **4곳**은 아예 한 글자도 적지 않았고, 나머지 두 절에도 mirror 주장이 6곳 더
있었다 — 한 파일 안에서 같은 종류의 사실이 맞고·틀리고·비어 있었다.

**가드가 아닌 스크립트는 그 계산의 도메인 밖이다** — `bootstrap.sh`·`dr-drill.sh`·`teardown.sh`처럼
가드 이름 모양(`check-*`/`verify-*`/`*-guard`/`*-check`)이 아닌 것들은 계산원이 없으므로 이 인덱스가
실행 경로의 SSOT다. 그 문장을 지우면 정보 손실이 0이 아니다. 경계는 `scripts/check-doc-index.sh`가
강제하고, 두 집합이 실제로 일치하는지는 게이트가 권위 도구와 대조한다.

절 제목 셋이 부류 라벨이다 — CI 게이트(읽기 전용 순수 검사) · 시크릿/부트스트랩(라이브 클러스터에
쓰거나 봉인본을 산출) · DR/owner 전용(파괴적 — 잘못 쓰면 데이터 유실).

> CNPG 복구·DR 절차 상세는 (gitignored) `docs/runbooks/restore.md`·`docs/runbooks/host-substrate.md` 참고.

## CI 게이트 (읽기 전용 검사)

- **`check-skeleton.sh`** — 필수 디렉토리 스켈레톤 존재 검사. 라이브 무관(순수 파일 존재).
- **`check-bats-accounting.sh`** — 모든 추적 `test_*.bats`가 정확히 한 도메인(gate / chart-test /
  `.ci-exclude`)에 배정됐는지 검사(고아·이중소유 차단). `run-bats.sh --list`를 읽는다. 도메인 회계만으로는 **gate → `.ci-exclude` 이동**이 원리적으로 안 보이므로
  (옮겨도 여전히 "정확히 한 도메인") 레지스트리 계약 세 가지가 더 붙는다: 항목은 빈 줄로 끊긴 직전 주석
  블록의 지배를 받고 그 블록이 `실행처`를 명시 + 그 표기가 지목한 venue가 **실재**(인용된 `make`/`bats`
  토큰 또는 워크플로 파일 경로 — 단어만으로는 통과하지 않는다) + 항목 수 **상한**(스크립트 상수 `EXCL_MAX` — env
  오버라이드는 폐지됐다: 호출부에 보이지 않는 off-switch를 두지 않는다). 여기에 gate 도메인
  바닥값(``--floor gate=<n>`` — 러너 붕괴·대량 삭제)까지 셋이 각각 다른 축이다.
  `--lint-excludes <파일>`은 레지스트리 계약만 보는 픽스처 모드다(그 외 인자는 exit 2 — 맨 인자로 회계를
  끄는 off-switch를 두지 않는다).
- **`check-app-deploy.sh`** — `apps/<name>/deploy/prod/` 배포 계약 가드. 필수 산출물 목록을
  `tools/app-deploy-schema.json`(SSOT)에서 읽어 강제(`source-repo` 누락/공백 = fail-closed) + **봉인 배선
  all-or-none 불변식**(봉인본⇔envFrom `<app>-secrets`⇔kustomization 등재⇔checksum/secrets, 부분 상태 거부)
  + `S → checksum 정합`(#277 재발 방지) + **strict scope**(namespace-wide/cluster-wide 어노테이션 거부, patch는
  통과) + **파일명 규약**(`<app>-secrets.sealed.yaml` 하나만 허용). 인자 없는 기본 모드에서 앱 열거 0건은 **scan-floor로 실패**(vacuous pass 아님).
- **`run-bats.sh`** — **단일 테스트 수집·실행기(required GATE)**. `make ci`·`ci.yaml`(gate)이 공통 호출(이중 SSOT 제거).
  스코프 = git-tracked `test_*.bats` − `platform/charts/*`(chart-test 별도) − `tests/.ci-exclude`. `--list`는 수집 목록만.
- **`verify-secrets.sh`** — 추적 `*.enc.yaml` 무결성(암호화됨 + age recipient 신원이 canonical(.sops.yaml
  cluster+recovery)과 일치 + 복호 가능) 검사. 값 비출력; age 키 없으면(=CI) 복호 단계만 스킵하고 구조 검사는 수행.
- **`verify-traps.sh`** — `docs/traps.md` enforcement 원장이 가리키는 guard 파일이 실재하는지 검사
  (가드 소실 드리프트 = 거짓 안심 차단). 순수 파일 존재 검사.
- **`ledger-to-json.ts`** — `docs/memory-ledger.md` 표를 JSON으로 변환(conftest 입력 생성). **`bun run verify:ledger`**·
  `make verify`·`ci.yaml`(gate)이 호출(출력을 `conftest test … policy/ledger.rego`로 파이프). 라이브 무관.
- **`sops-guard.sh`** — `*.enc.yaml`이 실제 sops 암호화됐는지 구조 검사(평문 누출 차단). 3조항:
  `.sops.mac`·`.sops.lastmodified` 실재 · `data`/`stringData` 평문 리프 0건(`ENC[` prefix) · age recipient
  신원이 canonical(`.sops.yaml` cluster+recovery)과 정확 일치. **인자 선택** — 주면 그 파일만 보고(대상
  목록이 staged 파일 등으로 좁혀지는 모드 — 그 목록은 호출측이 소유한다), 없으면 추적 `*.enc.yaml`
  전량을 스스로 열거하고 **파일 수 바닥값**을 건다(무인자=아무것도 평가 안 하고 exit 0이던 옛
  vacuous pass를 닫았다). 바닥값 오버라이드는 `--floor sops-guard=<n>` 하나뿐이다.
- **`sealed-guard.sh`** — `*.sealed.yaml`이 실제로 **봉인**됐는지 구조 검사(sops-guard.sh가 `*.enc.yaml`에
  대해 하는 일의 봉인본 판). 4조항: `kind: SealedSecret` · `spec.encryptedData`가 비어 있지 않은 맵 ·
  평문 리프 0건(`.data`·`.stringData`·`.spec.template.data`·`.spec.template.stringData`) · encryptedData
  값이 kubeseal 암호문 표기(`^Ag…`). 복호 키 불필요(yq만). 인자 없으면 추적 봉인본 전량을 스스로 열거하고
  **파일 수·키 총수 두 바닥값**을 건다 — 키 축은 "파일은 다 있는데 내용이 통째로 비었다"를 잡는다(파일 수
  축이 원리적으로 못 보는 붕괴). gitleaks의 봉인본 면제(generic-api-key)가 원리적으로 못 보는 클래스 —
  룰이 아니라 구조의 문제라 여기서 문다.
- **`check-doc-index.sh`** — 두 레인. ① **등재**: `scripts/`·`tools/`·`.github/workflows/` 산출물이 해당
  README에 있는지(가드 없는 인덱스 드리프트 소멸). ② **스코프**: 이 파일의 **가드 bullet**이 계산 가능한
  실행 경로를 주장하지 않는지 — 판정 단위는 `- **` bullet 전건 + bullet 밖 산문이고(절 스코프는 절
  이름을 바꾸면 통째로 우회된다), 가드가 아닌 bullet은 계산원이 없어 스코프 밖이자 **검출기의 상시
  양성 대조**다. 순수 문자열 검사.
- **`check-app-netpol.sh`** — `apps/<app>/deploy/**`의 app-owned NetworkPolicy가 app-scoped 셀렉터
  (`app.homelab/instance=<app>`)를 갖는지 강제(빈/광범위 podSelector = blast-radius). 그 키는 리터럴이
  아니라 차트 SSOT(`platform/charts/app/templates/_helpers.tpl`의 `app.selectorLabels` 중 값이
  `{{ .Release.Name }}`인 줄)에서 **파생**한다 — 손 사본은 갈라진다(실측: 표준 `app.kubernetes.io/instance`를
  강제하던 판은 차트가 내지 않는 키를 요구해, 그대로 따라 쓴 netpol이 아무 파드도 선택하지 못했다).
  파생 실패는 fail-closed. netpol 0건은 통과지만 **매니페스트 열거 0건은 scan-floor로 실패**(vacuous pass 아님).
- **`check-pg-servername.sh`** — CNPG **아카이브 serverName** 분리 가드. `serverName` 한 줄이 `s3://<bucket>/<serverName>/`를 통째로 정하고, 두 primary가 같은 값을 쓰면 타임라인이 섞여 오프사이트 PITR 경로가 망가진다(R2 버저닝 없음 = 되돌릴 수 없음). (A) 쓰기 ≠ 읽기 정합은 항상, (B) `EXPECT_PG_SERVERNAME` 고정은 **main 진입 시에만**(`check-argocd-revision.sh`와 같은 이유로 분리).
- **`check-argocd-revision.sh`** — ArgoCD **자기레포** 리비전 핀 정합. `repoURL`을 가진 맵 노드를 **재귀로**
  뽑아(Application 단일/다중 소스 · ApplicationSet template 소스 · git generator `revision` — 모양을 세지 않는다)
  자기레포 참조 전건이 **같은 값**인지 강제한다(A). `EXPECT_REVISION`(또는 `--expect`)이 주어지면 그 값과의
  일치까지 본다(B) — 그 변수는 **main 진입 시에만** 채워진다. (B)를 기본으로 켜면 마이그레이션 브랜치의
  gate가 영구 red가 되고, 무인자 rc=0을 요구하는 형제 게이트까지 같이 죽는다. 자기레포 판정은 앵커
  (`platform/argocd/root/root-app.yaml`의 repoURL) **정규화 후 비교** — 리터럴 대조는 `.git` 접미사 하나로 눈이 먼다.
- **`check-bats-style.sh`** — bats **코드 표면**(`@test` 본문 + 0열 함수 본문) 단언-스타일 가드.
  네 클래스: 중간(마지막 아님) 부정(`! `)·조건(`[[ `) — bats가 침묵 통과시키는 false-green 단언 ·
  부재 단언 `[ABS]`(`run grep <경로>` + `-ne 0`은 무매치 rc 1과 대상 부재 rc 2를 구별하지 못한다;
  재귀·디렉토리·루프 자리는 비공허 바닥값 + 양성 대조를 **형태로** 요구) · `[QV]`(`grep -qv`의 줄 단위
  반전은 부재가 아니라 항진이다). NEG·QV=hard-zero · BB·ABS=ratchet.
  기본 모드에서 스캔 대상이 0건이면 통과가 아니라 **열거 붕괴**(scan-floor, exit 1) — 같은 도메인을 쓰는
  check-skeleton·check-bats-accounting과 같은 채널이다(skip 규약 아님).
- **`check-locale-collation.sh`** — 로케일 콜레이션 가드: 게이트의 `sort`가 `LC_ALL=C` 접두(또는 숫자
  정렬)인지, TS/JS가 `localeCompare`·`toLocale*`·`Intl.Collator`를 쓰지 않는지 hard-zero로 강제한다.
  en_US 계열은 `-1`과 `1`을 같다고 봐 `sort -u`가 하나를 버린다 — 거짓 red가 아니라 **fail-open**이었다.
- **`check-gh-secret-coverage.sh`** — GH Actions **secret·variable 두 평면 ↔ 분류 정책 전단사** 가드.
  SSOT는 `policy/gh-secret-var-classification.json`이고, 두 평면은 그 안의 **별도 배열**(`secrets`·`vars`)로
  산다 — 섞으면 `ledger` 갈래와 뒤엉켜 만료 원장 대조가 무의미해진다.
  ① **secret**: 워크플로가 참조하는 secret 전부가 정확히 한 번, 사유와 함께 분류돼 있어야 한다
  (ledger/inventory-only/identifier/provided). `ledger` 갈래는 `policy/credential-expiry.json` 행과 기계
  대조된다. ② **variable**(`vars.X`): 공개 설정값이라 유출·회전 축이 없어 `ledger` 갈래 자체를 허용하지
  않는다. 그래도 tracked 원장이 필요한 이유는 감시 공백이다 — `vars.HOMELAB_OWNER`는 owner 경계의 신뢰
  앵커인데 `github_actions_variable` 리소스가 0건이라 terraform 드리프트 감시 범위 밖이다.
  두 평면 모두 양방향(미분류·stale)이고, 이중선언·열거 붕괴까지 전부 fail-closed.
- **`check-host-ports.sh`** — 호스트 포트 위생 가드: `tests/gates/**`의 하네스가 호스트 포트를
  **리터럴로 박거나** 기동 프리미티브를 우회하는 자리를 hard-zero로 막는다(publish 인자 · 리스너 헬퍼
  인자 · 배정 lib 미사용 · 포트 변수를 자기가 리터럴로 채움 · publish 컨테이너를 기동 프리미티브 없이
  띄움 — `HP_` 이름공간만 면제, 밴드 상수의 정의처라서다).
  이 클래스의 결함은 red가 아니라 **오진**으로 나타난다: 예전 AM 렌더 e2e는 mock을 `8089`에 `&`로
  띄워 바인드 실패가 `set -e`에 안 걸렸고, 30초 뒤 "no telegram capture within timeout"으로 죽어
  진단이 포트가 아니라 메시지 템플릿을 가리켰다. 배정·기동 프리미티브는 `tests/gates/lib/host-port.sh`.
- **`verify-credential-inventory.sh`** — 런북 `token-inventory.md` §A 표 ↔ `policy/credential-expiry.json`
  **양방향** 정합 + "N건 등재" 수치 대조. 런북이 gitignored라 **로컬 전용**이고 부재는 SKIP(exit 4).
  병(2026-08-21 실측): 원장에는 `github-tf-ci-pat`·`r2-terraform-state`가 들어갔는데 §A 표는 3건인
  채였다 — `check-credential-expiry.sh`는 원장 **안**만 보므로 이 방향에 원리적으로 침묵한다.
- **`check-bats-fd0.sh`** — bats 호출면의 `</dev/null` 규약 hard-zero 가드. bats는 stdin을 만지지 않고
  @test에 그대로 물려주므로, 스텁이 피연산자 없이 fd 0을 읽으면 호출자 stdin에서 **영구 블록**한다
  (red가 아니라 hang — 이전 세션이 1시간 39분을 태운 형태, PR #520). ⚠️ 같은 러너라도 호출면에 따라
  갈린다: `&`로 띄운 호출면은 fd 0이 `/dev/null`이라 **우연히 면역**이다 — 그 우연 때문에 어떤 venue는
  영영 이 병을 못 재현하고, 규약을 정적으로 강제해야 하는 이유가 정확히 그것이다.
- **`check-sigpipe-writers.sh`** — `set -o pipefail` 셸에서 **다중행 writer를 `grep -q`에 파이프하는 것**을
  금지한다. `grep -q`는 첫 매치에서 즉시 종료하는데 그때 writer가 쓸 것이 남아 있으면 SIGPIPE로 죽고,
  pipefail이 그 141을 파이프라인 rc로 채택한다 — **매치가 있었는데 FAIL**이 된다. 판정이 뒤집히는 게
  아니라 판정 자체가 종료코드에 삼켜진다. ⚠️ **부하 의존이라 로컬이 CI를 예고하지 못한다**: writer가
  몇 번 write()를 끝냈는지가 스케줄링에 달려 있어, `verify-traps.sh`가 부하 아래 30회 중 22회 red였는데
  무부하 20회는 전건 green이었다(PR #565 실측).
  처방은 herestring(`grep -q P <<<"$v"`)이고, 재시도는 처방이 아니다 — SIGPIPE가 만든 거짓 FAIL과 진짜
  드리프트 FAIL이 **같은 문장을 내므로** 판별 장치가 아니라 은폐다. 판정 범위는 의도적으로 좁다:
  pipefail을 켠 파일만, 다중행 writer(`printf '%s\n' "$v"`·`echo "$v"`)만, 주석 줄은 제외
  (여기 본문과 traps-detail이 그 관용구를 **설명**하기 때문이다 — 설명한 파일이 규약에서 면제되는
  반대 방향을 밟지 않으려는 것이다).
  면제는 파일 목록이 아니라 그 파일이 `exec 0</dev/null`을 하는지로 판정한다.
  바닥값의 대상은 파일 수가 아니라 **호출면 수**다(파일 수로 걸면 정규식이 깨져도 통과한다).
- **`check-skip-signalling.sh`** — 가드 skip 신호 규약(CONTRIBUTING '가드 skip 신호')의 정적 가드:
  `SKIP: <가드>: <이유>` 마커와 skip 종료코드(셸 `exit 4` / TS `process.exit(4)`)가 **같은 줄에서 짝**을
  이루는지 검사한다. 짝이 깨지면 "미평가"가 다시 성공으로 위장한다. 추적 `.sh`/`.ts`/`.mts` + Makefile
  전수(자기 자신 제외 — 패턴 리터럴이 위반과 같은 모양). 열거 붕괴 차단용 바닥값 보유(오버라이드는 `--floor check-skip-signalling=<n>`).
- **`check-scan-producers.sh`** — 가드 스캔 신호 규약(CONTRIBUTING '가드 스캔 신호')의 **거부 가드**:
  추적 `tools/**/*.ts`·`*.mts`의 코드 줄이 커널(`tools/lib/scan-floor.ts`)을 우회해 `SCAN:` 마커를 직접
  출력하면 red. 로스터 등식은 되돌린 가드가 정적·런타임 양쪽에서 함께 사라져
  못 잡으므로(게이트 r1 F1) 인식이 아니라 거부가 문을 닫는다. 판정 선은 "출력 동사의 인자가 마커
  리터럴로 시작"(여러 줄 호출 포함) — 마커를 다루는 소비자·진단문은 선 밖이라 제외 목록이 없다.
  주석(`//`·블록 주석 상태 기계·꼬리 주석)을 걷어낸 뒤 판정하고, 면제는 커널 경로 하나 — 그 파일도
  건너뛰지 않고 생산자 히트 ≥1을 검출기 생존 증거로 요구한다. awk 3겹 처방(rc 포착·`[ -r ]`·READFILES)
  + 바닥값·마커는 검출 뒤. 바닥값은 상수(`MIN_FILES`, env 주입 없음) · `--root <dir>`는 픽스처 전용.
- **`check-floor-vocab.sh`** — 바닥값 어휘 거부 가드(kernel-followups 04): 구 어휘의 재유입 —
  `--min-*` 플래그 표면 · `${…MIN…:-…}` env 폴백 읽기(셸) · `process.env.…MIN…`(TS) — 을 정적
  red로 만든다. 상수 정의·지역 읽기·주석 산문·`*.bats`(거부 증인 픽스처)는 정당 보유처로 선 밖.
  패턴은 조립식(self-exclusion 없음), 검출은 detect_run(rc·READFILES 대조), 오버라이드는
  `--floor check-floor-vocab=<n>` 하나(dogfood).
- **`check-credential-expiry.sh`** — 자격증명 만료 원장(`policy/credential-expiry.json`) 검사. `--days N`
  (D-N 이내 만료 시 exit 1·목록 출력), `--lint`(스키마만). 주간 telegram 경고의 임계는 **D-14**.
  jq 전용·값(토큰) 미보유(만료일 원장만). (메타갭 ④)
- **`check-image-pins.sh`** — 이미지 digest 핀 2-레인 게이트: 레인1(platform 문자열 `image:`)·레인2(apps values
  `image:` 구조체 `digest:`). 벤더(barman-plugin)·테스트/픽스처(`**/tests/**`·`**/fixtures*/**`) 제외, substrate 스코프 밖,
  scan-floor. 예외=`policy/image-pin-allowlist.txt`(사유 주석 **+ 건수 상한 `EXEMPT_MAX`** — 픽스처는
  `--exempt-max`로만 넘긴다). 신규 미핀 이미지는 fail-closed 차단. (메타갭 ②)
- **`verify-ledger.sh`** — 메모리 원장 예산 게이트 SSOT. `bun tools/ledger-to-json.ts` 출력을
  `conftest … policy/ledger.rego`로 검사.
- **`verify-runbook-index.sh`** — `docs/runbooks/`(gitignored) ↔ AGENTS.md 런북 인덱스 정합(로컬 전용).
  런북 부재 시 **SKIP 신호**(exit 4 + `SKIP:` 마커 — CONTRIBUTING '가드 skip 신호'; exit 0은 "실제로
  대조했고 정합"만 뜻한다).
- **`audit-orphan-pv.sh`** — 고아 스토리지 감사: ① Released PV(storageclass Retain이라 PVC 삭제 시 PV 누수)
  + ② Bound인데 어떤 파드도 마운트하지 않는 PVC(cascade=orphan 잔재 — phase만으로는 못 잡는다). 나열만
  (비파괴), reclaim은 owner 수동. **`make audit-orphan-pv`**(라이브 ops)가 호출. `tests/gates/test_audit-orphan-pv.bats`가
  가드. ★fail-closed(도구/쿼리 실패=비-0).

## 시크릿 / 부트스트랩 (라이브 쓰기·봉인본 산출)

- **`bootstrap.sh`** — 멱등 DR 진입점: argocd NS + sops-age Secret + ArgoCD + root app 설치.
  **`make bootstrap`**이 호출(+ `bootstrap-deadmanswitch` 선행). 라이브 클러스터에 적용.
- **`seed-secrets.sh`** — terraform output + `.env.secrets`에서 SOPS 암호화 시드 시크릿 생성.
  **`make seed-secrets`**가 호출(`.env.secrets`를 source한 뒤). R2/telegram 등 키를 env로 요구.
  전제: `infra/cloudflare`·`infra/tailscale` apply 완료(state에 output 실재) — 부재/null은
  `jq -re`가 FATAL로 끊는다(예전엔 문자열 `null`이 그대로 봉인·커밋됐다).
- **`tools/seal-batch.ts`** (셸 아님 — 참고) — seal-* 4종(adguard-auth·argocd-notify·files·ghcr-pull)을
  선언 테이블로 통합. `make seal-<name>`(별칭)·`make seal-all`(회전 드릴)이 호출. 봉인 전 `secret-cert-check`
  preflight fail-closed(break-glass `--offline-ok`). 평문·해시·토큰은 kubeseal stdin 전용(값 미출력).
- **`secret-cert-check.sh`** — 봉인 전 preflight: 커밋된 `tools/sealed-secrets-cert.pem`이 라이브
  컨트롤러 cert와 fingerprint 일치하는지(stale 차단) 검사. read-only(fetch만); 오프라인/kubeseal 부재면 **SKIP 신호**(exit 4 + 마커 — 예전 2는 unknown-option과
  같은 코드였다). 호출자(`seal-batch.ts`)는 4=미평가와 1=stale을 구별해 보고한다. `sealing-key-dr-gate.sh` 로직 재사용.

## DR / owner 전용 — 파괴적

- **`reset-pg-r2-archive.sh`** — **파괴적**. fresh initdb `pg`가 R2의 옛 barman 아카이브와 충돌할 때
  serverName `pg` 아카이브(base/+wals/)만 정리해 아카이빙 재개. **`make reset-pg-archive`**가 호출하되
  **기본 dry-run** — 실제 삭제는 `ARGS=--purge`. 라이브 ObjectStore에서 bucket/endpoint를 읽음.
- **`destroy-node.sh`** — **극도로 파괴적(owner 전용, D-j)**. 베어메탈 노드 파괴 프리미티브:
  `k3s-uninstall.sh` + `/var/lib/rancher` 삭제(= standard 클래스 PV 전량 소멸, 복구 불가).
  OrbStack 시절 `orb delete -f k3s` 한 줄을 대체한다. `dr-drill.sh`의 [1]이 유일한 자동 호출자이고
  그 밖에는 사람이 직접 실행한다 — Makefile/워크플로 **배선 없음**(`make down`은 의도적 비배선).
  3중 fail-closed: 확인 env `DR_DRILL_DESTROY_CONFIRM=1` · 국면 A(`BULK_MIGRATION_WINDOW_UNTIL`이
  비어있지 않으면) 거부 · `k3s-uninstall.sh` 부재 fail-loud. **`|| true` 없음** — 파괴 실패를 삼키면
  드릴이 거짓 PASS를 찍는다. 시임 `K3S_RUN`(기본 sudo)·`K3S_UNINSTALL`. 가드 `tests/test_destroy-node.bats`.
- **`dr-drill.sh`** — **극도로 파괴적(owner 전용)**. 노드를 DESTROY→RECREATE(`destroy-node.sh`에 위임)하고
  git+R2+age 키만으로 전 플랫폼 재구축 + R2 DB 복구(canary 일치)를 증명하는 풀 DR 드릴(R5). Makefile/워크플로
  **배선 없음** — 직접 실행. 파괴 전 canary 캡처 + 복구 증명 후에만 노드 파괴. `sealing-key-dr-gate.sh`를 source.
- **`sealing-key-dr-gate.sh`** — sealing-key DR 게이트 **라이브러리(source 전용 — top-level 실행 없음)**.
  `dr-drill.sh`가 source한다. SealedSecret 소비자/커밋 cert가 있으면 파괴 전 백업·실복원 증명 + 재구축 후
  전수 unseal + cert 일치를 강제(권위 소스 조회 실패 = fail-closed). `make`/워크플로 직접 호출 아님.
- **`backup-sealed-secrets-key.sh`** — **owner 전용(DR 불변식)**. SealedSecrets 컨트롤러 sealing key를
  out-of-band 백업. `scripts/backup-sealed-secrets-key.sh <outdir>`(백업 생성, outdir는 git 밖) /
  `--verify <outdir>`(최신 백업이 라이브 키 셋을 담는지 — 회전 게이트). `sealing-key-dr-gate.sh`가 `--verify`로 호출.
  평문 private key를 디스크에 비기록(kubectl→sops 직행), git 작업트리 안 보관 거부.
- **`backup-files-data.sh`** — **owner 전용(내구성 불변식, 비파괴)**. files-data(비재생성 사용자 데이터)를
  bulk 티어 → 별도 매체로 rsync 오프-SSD 백업. `<dest>`(백업)/`--dry-run <dest>`/`--verify <dest>`
  (백업서 전 파일 복원+sha256 대조 — 매체 판독성 게이트). dest는 source와 **다른 물리 디스크**여야 한다
  (판별은 `findmnt --target` → 백킹 디바이스 → `lsblk -nso` TYPE=disk까지 거슬러 올라간다).
  스테이징→sanity(빈/급감 중단)→승격(data.prev 1개 보존). 성공 시 `files_backup_last_success_timestamp`·
  용량을 vmsingle에 push(r4의 FilesBackupStale/FilesBulkSSDLow).
  ⚠️ 2026-08-19에 **리눅스로 재작성**됐다(이전 판은 macOS 결박 — `diskutil` 매체 판별 + launchd 배선).
  실행자는 `infra/k3s-bootstrap/host-config/etc/systemd/system/files-data-backup.{service,timer}`이고
  🔴 **국면 A 동안 enable하지 않는다** — `/mnt/bulk`가 루트 LV의 bind 마운트라 2차 매체가 원리적으로
  없고, 스크립트가 같은 물리 디스크를 dest로 주면 거부한다. 국면 B(2TB M.2 장착) 이후
  `sudo systemctl enable --now files-data-backup.timer`가 배선의 마지막이다.
  실패는 `OnFailure=`가 `notify-unit-failure.sh`로 즉시 알린다(신선도 알림은 1주기보다 빨리 못 운다).
  Makefile 배선 없음 — 직접 실행.
- **`notify-unit-failure.sh`** — **호스트 systemd 전용**(직접 실행하지 않는다).
  `OnFailure=unit-failure-notify@%n.service`가 호출해 `systemd_unit_last_failure_timestamp{unit=…}`를
  node-exporter textfile collector 디렉토리에 원자적으로 쓴다(r4 `SystemdUnitFailed`가 읽는다).
  oneshot 실패의 **유일한 즉시 채널** — 신선도 알림은 원리적으로 주기보다 빨리 울 수 없다.
  push가 아니라 파일인 이유: kubectl/port-forward 의존이 없어 **자기 트리거와 함께 죽지 않는다**.
- **`sweep-systemd-failures.sh`** — **호스트 systemd 전용**(직접 실행하지 않는다).
  `systemd-failed-sweep.timer`(5분)가 호출해 `systemctl list-units`를 **한 번** 읽고
  `systemd_sweep_unit_failed{unit,type}`·`systemd_sweep_units_failed`·`systemd_sweep_last_success_timestamp`를
  textfile collector에 원자적으로 쓴다(r4 `SystemdHostUnitFailed`·`SystemdSweepStale`이 읽는다).
  위 즉시 채널과 **직교**다: 저쪽은 `OnFailure=`가 달린 유닛만 지연 0·critical로, 이쪽은 전역을
  주기적으로 warning으로 본다. 라이브 실측 로드 `.service` 64건 중 `OnFailure=` 보유는 3건뿐이다.
  ⚠️ **`Restart=always` 유닛(k3s 등)은 원리적 사각지대다** — 시작 rate limit에 도달하지 못해
  `failed`에 진입하지 않는다. 🔴 열거가 붕괴하면(3중 바닥값) **파일을 쓰지 않고 죽는다** —
  "failed 0건"과 "스윕 미실행"을 구별하는 것이 이 스크립트의 계약이고, 그 구별은 하트비트가 진다.
  배선: `host-config.sh --apply` 후 `sudo systemctl enable --now systemd-failed-sweep.timer`
  (잊으면 `SystemdSweepStale`이 운다).
- **`teardown.sh`** — **파괴적(owner 전용)**. `make teardown-app`/`teardown-resource` 래퍼가 호출 —
  clean-worktree 가드 → origin/main fetch → `teardown/<target>-<ts>` fresh-main 전용브랜치 → 툴(plan) →
  allowlist staging → PR(owner gh 자격). 앱/리소스 매니페스트·apps.json·원장 행 제거(리소스 purge는
  상태머신·런북 전용). fresh-main 기반이라 무관 커밋 미포함(C-F1). 잘못 쓰면 배포/데이터 유실.
- **`netpol-rehearsal.sh`** — **owner-local**. NetworkPolicy candidate를 selfHeal off→apply→verify-posture→
  trap 복원으로 리허설(라벨 미스가 prod로 안 새게). GitOps selfHeal라 머지 전 필수(pre-merge posture는
  main=broad을 테스트, candidate 아님). Makefile/워크플로 배선 없음 — 직접 실행.
  ⚠️ posture 스위트 **전체가 아니라 netpol 레그만** 돈다(`POSTURE_BATS` 오버라이드, `git ls-files` 파생 +
  열거 붕괴 바닥값) — `tests/posture/test_dr-assets.bats`는 owner 매체 env를 요구하는 별개 도메인이라
  리허설 범위 밖이다(무가드로 부르면 candidate와 무관한 red가 **클러스터 변이 뒤에** 나온다).
  ⚠️ 인-레포 앱 0인 현 정상 상태(`apps/README.md`)에서는 **kubelet 프로브 레그만** skip된다(경고 출력) —
  리허설 자체는 돈다. POSITIVE pg-rw·pg-pooler-rw(F4b)·NEGATIVE egress deny는 `probe()`가 자기 파드를
  띄우므로 앱 파드와 무관하게 실질 판정이고, ipBlock 핀은 `platform/network-policies/prod/test_netpol.bats`가
  gate에서 따로 강제한다. prod에 파드는 있는데 셀렉터가 0건이면(라벨 드리프트) 그건 열거 붕괴라 exit 1이다.
- **`auto-merge-or-fail.sh`** — 워크플로 헬퍼(비파괴). `bump.yaml`·변이 경로가 PR 생성 후 auto-merge
  설정, PR이 CLEAN일 때만 폴백하고 BLOCKED/BEHIND/UNKNOWN이면 시끄럽게 실패(un-gated 직접 머지 차단). `make`/직접 실행 아님.
- **`backup-local-asset.sh`** — **owner 전용(DR 불변식, 비파괴)**. 런북(`docs/runbooks/`, gitignored 단일
  사본)을 tarball→age(sops binary) 암호화해 git 밖 매체에 버전드 백업. `<outdir>`(생성)/`--verify <outdir>`
  (최신 백업이 현재 런북과 파일명+내용 sha256 일치하는지 신선도 게이트). **`make backup-local-asset OUT=<git 밖>`**
  (`ARGS=--verify`)가 호출. sealing key 백업과 대칭. `verify-runbook-index`가 양방향 fail-closed로 인덱스 드리프트 차단.
