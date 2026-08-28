# 처방 도달 (prescription-reach) — 설계

2026-08-28 아키텍처 리뷰 패스. 스캔 → 후보 8건(+짧은 목록 4 + 결함 1) → 설계 조사 14건 →
적대 검증 14건 → 이 문서. 티켓 14개로 착지한다.

## 1. 캠페인 축

이 패스가 찾은 후보 전건이 **같은 클래스**다. 그 클래스에 이름을 붙이는 것이 이 캠페인의 첫 산출물이다.

> **처방 도달 (prescription reach)**: 한 자리에서 실증된 처방이 같은 클래스의 인접 표면에 닿았는지를
> 가리키는 성질. 진단은 "중복이 있다"가 아니라 **"형제 자리에 이미 있는 처방이 여기엔 없다"**이며,
> 그래서 근거는 처방의 실증 이력과 형제의 실재이지 유사성이 아니다. 도달 실패는 조용하다 — 처방을
> 받은 자리가 초록이므로 회계가 정상값을 낸다.
> _Avoid_: 중복 제거, DRY(중복이 문제가 아니라 처방이 닿지 않은 것이 문제다), 리팩터링

**도달 실패 진단 3조건 (셋이 다 서야 후보다):**
1. 처방이 어딘가에서 **실증**됐다 (라이브 사고·재현·명시 결정 중 하나로).
2. 형제 표면이 **같은 실패에 노출**돼 있다.
3. 그 비대칭에 **근거가 적혀 있지 않다**.

이 3조건이 없으면 다음 리뷰가 이 용어를 "비슷한 코드를 합치자"로 오독한다. ADR 0003·0004·0005가
기각한 축은 전부 **중복은 실재하나 처방이 실증되지 않은** 자리였다 — 조건 ①이 서지 않았다.

이 어휘는 이미 두 번 실증됐다: `tests/gates/lib/host-port.sh:8`과 `tests/gates/lib/heredoc-marker.sh:9`가
같은 명제를 **각자 산문으로 다시 논증한다**. CONTEXT.md 승격 문턱("공통형이 실증될 때")을 넘었다.

## 2. 이긴 설계와 진 설계

**진 것 — 통합 메타 가드.** "처방이 인접 표면에 닿았는가"를 정적으로 판정하는 가드 하나를 세우고
14건을 그 첫 소비자로 삼는 안. 기각한다: 처방을 열거하고, 인접 표면을 열거하고, 열거 밖을 안전으로
읽는 구조다 — ADR-0002가 **다섯 번** 무너진 그 클래스의 다섯 번째 얼굴이다. "어떤 표면이 이 처방을
받아야 하는가"는 원리적으로 열거할 수 없다. → **ADR-0007로 기록**(§6).

**이긴 것 — 14개 독립 처방.** 클래스는 같지만 처방은 각각 다르다. 적대 검증이 14건 중 10건의 설계를
반려했고, 반려의 방향이 하나로 수렴했다: **새 module을 만들지 말고 이미 실증된 형제 처방을 가져와라.**
수용 후 신설 module은 **E 하나**(`hp_run_published`)만 남는다 — adapter가 둘이고 소비자 집합이
포함 관계(`consumers(publish) ⊂ consumers(port)`)라는 것이 실측으로 확인된 유일한 자리다.

**적대 검증이 죽인 신설 module 4개** (전부 deletion test 실패):
- `tests/lib/absent.sh` (A1) — 처방은 새 lib이 아니라 `-eq 1`과 setup 한 줄이다.
- `scripts/assert-staged-complete.sh` (B) — 본체가 4줄이고 세 콜사이트 중 하나는 소비 불가.
- `sealedFileFor`/`secretNameFor` export (C) — 생산 자리 9곳 중 4곳만 닿는다.
- `scanFields` 커널 함수 (K) — 방출을 안 가져가면 규율상 콜사이트 리터럴과 동치.

## 3. 티켓

### PR-0 — bats 부재 단언 (뿌리)

블로킹의 뿌리다. `run grep <실 트리 경로>` + `[ "$status" -ne 0 ]`은 경로 부재(grep rc=2)에 통과한다.

**재현** (`git archive HEAD` 픽스처, 레포 무수정): `infra/github/variables.tf` → `vars.tf` 리네임 +
`bot_pat` 변수·시크릿 재도입 → `test_auth.bats` 4·5번 단언 `ok`. 상시 write-capable PAT 부활이
무증인 초록. 빈 트리에서 `test_auth.bats` 7건 중 5건 통과.

**이미 실증된 처방 셋**: `scripts/lib/guard.sh:50-96`의 `detect_run`(셸 레인) ·
`tests/gates/test_scan-floor.bats:455-464`(한 @test의 사유물) ·
`tests/gates/test_app-token-sha-ssot.bats:28,35`(`-eq 1`, 주석이 함정을 명명).
함정 자체는 **이미 원장에 있다** — `docs/traps-detail.md:605` ③("부정 카운트는 '매치 0'과 '대상 0'을
구별하지 못한다"). 처방이 scan-floor 기계에만 닿았고 bats 콜사이트엔 안 닿았다.

#### 01 · `-ne 0` → `-eq 1` 전건 전환 + setup 비공허 단언

- **스코프: 184곳 전건.** A 분류 32곳이 아니다 — A/B 분류는 **진단**이지 **전환 스코프**가 아니다.
  완전성 가드가 그 선을 원리적으로 못 본다. `platform/`·`infra/` 레인 67곳 포함, ~60파일.
- **디렉토리 피연산자 5곳 + 루프 1곳은 `-eq 1`로 안 닫힌다.** 실측: `grep -r PAT <빈 디렉토리>` =
  **rc 1**이고, `for d in $DISPATCHERS`(`tools/tests/test_mutation-dispatch.bats:52`)는 목록이 비면
  반복 0회라 어떤 rc로도 안 보인다. → `setup()`에 비공허 단언(`test_app-token-sha-ssot.bats:8` 형태)과
  원장이 요구하는 **양성 대조**(`tests/test_dr-drill.bats:161-163` 형태)를 함께 건다.
- **신설 module 0.** `tests/lib/absent.sh`는 세우지 않는다. 재개 조건(ADR-0001/0004 형태):
  바닥값 축이 콜사이트 로컬 정책으로 표현 불가능한 자리가 **3곳 이상 실증되고 동반 변경 이력이 실재할 때**.
- 파일: 전 레인의 `*.bats` ~60개. 테스트: 판정 의미 무변경, 위 재현이 red가 되는 증인 추가.

#### 02 · `[ABS]` 거부 가드 + venue 부채 상환

- 원형(`run grep … ; [ … -ne 0 ]`)을 red로 만든다. **새 가드 파일이 아니라** `scripts/check-bats-style.sh`의
  새 클래스 — 그 가드가 이미 bats 「코드 표면」(intest 상태기계·주석 먼저 순서·`<<<`/`$((` 오인원 제거·
  `detect_run`+READFILES·명시-파일 픽스처 모드)을 소유한다. 표면 판정을 둘로 가르지 않는다(ADR-0006 축).
- **⚠️ `-ne 0` 철자만 거부하면 안 된다 (게이트 r1 · F3 Accept).** 전환 이후에는 `-eq 1` 디렉토리 단언이
  자기 floor나 양성 대조가 제거돼도 compliant로 남아, **같은 vacuous green이 `[ABS]` 발화 없이 재발한다**.
  01이 6곳에 손으로 건 setup 단언이 영구 가드에게는 보이지 않는 것이 문제의 핵이다. → `[ABS]`가
  **형태로** 요구한다: 피연산자가 디렉토리이거나 판정이 루프 구동이면, 같은 `@test`(또는 그 `setup()`)에
  **비공허 floor와 양성 대조가 함께 있어야 한다**. 없으면 red.
  ⚠️ 게이트의 다른 권고("카디널리티를 검증하는 헬퍼")는 채택하지 **않는다** — 적대 검증이 deletion test로
  죽인 `tests/lib/absent.sh`를 되살리는 방향이다. 형태 판정은 열거가 아니므로 「열거 붕괴」 축도 피한다.
- **하드제로가 아니라 `ABS_BASELINE` 래칫.** 같은 파일의 `BB_BASELINE` 선례(`check-bats-style.sh:23` ·
  `scan-floor.sh:50-51` · `check-bats-accounting.sh:87`)가 정확히 이 이주를 위한 것이다. 래칫이라
  01과 별 PR이 가능하다.
- **venue 부채를 같은 PR에서 갚는다.** `check-bats-style.sh`는 Makefile·ci.yaml 명시 스텝이 없고
  `tests/gates/test_bats-style.bats:11-14`로만 돈다 — `check-bats-accounting.sh:17`이 "자기 bats에만
  의존하면 `.ci-exclude` 한 줄로 자기가 꺼진다"며 거부한 자리다. 새 하드 클래스의 유일한 집행자가
  한 줄로 꺼지면 안 된다. **별건 확대가 아니라 그 클래스의 전제다.**
- 히어스트링(`<<<`)은 경로가 없으므로 대상 밖 — 이 구별이 없으면 100곳 넘는 정당한 자리가 전건 red.
- 동반: `CONTEXT.md`에 「처방 도달」 승격(`docs(context):` 별도 커밋). 충돌 0.

### 클러스터 1 — 셸 계층

#### 03 · `hp_run_published` — 컨테이너 기동 프리미티브 (E · 유일한 신설 module)

- 6불변식(`rm -f` 선행 · `--rm` 금지 · 실패를 메시지·종료코드로 비판별 · 포트 재추첨 재시도 ·
  요청↔실제 매핑 대조 · 실패 시 `logs tail`)이 `tests/gates/lib/vmalert-e2e.sh:112-171`과
  `tests/gates/alertmanager-render-e2e.sh:94-145`에 두 벌로 산다. 출처가 커밋 `e0eff5f`(#525)이고
  그 제목이 "처방이 한 소비자 lib에 갇히면 인접 표면은 원리적으로 그 처방을 못 받는다"다 —
  같은 커밋에서 같은 클래스가 한 층 위로 재발했다.
- **배치: `tests/gates/lib/host-port.sh`에 얹는다**(새 파일 아님). publish하는 파일은 예외 없이 이미
  그 파일을 source한다. 헤더 규율(`:13-16` — `set -e` 비건드림·trap 비소유·exit 비소유)을 승계한다.
  두 사본의 종료 규약 차이(vme=exit 2, AM=exit 1)는 rc 번역으로 표현되고 그 번역에 이미 증인이 있다
  (`test_vmalert-e2e-port-allocation.bats:221-235`).
- **seam은 readiness 앞에서 끊는다.** vmsingle의 `/health` 본문 `OK*` 판정과 AM의 `/-/ready`는
  하네스-로컬 정책이다(CONTEXT.md 「판정 어휘」 · ADR-0005가 지킨 축).
- `VME_BIND_TRIES`/`AM_BIND_TRIES` → `HP_BIND_TRIES`로 통일.
- ⚠️ 원 설계의 실측 오류 정정: AM 사본의 자백은 **4회가 아니라 3회**(`:93`·`:101`·`:149`).
  `:73-74`는 vme가 아니라 skopeo 스모크를 가리킨다.
- 후속(같은 PR): `scripts/check-host-ports.sh` 레인 E — publish 컨테이너를 띄우면서 프리미티브를
  안 쓰면 red. ⚠️ 「같은 줄」 접속사 조건을 넣으면 레인이 vacuous해진다.
- 파일: `host-port.sh` · `vmalert-e2e.sh` · `alertmanager-render-e2e.sh` · `check-host-ports.sh` +
  증인 2. **다른 티켓과 충돌 0.**

#### 04 · `versions.env` 단일 값 리더 (F)

- `scripts/destroy-node.sh:73-75`는 `|| fail`, 같은 파일 `:56-58`은 통과. 후자의 sed는 파일 부재·
  키 부재·포맷 변경을 전부 빈 문자열로 접고, 셋 다 "국면 B, 파괴 허용"으로 읽힌다.
  ADR-0004의 기각 근거("파생 8곳 **전부** fail-closed")가 이 축에선 실측으로 반대다.
- **rc를 3분기가 아니라 2분기로 접는다**: `rc 0` = 정본 1회 선언(stdout = 값, 빈 값 포함) ·
  `rc 1` = 판정 불가(파일·키·형태·중복 전부) + stderr 사유 한 줄. 3-way를 쓰는 콜사이트가 **0곳**이라
  유지 근거가 없다.
- **정본 정규식을 좁힌다**: `^export <KEY>="[^"$\`\\]*"$` + 같은 규약을 versions.env
  전 13줄에 거는 정적 가드를 **같은 PR에 필수 포함**. 그래야 "텍스트 파서 == source"가 강제가 된다.
- **⚠️ 백슬래시 배제가 불변식의 전제다 (게이트 r1 · F2 Accept).** 최초 설계는 `[^"$\`]*`였고 백슬래시를
  허용했다 — 그러면 **"텍스트 파서 == source" 불변식이 거짓이다**. Bash 큰따옴표는 이스케이프를
  해석하는데(`\\` → `\`) 텍스트 리더는 원시 바이트를 돌려주고, 후행 `\"`는 그 정규식을 만족하면서
  셸 선언을 **미종료**로 남긴다. 두 소비자가 서로 다른 값을 관측한다. 백슬래시를 금지하는 쪽을 택한다
  (Bash 이스케이프를 정확히 재현하는 대안은 리더를 파서로 만든다). **계약 테스트 필수**: 허용되는 모든
  어휘 형태에 대해 리더 출력과 `source`된 값을 대조하고, 후행·이중 백슬래시를 거부 케이스로 넣는다.
- `source`를 쓰지 않는다는 기존 결정(`destroy-node.sh:53-55` — 파괴 직전 셸이 남의 export를 안 들인다)은
  유지. 배치: `infra/k3s-bootstrap/versions-read.sh` + `SCRIPT_DIR` 관용구(같은 트리 6파일) +
  `VERSIONS_ENV_FILE` seam. `chmod +x`·`git update-index` 모드를 명시(형제 `bulk-gate-probe.sh`가 644).
- 완화 사실(티켓에 명시): `destroy-node.sh:73-90`의 findmnt 정체성 게이트(2b)가 데이터 유실은 막는다.
  무효화되는 것은 "거부가 부작용 0으로 끝난다"는 성질이다.
- 소비자 4 + 픽스처 2. 파일: `versions-read.sh`(신규) · `destroy-node.sh` · `dr-drill.sh` ·
  `test_files-backup-phase-a.bats` + 증인 3.

#### 05 · `scripts/README.md`의 호출 경로 주장 (I)

- 24항목 중 6곳이 비권위 mirror를 권위로 주장(예: `:104` check-image-pins.sh가 "`make verify` 배선됨"을
  굵게 적는데 계산은 `make:verify`를 nonAuthoritative로 분류), 11곳은 문장이 아예 없다.
- **처방은 신설이 아니라 삭제.** 호출 경로 문장은 전부 `tools/check-guard-authority.ts`가 계산하므로
  deletion test에서 정보 손실 0. README가 소유하는 것을 계산 불가능한 것(목적·파괴성·불변식·위험)으로
  한정하고, 호출 경로는 포인터 한 문장으로 대체한다. 헤더 자기 계약(`:3`)도 정정.
- **막힌 두 경로(제안 금지)**: README를 계산에서 파생(ADR-0001 형태) · `policy/`에 소유권 원장
  (ADR-0004 형태 + `check-guard-authority.ts:12-14`의 명시 결정).
- **증인 스코프를 절이 아니라 bullet으로.** 「## CI 게이트」절 hard-zero를 버리고 `^- \*\*` bullet
  전건(실측 42)을 열거해 각 bullet이 호출 경로 술어를 담는지 본다. 절 경계 이동 우회가 소멸하고
  `secret-cert-check.sh:123-126`이 증인 안으로 들어온다. 판정 선은 토큰이 아니라 **술어 5종**
  (「…가 호출」·「…이 호출」·「배선됨」·「배선 아님/배선 없음」·「진입점은」).
- **면제를 레지스트리로**: 사유 + "왜 계산이 못 보는지" 표기 요구 + 건수 상한(오늘 3 → 상한 3).
  형제 처방(`check-bats-accounting.sh:81-82,94-97` · `tests/.ci-exclude:4-8`) 그대로.
- ⚠️ **01 블로킹**: 새 증인이 부재 단언 형태이므로 01의 전환 이후여야 무증인 초록이 안 된다.

#### 06 · `verify-traps` 4방향 + fail-open 전환 (D)

두 결함을 **한 편집**으로 닫는다. 순서가 아니라 한 편집이어야 하는 이유: 네 번째 방향을 fail-open인
채로 추가하면 새 방향도 같이 fail-open이 된다.

- **결함 1 — 인덱스 등식 무가드.** AGENTS.md가 "헤드라인 = traps-detail.md 섹션과 동일"을 선언하는데
  강제되는 세 방향이 전부 traps.md ↔ traps-detail.md 사이다. 실측: 개수는 106=106인데 **4건이 어긋나
  있다**(인덱스가 SSOT 헤드라인에 꼬리를 덧붙였다). 개수 축으로는 원리적으로 관측 불가 —
  「표면 붕괴」와 같은 계열.
- **결함 2 — 게이트 자신이 fail-open.** `:29`·`:50`이 방향 ②③을 `if [ -f "$DETAIL" ]`로 감싼다.
  DETAIL이 없으면 **rc=0으로 "원장 guard 실재 + SSOT↔원장 양방향 일치 OK"를 출력한다** — 건너뛴 게
  아니라 **검증하지 않은 주장을 낸다**. 처방은 같은 파일 세 줄 위에 있다: `:14`가 LEDGER에 대해
  `[ -f ] || { 진단; exit 1; }`를 이미 쓴다. locality 최대.
- **드리프트 4건의 수정 방향은 티켓에서 항목별로 판단한다** — 꼬리가 정보를 담고 있으면 SSOT 쪽이
  부족한 것일 수 있다. 등식은 **완전 일치**로 강제한다(접두 허용은 드리프트를 정당화하는 뒷문).
- ⚠️ 원 설계의 argc 허용 집합 {0,1,3}이 자기모순 — 재설계 필요. 픽스처/실 트리 모드 구별은
  CONTEXT.md 「가드 스코프」를 따른다.
- ⚠️ **05 블로킹**: `scripts/README.md` 공유 + 둘 다 셸 스캔 라벨을 추가하면
  `tests/gates/test_scan-floor.bats:257`의 `[ "$labels" -ge 29 ]`를 함께 올려야 한다(현재 정확히 29,
  주석이 '여유 없음'을 의도로 못박았다).

### 클러스터 2 — tools 커널

`tools/README.md`를 07·08·09가 공유한다 → **분리 착지 불가, 같은 PR.**

#### 07 · 앱 표면 값 경계 + 앱 레인 parity + 철거 극성 (C)

원 설계의 세 갈래 중 **갈래 1을 잘라낸다.**

- **잘라낸 것**: `sealedFileFor`/`secretNameFor` export. 봉인 이름 생산 자리가 실측 9곳인데 새 export가
  닿는 것은 4곳뿐이고, 나머지 5곳은 구조적으로 못 닿는다(`seal-secret.mts:89` 벤더 계약 ·
  `catalog-rows.ts:70` import-0 계약 · `check-app-deploy.sh` 셸 adapter · 워크플로 2곳). 규약이
  본질적으로 4언어·2레포에 걸쳐 있고 이 레포가 그것을 잇는 방식은 이미 rule-of-two + parity 가드다.
  주장된 ①→② 블로킹은 실재하지 않는다. `tools/lib/sealed-contract.ts`는 **무변경**(헤더 `:2-3`의
  "하나의 순수 함수 readSealed가 봉인 계약 전부를 소유한다"는 명시 설계 진술을 존중).
- **살린 것 ①**: `AppRelPaths.sealed`를 함수에서 **값**으로(`app-surface.ts:24,37,47`).
  `scripts/check-app-deploy.sh:104`가 이미 "봉인본은 `<app>-secrets.sealed.yaml` 하나만 허용"을
  강제하므로 현재 signature가 불변식보다 넓다.
- **살린 것 ②**: `test_lane-rows.bats:136-156`의 parity 가드를 손 열거(db/cache 4건)에서 **행 순회**로.
  앱 레인 3행이 리터럴 앵커(`:90-94`)만 갖는 비대칭이 설계 판단이 아니라 누락임을 형제 축이 증언한다.
- **살린 것 ③**: `tools/lib/mutation.ts:195-200`의 absence 극성. `blobAt`이 404를 `absent`로 접고
  absence 수렴에서 absent는 **무판정 통과**다(found=fail · error=미확정 · absent=통과) — 경로 오타가
  "이미 없었다"와 구별되지 않아 표면 축이 vacuous해진다. create 레인(`:264`)은 같은 absent를 fail로
  읽는다. 철거 **전** ref에서 표면 실재를 확인한다. ⚠️ 행위 변경이고 대상이 파괴 동사다 —
  이미 부분 철거된 상태의 재시도가 정당하게 실패하지 않는지 티켓에서 검증한다.

#### 08 · APPS 편집을 `digest-exporter.ts`로 라우팅 (G)

**진단이 틀린 자리를 가리키고 있었다.** 원 후보는 이 부채를 「배포 핀 형식 커널의 폭」으로 놓았으나,
`syncDigestExporter`가 재유도한 것은 tag 형식만이 아니라 **APPS 리스트 문법 전체**(항목 경계·이름 키·
ref 표기·존재 판정)다. 그 문법의 SSOT는 이미 `tools/lib/digest-exporter.ts`에 있고 세 쓰기 주체 중
둘(`create-app.ts:215` · `teardown-app.ts:49`)이 이미 그것을 지난다. 형제 자리에 이미 있는 처방이
여기엔 없다 — 캠페인 축 그대로다.

- 무성 실패 4종이 격리 픽스처로 실측됐다. 경로: TAG_BODY 변경 → 매치 0건 → `next === raw` →
  `:31-36` 조용한 skip → digest-exporter APPS가 stale 태그에 묶임 → R6 `ImageDigestDrift` **거짓 발화**.
- 착지 증거 보강(필수): `test_image-pin-lib.bats:99`의 검출기 로스터에
  `tools/lib/digest-exporter.ts`를 추가(오늘 두 리터럴 0건이라 무비용). `tools/lib/image-pin.ts`는
  로스터에 **넣지 않는다**는 것을 주석으로 못박는다(커널이 형식의 유일한 소재지).
- 불변식 문구 정정: "이미 최신이면 바이트 동일" → "이미 최신이고 **APPS가 이미 정준**(코드유닛 정렬 +
  단일 공백)이면 바이트 동일".
- **긴급성이 낮다는 사실을 티켓에 명시한다** — `apps/`가 오늘 비어 있다(`README.md` 하나,
  `apps.json` = `[]`). 그래서 **지금이 안전한 착지 시점**이다: 회귀가 라이브를 못 건드린다.
- ⚠️ **07 블로킹**: `bump-tag.ts`가 `app-surface.ts` 소비자다.

#### 09 · ops 재핀 카탈로그 표기 통일 + 집합 대조 (J)

- `check-image-ownership.ts:209-211`의 `REPINNED_OPS`가 `repin-ops-image.ts:19-22`의 `CATALOG`와
  주석으로만 묶여 있다(소비자 2줄, 테스트 참조 0건). 형제 쌍(CATALOG ↔ `bump.yaml`)에는 실제 게이트가
  있다(`test_ops-repin.bats:59`). 두 정규식은 **이미 갈렸다**(경로 구분자 요구 여부, 근거 없음).
- **신설 module 0.** ① 표기를 제자리에서 좁힌다(`ghcr\.io\/[a-z0-9-]+\/…@sha256:[0-9a-f]{64}`) —
  실 트리 차이 0이라 동작 보존이고, `infra/**`처럼 renovate 미도달 경로의 거짓 소유가 사라진다.
  ② 집합 대조 게이트를 `test_ops-repin.bats`의 **세 번째 @test**로(`:59`와 동형, 같은 파서 관용구,
  양쪽 바닥값 `-ge 2`). 이것이 추가 방향 드리프트(CATALOG에만 넣고 REPINNED_OPS를 잊음)를 막는
  유일한 기전이다. ③ skopeo 증인을 `test_image-ownership.bats`의 `_fixture`에 추가.
- 드리프트 손해는 오귀속(`resolveOwner`가 `renovateReaches`로 떨어져 "owner: renovate"로 초록)이지
  배포 사고가 아니다 — 티켓에 명시.

#### 10 · `audit-orphans` 스캔 신호 (K)

- 라벨 선언이 4번째 형태(`const FLOOR_REGISTRY = "…"`)라 정적 로스터가 못 보고, 바닥값 비교가
  커널을 안 거치며(`:109-111`), 신호를 어느 채널로도 안 낸다. `:109` 비교와 `:252` 출력 사이에
  findings 수집 140줄이 낀다 — 커널 독스트링(`scan-floor.ts:139-142`)이 없애려던 배치 그대로다.
- **커널 표면을 늘리지 않는다.** `scanFields` 신설은 방출을 가져가지 않으면 콜사이트 리터럴과 규율상
  동치다. `tools/audit-orphans.ts` **안에서만** 닫는다: 라벨 상수 7개 → `assertFloorKeys`(이미 import) →
  `:113` 직전 한 블록에서 일곱 열거 후 `floorOf` + `scanFloor(…, { quiet: true })` 루프로 붕괴를
  **모아** 던지고 콜사이트가 exit 1을 소유(3분기 종료코드 유지). 페이로드는 `:252`에
  `scan: {라벨: 건수}`(`dns-drift-check`의 합계 결함은 복제하지 않는다).
- 바닥값은 근거 있는 곳만: 원장 행 1 · role 1 · registry/apps/caches/tombstones 0.
- ⚠️ **07 블로킹**: `audit-orphans.ts:18`이 `app-surface.ts`를 import한다.

### 클러스터 3 — 레포 밖으로 나가는 쓰기 경로

#### 11 · 스테이징 완전성 판정 (B)

- **라이브 사고 실측**: `_create-app.yaml:135-139` 주석이 2026-08-18 사고를 적었다 — `create-app.ts`가
  `digest-exporter.yaml`에 쓰는데 `add-paths` 천장 밖이라 유실. 처방은 한 레인에만 착지했다
  (`test_create-app.bats:285`).
- **`add-paths`는 상한으로 남긴다** — 매니페스트로 바꾸지 않는다(오염된 도구가 커밋할 수 있는 범위를
  묶는 설계). 처방은 열거가 아니라 **잔여물 판정**이다.
- **신설 module 0.** `scripts/assert-staged-complete.sh`를 만들지 않는다(본체 4줄, 세 콜사이트 중
  `run-bump-plan.ts`는 소비 불가 — ADR-0003·0006이 같은 자리에 이미 선다). 판정을 **각 콜사이트에,
  그 언어로, `git add` *앞*에** 인라인한다 — `tools/lib/secrets.ts:74-79`에 이미 착지한 형태:
  `git status --porcelain --untracked-files=all` → 각 줄의 경로를 그 사이트의 자기 천장과 집합차 →
  foreign 비었나. 셸 쪽 포함 판정 선례는 `test_create-app.bats`의 `case "$c" in "$p"|"$p"/*)` 4줄.
  ⚠️ `secrets.ts`의 `l.slice(3)` 고정 오프셋은 복사 금지(rename `R  a -> b`·따옴표 경로에서 깨진다).
- **로스터 3 → 5**: `action.yml:40` · `teardown.sh:68`(`|| true`가 add 실패까지 삼킨다) ·
  `run-bump-plan.ts:119` · **`bump.yaml:139`** · **`secrets.ts:81`**.
  `init.ts:177`은 "천장을 선언하지 않는다"는 **성질로 파생 제외**(이름 면제 목록은 다음 사본이 된다).
- `bump.yaml:139`는 특례 — 천장이 파일 매니페스트가 아니라 디렉토리 스코프(`-A -- apps platform`)이고
  `:134-138` 주석이 그 근거를 논증한다.

#### 12 · `--ensure-cmd` 광고/파서 불일치 + `cli.ts` 수렴 (M)

- `run-bump-plan.ts:18`·`:21`·`:44`가 `--ensure-cmd`를 광고하는데 파서(`:41`)는 `--ensure-bin`/
  `--ensure-script`만 받는다. `--help`를 따라 하면 `exit 2`. 실측: `--ensure-cmd` 콜사이트 레포 전체
  **0건**, `tools/README.md:210`은 이미 argv seam으로 옳게 적혀 있다. → **광고를 정정한다**
  (파서에 추가하지 않는다 — `:40` 주석이 shell-string split을 명시 기각했고 태생부터 argv seam이다).
- **증인에 정적 절반을 붙인다**(필수): 런타임 parity만으로는 `:18`·`:21`이 무증인.
  `run grep -c -- '--ensure-cmd' tools/run-bump-plan.ts` → `[ "$output" = "0" ]`를 **주석 스트립 없는
  원본**에 건다(`check-floor-vocab.sh` 형태 — "인식 제거는 '안 본다'이고 필요한 것은 '있으면 red'다").
- `lib/cli.ts` 우회에 근거 주석이 없다(비교: `generate-result-schema.ts:653`은 명시). SSOT로 수렴시킨다.
  ⚠️ `toctou:44`의 `opts["--base"] ?? "main"` 재작성 필요.
- ⚠️ **11 블로킹**: `run-bump-plan.ts`·`test_run-bump-plan.bats` 공유.

#### 13 · `tf-r2-init` state-key 파생 (H)

- 5/5 콜사이트가 `<root>/prod/terraform.tfstate`이고 등식을 강제하는 것이 0건. 잘못된 짝을 붙여도
  전 게이트 초록이고 `terraform init`은 성공하며 github 루트가 cloudflare state에 바인딩된다.
- **입력을 제거하고 파생한다** — 등식은 정보가 0이고(레포 전체에서 달리 쓰는 자리 없음), 강제 기전이
  **이미 설치돼 있다**: `state-key` 입력을 지우면 남은 `with: state-key:`를 actionlint가 required gate에서
  즉시 red로 만든다(실측 재현). B·C안은 정보 0인 중복을 강제하는 비용을 새로 지불한다.
- ⚠️ 약점: `action.yml:15`의 `ROOT: ${{ inputs.root }}`가 유일한 고리가 되는데 **actionlint가 이 줄을
  못 본다**(재현됨). 증인을 다시 설계한다 — 부정 단언과 **같은 셀렉터**에서 파생:
  `yq '.jobs[].steps[] | select(.uses == "./.github/actions/tf-r2-init")'`로 열거해 ⓐ 크기 == 5(바닥값,
  콜사이트 소유) ⓑ `.with` 키 union에 `state-key` 0건 ⓒ 각 스텝의 `.with.root` 비공허.
  `test_telegram-callsites.bats:63-70`의 **부분 실명 대책**(yq 매치 수 == `grep -c` 교차검증)을 가져온다.
- **⚠️ 호출부 증인만으로는 부족하다 — action-로컬 증인이 필수다 (게이트 r1 · F1 Accept, high).**
  위 ⓐⓑⓒ는 전부 **호출부 형태**만 본다. `state-key`를 제거하면 action의 root→key 파생이 **유일한
  격리 경계**가 되는데, action이 키를 하드코딩하거나 오타 내거나 달리 잘못 파생해도 ⓐⓑⓒ는 전건
  통과한다. 그 상태에서 `terraform init`은 **잘못된 기존 state에 대해 성공**하고, 이어지는 plan/apply가
  다른 루트의 리소스를 관리한다 — 이 티켓이 막으려던 바로 그 실패다. 경계를 하나로 줄이는 변경은
  그 하나에 증인을 세우는 것과 **같은 편집**이어야 한다.
  → 두 가지를 추가한다: ① backend key가 정확히 `<root>/prod/terraform.tfstate`로 파생됨을 증명하는
  **실행 가능한 픽스처**(또는 추출된 파생 헬퍼에 대한 직접 단언) — 호출부 형태 대조가 아니다.
  ② `root`를 지원되는 세 루트(`cloudflare`·`tailscale`·`github`)에 대해 **검증**한다 — 오늘 action은
  임의 문자열을 받는다.
- **다른 티켓과 충돌 0.**

#### 14 · `pr-sweeper` 증인 실질화 (L)

- 증인이 항진명제다: `test_pr-sweeper.bats:39-42`의 `grep -qE 'bump|create-|update-secrets'`는
  **정규식을 통째로 지워도 초록**이다. 주석(`:40`)의 목록은 이미 드리프트했다(`bump-poll/`은 `:64-78`에서
  의도적으로 제거됐다). 오늘의 실害는 0(teardown 레인이 `auto-merge: 'false'`라 배제됨).
- **파생 우주를 `LANES`가 아니라 무장 초크포인트로.** `Object.keys(LANES)` 등식과 `n !== 5` 불변식을
  폐기한다 — `bump/`가 `LANES` 밖이라 그 우주가 애초에 안 맞는다. 대신 **무장 생산자 전수 스캔**:
  ① `pr-first-commit` 소비자 중 `auto-merge: 'true'`(오늘 3) ② `bash scripts/auto-merge-or-fail.sh`
  직접 호출(오늘 `bump.yaml:148` 1건) ③ `gh pr merge --auto` 직접 호출(오늘 `auto-merge-or-fail.sh:13`).
  불변식: **무장하는 생산자의 브랜치 접두는 전부 라이브 union이 select해야 한다**, 예외는 `bump-poll/`
  하나이며 근거는 이미 `pr-sweeper.yaml:64-73`에 있다.
- 스캔 관용구는 발명이 아니다 — `test_bump-poll-callsite.bats:606-616`(전 워크플로 스캔) ·
  `test_mutation-dispatch.bats:180-205`(동적 열거)가 같은 형태다.
- 정규식을 **실행하는** 증인으로 대체한다(`test_bump-poll-callsite.bats:570` 관용구).
- teardown 접두 부재가 의도인지 누락인지 판정하고, 어느 쪽이든 근거를 `pr-sweeper.yaml`에 적는다.
- ⚠️ **01 블로킹**: `test_mutation-dispatch.bats` 공유.

## 4. 블로킹 그래프

```
01 (전환) ──► 02 (가드)
   │
   ├──► 05 (I) ──► 06 (D)          [scripts/README.md + scan-floor 라벨 :257 여유 0]
   ├──► 04 (F)                      [test_destroy-node.bats]
   ├──► 11 (B) ──► 12 (M)           [test_teardown-wrapper.bats / run-bump-plan.ts]
   ├──► 14 (L)                      [test_mutation-dispatch.bats]
   └──► 06 (D)                      [traps.md · traps-detail.md · test_traps-sync.bats]

07 (C) ──► 08 (G)                   [app-surface.ts 소비자]
07 (C) ──► 10 (K)                   [audit-orphans.ts:18 import]
07·08·09 는 같은 PR                  [tools/README.md 3자 공유]

클러스터 1 ──► 클러스터 2            [test_scan-floor.bats — 셸 레그 :257 / TS 레그 :353]

독립(충돌 0): 03 (E) · 13 (H)
```

## 5. PR 착지

| PR | 티켓 | 서사 |
|---|---|---|
| PR-0a | 01 | `-eq 1` 전건 전환 + setup 비공허 단언 (~60파일) |
| PR-0b | 02 | `[ABS]` 래칫 가드 + venue 부채 상환 + CONTEXT.md 어휘 승격 |
| PR-1 | 03 · 04 · 05 · 06 | 셸 계층 — 프리미티브 넷이 각자의 형제에게 닿는다 |
| PR-2 | 07 · 08 · 09 · 10 | tools 커널 — 커널의 처방이 형제 소비자에 닿는다 |
| PR-3 | 11 · 12 · 13 · 14 | 원격 쓰기 경로 — 자기 완전성을 증명한다 + ADR-0007 |

PR-0을 둘로 나눌 수 있는 것은 가드가 하드제로가 아니라 래칫이기 때문이다. 원 계획(4 PR)에서 5 PR로
늘었다.

## 6. 산출물

- **`CONTEXT.md` 「처방 도달」 승격** — PR-0b에 `docs(context):` 별도 커밋. 충돌 0.
- **ADR-0007 「처방 도달을 하나의 정적 가드로 판정하지 않는다」** — **마지막에 착지하는 클러스터의
  마지막 커밋**(현 계획으로는 PR-3). ADR-0002 형식을 따른다: 기각 근거 + 비회귀 기준선 표 + 재개 조건.
  기준선 표는 14개 처방이 각자 어떤 모양으로 착지했는지에서 나오므로 **착지 후에만 정직하다** —
  A1에 넣으면 설계 패스의 추정을 표로 박게 되고, 뒤 티켓 하나가 무너지면 ADR이 틀린 표를 진 채 남는다.
  재개 조건: **인접 표면 집합이 열거 가능한 도메인이 나타날 때**(형제 관계가 파일명 규약이나 원장으로
  이미 선언되어 열거가 파생값인 경우 — 그런 도메인에서는 열거 밖을 안전으로 읽는 문제가 원리적으로
  생기지 않는다).

## 7. 결정 기록

| # | 결정 | 근거 |
|---|---|---|
| 1 | 통합 메타 가드가 아니라 14개 독립 처방 | ADR-0002가 다섯 번 무너진 구조. 인접 표면은 열거 불가 |
| 2 | 14건 전부 담는다(카드 8 + 짧은 목록 4 + 결함 1, A2는 01에 흡수) | 전건이 같은 클래스이고 근거가 같은 수준으로 실측됐다 |
| 3 | deepening이 아닌 항목(판정 추가·결함 수정)도 같은 캠페인에 | 레포 관행(guard-witness·meta-observability). 빼면 클래스 증거가 절반이 된다 |
| 4 | 「처방 도달」을 CONTEXT.md에 승격 + 진단 3조건 명시 | 이미 두 번 실증됐다. 3조건이 없으면 "중복 합치기"로 오독된다 |
| 5 | 클러스터별 PR, 01은 단독 | 충돌 회피 + `gate` 실행 절감. 강도는 의존 관계가 아니라 그룹핑 축이 못 된다 |
| 6 | 통합 메타 가드 기각을 ADR-0007로 | 미래 리뷰가 거의 확실히 재제안하고, 무너지는 이유는 재발견하기 어렵다 |
| 7 | 01의 전환 스코프를 184곳 전건으로(32곳 아님) | A/B 분류는 진단이지 전환 스코프가 아니다 — 완전성 가드가 그 선을 못 본다 |
| 8 | `verify-traps` 두 결함을 한 편집으로 | 네 번째 방향을 fail-open인 채 추가하면 새 방향도 fail-open이 된다 |
| 9 | G를 방향 전환해 담는다(빼지 않는다) | `apps/`가 비어 있는 지금이 안전한 착지 시점 — 회귀가 라이브를 못 건드린다 |
| 10 | 적대 검증의 revision 8건 일괄 수용 | 전부 실측 반박이고 방향이 "새 module 말고 형제 처방"으로 수렴한다 |

## 8. 재제안 방지 (이 패스가 확인한 것)

- **ADR 재개 조건 전건 미충족**: 0001(`verbs.ts` 커밋 2건) · 0003(완전성 가드 여전히 파일별 정적 판정) ·
  0004(`metrics`/`heartbeat` 두 번째 소비자 없음) · 0006(TS 표면 결함 여전히 1건).
- **정당한 depth로 판정된 것**: `ensure-bump-pr.ts` 1886줄(코드 911 + 근거 주석 903, 두 모드가 같은
  파서·술어를 공유하는 것이 계약, churn 4커밋) · `check-alert-rules.ts` 1183줄(두 반쪽이 한 값으로만
  만나고 스캐너 소비자가 이 파일 하나).
- **이미 실증된 shallow**: TS 가드 프롤로그 커널 — `scan-floor.ts`가 그 형태(`reportScanError`)를
  **이미 만들었다 지웠다**(소비자 0 지속).
- **강제 기전이 이미 있어 후보가 아닌 것**: 레인 신원 3축 · `make ci` ↔ gate 패리티 ·
  `policy/` 원장 공통 대조 · 가드 커널 두 adapter · `reusable-app-build` 계약.
- **ADR-0002 축 재제안 금지**: `homelab-mutation` 그룹 멤버십 · `persist-credentials` 잔존.
- **어제 명시 기각**: `scope_floor` 4동사 커널(`guard-witness/06`) · 셸 순수 판정 import.
