# 설계 — 소유권 회계 (ownership-accounting)

- slug: `ownership-accounting`
- 작성일: 2026-07-26
- 출처: `/deepen` Stage 1 — 최근 200커밋 hot spot 기반 4영역 병렬 탐색 → 후보 6개 중 C-2 채택
- 스캔 리포트: `$TMPDIR/architecture-review-20260726-012235.html` (임시, 레포 밖)

## 채택한 심층화, 그리고 밀려난 대안

**채택**: 가드들이 공유할 **저장소 스캔 워커**를 `tools/lib/`에 만들고, 그 위에 **"정확히 한 곳이 소유한다"
회계**를 두 도메인(G1 가드→실행 venue, G2 아티팩트→핀 소유자)에 적용한다.

**밀려난 대안 — "회계 커널"**: 애초 스캔 리포트의 추천은 `check-bats-accounting.sh`의 카운팅 로직을
공유 module로 뽑는 것이었다. grilling에서 기각했다. 그 스크립트를 뜯으면 ①항목 열거 ②도메인 멤버십
③정확히-하나 카운팅인데, **③은 12줄 루프**다. 커널로 뽑아도 deletion test에서 복잡도가 집중되지 않고
이동만 한다(각 도메인이 12줄을 다시 씀). 진짜 깊이는 ①에 있고 그게 이 설계의 워커다.
②는 도메인마다 완전히 달라 공유 불가(`renovate.json` 패턴 해석 vs `ci.yaml` 스텝 파싱).

즉 **C-2는 "커널을 만든다"가 아니라 "이미 검증된 형태를 두 도메인에 더 적용한다"**이고,
스캔 리포트가 제안한 순서(C-2 → C-1)는 뒤집힌다. **워커가 먼저다.**

## 심층화된 module의 모양

`tools/lib/repo-walk.ts` — 한 module, 두 진입점.

```ts
walkManifests(scope) → { path, text, docs }[]   // 파일 단위, docs 파싱은 lazy
listUnits(scope)     → { name, dir }[]          // 앱/컴포넌트 디렉토리 단위
```

`scope`는 **이름 붙인 고정 집합**이다(조합 가능한 기술자가 아니다). 초기 6종:

| scope | 진입점 | 열거 출처 | 비고 |
|---|---|---|---|
| `platform-manifests` | walkManifests | tracked | 제외: charts/ · barman-plugin · tests/ · fixtures*/ · gateway-api-crds |
| `apps-values` | walkManifests | tracked | `apps/*/deploy/prod/values.yaml` |
| `rules` | walkManifests | tracked | `platform/victoria-stack/prod/rules/*.yaml` |
| `producers` | walkManifests | tracked | 레포 전역 − SKIP_DIRS − `test_*` − `*.bats` |
| `apps` | listUnits | tracked | `apps/*/deploy/prod` 디렉토리 — **필수 산출물로 거르지 않는다**(design-r1 R-1) |
| `platform` | listUnits | filesystem | `charts` 제외 |

⚠️ **`apps` scope는 필수 산출물(`values.yaml` 등)로 필터해선 안 된다** (design-r1 R-1). 초안은
`audit-orphans.ts:56-58`의 필터를 그대로 가져왔는데, 거기선 정당하다(고아 탐지는 배포 가능한 앱만 보면
된다). 그러나 `check-app-deploy`는 **`values.yaml`의 존재 자체를 검사**한다 — 열거자가 미리 걸러내면
위반이 검사 대상에서 사라져 **배포를 깨뜨리는 false green**이 된다. 같은 필터가 한 소비자에겐 맞고 다른
소비자에겐 치명적이라는 것이 scope 설계의 근본 함정이다. 의미론적 필터는 **소비자 쪽에** 둔다.

### seam 뒤에 들어가는 것 (= 호출자가 더 이상 몰라도 되는 것)

1. **"레포"의 의미** — tracked(`git ls-files`) vs filesystem(`readdirSync`)의 선택. 지금 이 지식은
   `check-image-pins.sh:96` 주석("untracked helm 캐시 자동 제외")에만 있다. scope 정의의 성질이 된다.
2. **제외 어휘** — 현재 6곳에 흩어져 서로 다르다. 한 곳이 된다.
3. **YAML 파싱** — 현재 3종(`yaml` 패키지 / `yq` / raw grep-sed-awk)이 난립. TS 경로는 한 곳으로.
4. **열거 바닥값** — scope는 자기 최소 기대치를 알고, **열거 단계의 붕괴**(글롭이 깨져 0건)를 시끄럽게
   실패시킨다. 현재 12개 가드 중 3개만 바닥값을 갖고 각자 다른 상수(20/10/30)를 하드코딩한다.

### ⚠️ scan-floor로 vacuous pass가 닫힌다는 주장은 철회한다 (design-r1 R-1)

초안은 ④가 "현재 vacuous로 통과 중인 가드 3건을 한 번에 닫는다"고 주장했다. **틀렸다.**
워커의 바닥값은 *열거*가 붕괴했는지만 안다. 대부분의 vacuity는 **소비자의 의미론적 필터 이후**에 생긴다:

- `check-app-netpol` — 앱 개수가 아니라 *필터 후 NetworkPolicy 개수*가 0이다. 앱 디렉토리 바닥값으로는
  안 잡힌다. 그리고 앱이 NetworkPolicy를 하나도 안 가지는 것은 **정당할 수 있다**.
- `verify-runbook-index` — 디렉토리가 gitignored라 CI에서 skip한다. 열거 문제가 아니다.

따라서 비어있음 검사는 **각 소비자가 자기 필터 뒤에서** 수행하고, 0이 정당한 곳은 **조건부 도메인
불변식**으로 쓴다(예: "앱이 NetworkPolicy를 선언했다면 그 selector는 …"). 워커는 열거 붕괴만 책임진다.
이 심층화의 이득은 여전히 실재하지만(①②③ + 열거 붕괴 감지), **vacuous pass 3건 일괄 해소는 이득에서 뺀다.**

### 셸 가드의 소비 방식

셸 가드 4개(`check-image-pins` · `check-app-netpol` · `check-app-deploy` · `check-skeleton`)는
**TS로 이관하지 않는다**. `CONTRIBUTING.md`가 "라인 지향 검사(grep/yq/jq 필터)"를 셸의 명시된 영역으로
규정하고, `check-app-deploy.sh:21`은 "yq는 버전차 함정이라 값 추출은 sed/grep으로"라는 의도적 선택을 적어 뒀다.

대신 워커에 **얇은 CLI**를 붙여 열거 결과만 넘긴다:

```bash
bun tools/lib/repo-walk.ts --units apps          # → 디렉토리 목록
bun tools/lib/repo-walk.ts --manifests platform  # → 경로 목록 (제외 적용됨)
```

셸은 자기 grep/yq 필터를 그대로 유지하고 **열거·제외·열거 바닥값만** 받는다. 셸이 추가 제외를 하지
않으므로 제외 어휘의 사본이 **원리적으로 존재하지 않게 된다**. (선례: `scripts/teardown.sh:31-45`가
이미 `bun tools/*.ts`를 호출한다.)

## 회계 — 계산하되 선언하지 않는다

### 모델 정정: "정확히 하나"가 아니라 "권위 있는 소유자 ≥1" (design-r1 R-2·R-3)

초안은 소유권을 **집합 멤버십 + 정확히 하나**로 모델링했다. 두 도메인 모두에서 틀린다 —
실제 구조는 **"권위 있는 소유자 1 + 도달 가능한 비권위 경로 N"**이다.
어떤 메커니즘이 파일에 *도달할 수 있다*는 것과 그 파일의 갱신을 *책임진다*는 것은 다른 사실이고,
`check-bats-accounting`의 세 도메인이 상호배타적이었던 것은 그 도메인의 성질이지 소유권 일반의 성질이 아니다.

따라서 판정 술어는 `count(owners) == 1`이 아니라 **`count(authoritative) >= 1`**이고,
비권위 경로(wrapper · mirror · 테스트 호출 · 일반 갱신기 도달성)는 **세지 않는다**.
`count == 1`은 도메인이 **실제로 상호배타적임이 증명된 경우에만** 쓴다.

### G1 — 가드 → 실행 venue

`check-bats-accounting.sh`가 작동하는 이유는 평행 레지스트리를 만들지 않았기 때문이다. 멤버십을
**실제로 결정하는 것에게 묻는다**(`run-bats.sh --list`를 실행, 러너가 실제로 읽는 `.ci-exclude`를 읽음).

이 심층화가 고치려는 병이 정확히 "주장을 적어두고 아무도 대조하지 않는 것"이므로
(`check-image-pins.sh:12`의 "Renovate 관할" · `AGENTS.md:129-133` 소유 목록 · `repin-pgtools.ts`의 "5개 소비처"),
**`policy/`에 새 소유권 레지스트리를 만들지 않는다.** 그건 같은 병을 하나 더 만드는 것이다.

예외 목록도 두지 않는다. 대신 **소유자 분류 체계를 완전하게 만든다** — `.ci-exclude`가 "예외"가 아니라
하나의 venue이듯, "주 1회 cron"·"owner-local"·"수동 re-vendor"도 예외가 아니라 소유자 이름이다.
doc-only 함정은 `> 가드:` 줄의 부재로 이미 계산 가능하므로 별도 선언이 필요 없다.

- **항목**: `scripts/check-*.sh` · `scripts/verify-*.sh` · `tools/check-*.ts` · `tests/gates/*.sh`(docker 게이트)

**권위의 정의 = "불변식이 실제 도메인에 대해 평가됐는가"** (design-r2 R-4).
어느 venue에서 도느냐가 아니다. 실행됐지만 대상이 비어 조용히 통과한 경로는 권위가 아니다.

- **권위 경로 (센다)**
  - `ci.yaml`의 `gate` job 스텝 + 그 스텝이 부르는 것(`run-bats.sh --list`로 수집되는 bats 포함) —
    **단 그 실행이 가드의 실제 도메인에 닿을 때만**
  - 스케줄 워크플로(cron)의 직접 호출
  - **owner-local 전용 엔트리포인트**(`make verify-runbook-index`·`make verify-posture`·`make verify-ksops`) —
    도메인이 CI에 존재하지 않는 가드에겐 **이것이 유일한 권위**다
- **비권위 경로 (세지 않는다)**
  - `make verify`·`make ci`(로컬 편의 mirror) · pre-commit 훅 · 가드를 실행하는 bats가 **또** 있는 경우
  - **픽스처 전용 · 스모크 전용 · skip-only bats 호출** (design-r2 R-4)
- **별칭은 전이적으로 해소한다** (design-r1 R-2): `bun run verify:ledger` → `package.json` 스크립트 →
  `scripts/verify-ledger.sh`. 해소하지 않으면 정당한 가드가 "도달 경로 0"으로 오탐된다.
- **판정**: 각 가드가 **자기 도메인에 대해 실제로 평가되는 권위 경로를 최소 하나** 갖는가. 0이면 FAIL.

⚠️ **skip 경로가 거짓 권위를 준다** (design-r2 R-4). `tests/gates/test_verify-runbook-index.bats:9`는
`[ "$status" -eq 0 ]`을 단언하는데 `verify-runbook-index.sh:9`의 **skip 경로(gitignored 디렉토리 부재 →
exit 0)가 그걸 만족한다.** CI에서 그 bats는 통과하지만 불변식은 한 번도 평가되지 않는다. 그 가드의
실제 소유자는 owner-local `make verify-runbook-index`이고, 초안 모델은 그걸 비권위로 배제했다 —
즉 **회계가 통과하면서 로컬 전용 가드가 실제 실행 경로를 잃어도 감지 못 한다.** 같은 형태가
`make verify-posture`(KUBECONFIG 없으면 exit 0)·`make verify-ksops`(age 키 없으면 skip)에도 있다.
- **구현 요구**: bats 래퍼가 도메인에 닿았는지를 판정하려면 가드가 **skip을 성공과 구분해 신호**해야 한다
  (예: skip 시 전용 종료코드 또는 표준 마커 출력). 이것 없이는 정적 분류로 근사할 수밖에 없고,
  그 근사는 이 finding이 지적한 구멍을 완전히는 못 막는다 — 티켓에 명시할 것.
- **잡히는 것**: `check-bats-style.sh`가 `gate`에 도달하는지(현재 bats 래퍼 경유로 도달 — 확인 필요) ·
  `ci.yaml`에 수기 나열된 docker 게이트 8개의 무회계(9번째 누락·기존 1개 삭제 감지 불가) ·
  owner-local 가드가 자기 Make 타깃을 잃는 경우
- ⚠️ **정정** (design-r1 R-2): 스캔 리포트가 `check-credential-expiry.sh`를 "고아"라 한 것은 **오류**다.
  `.github/workflows/credential-expiry.yaml:35`가 직접 호출하며, 스케줄 워크플로는 권위 경로다.
  `check-skeleton.sh`가 `ci.yaml:51`과 `make verify` 양쪽에서 도는 것도 **정상 mirror**이지 이중소유가 아니다.
  초안의 `count == 1` 모델이었다면 둘 다 오탐이었다.

### G2 — 아티팩트 → 핀 소유자

- **항목**: 레포의 모든 컨테이너 이미지 참조 + 런타임 페치 아티팩트
- **권위 있는 소유자 (아티팩트별 우선순위)** (design-r1 R-3):
  - `pg-tools` → `repin-pgtools.ts`의 `CONSUMERS`가 **권위**
  - apps 레인 → `.bindings.json` + bump-poll
  - 베스포크 레인 → `.image-pin.json` descriptor + bump-poll
  - 서드파티 platform 이미지 → Renovate **(단 적용성 증명 필수 — 아래)**
  - 벤더 파일 → 수동 re-vendor / setup-toolchain 수동 sha256

⚠️ **권위 소유자로 지정했다고 소유가 증명되는 게 아니다** (design-r2 R-5). 초안은 R-3을 고치면서
Renovate를 비판정 freshness 채널로 **과잉 강등**했다. 그 결과 서드파티 이미지는 *분류표만 보고*
"소유자 있음"으로 통과하게 된다 — `ignorePaths` 변경 · manager 패턴 공백 · 지원 안 되는 manifest 모양이면
실제로는 추출 불가인데도 초록이다(조용한 stale-pin 노출). D-2 탐지도 같이 약해진다:
D-2는 "Renovate가 차트 내부 이미지에 **도달 불가함을 증명**"하는 것이 핵심인데, 도달성을 판정에서
빼버리면 증명할 대상이 사라진다.

- **Renovate가 지정 권위 소유자인 아티팩트에는 차단성 적용성 검사를 요구한다**:
  Renovate가 그 파일에서 그 이미지를 **실제로 추출하는지**의 증거(추출 결과 또는 dry-run).
  그것이 CI에서 비싸면 **fail-closed 근사 + 센티넬 테스트**로 대체한다 — 즉 근사가 깨졌을 때
  조용히 통과하지 않고 실패하도록, 알려진 매치/논매치 샘플을 고정 테스트로 박아 둔다.
- **pg-tools·앱 핀에서는 Renovate가 여전히 비권위다**(R-3 수정 유지). 강등은 그 두 곳에만 적용된다.

**Renovate 도달성은 (pg-tools·앱 핀에서) 소유권 매치가 아니다.** 별개의 **freshness 채널**로 취급한다.
  이유: `renovate.json:29-32`가 `^platform/.+\.ya?ml$`를 덮으므로 pg-tools 참조는 전부 Renovate에도 매치된다.
  초안의 `count == 1` 모델로 계산하면 **정확히 반대 결과**가 나온다 —
  `CONSUMERS`에 등록된 4파일은 소유자 2개(이중소유 오탐), **누락된 2파일은 소유자 1개(통과)**.
  D-1을 잡기는커녕 올바른 쪽을 신고한다.
- **D-1 탐지는 별도 불변식으로**: "레포의 모든 `pg-tools` 참조가 `CONSUMERS`에 등장해야 한다" —
  소유권 카운팅이 아니라 **권위 목록의 완전성 검사**다. 같은 형태를 digest 일치로도 확장할 수 있다
  (같은 태그의 참조는 같은 digest여야 한다 — `check-image-pins.sh`가 지금 핀의 *존재*만 보고 *일치*는 안 본다).
- **잡히는 것**: D-1(위 완전성 불변식) · D-2(차트 내부 이미지 — **패턴 해석 없이 잡힌다**: 파일이
  gitignored라 Renovate가 원리적으로 도달 불가) · D-3(CNPG `SIDECAR_IMAGE`가 base64 Secret 안이라 모든 메커니즘 밖)
- ⚠️ **알려진 근사**: Renovate의 매칭 의미론을 정적으로 재구현하므로 미묘하게 틀릴 수 있다.
  근사는 **fail-closed**여야 하고(불확실하면 "소유 없음"으로 판정), 센티넬 테스트로 근사의 붕괴를
  감지해야 한다(design-r2 R-5). pg-tools·앱 핀에서는 판정에 안 쓰이므로 영향이 작지만,
  서드파티 이미지에서는 **판정에 쓰인다**.

**G1이 G2보다 먼저**다. G1 없이는 G2의 가드 자체가 `gate`에 도달하지 못한 채 조용히 안 돌 수 있다
(현재 `ci.yaml`의 docker 게이트 8개가 정확히 그런 무회계 상태다).

### 회계 대상에서 제외한 것

- **메트릭 → 소비 알림 (G3)**: 기각. `pvc_dir_size_bytes`가 매일 수집되고 소비 알림·대시보드가
  0개인 것은 사실이나, "모든 메트릭에 소비자가 하나 있어야 한다"는 **참인 불변식이 아니다**(대시보드
  전용·ad-hoc 질의용이 정당하다). 거짓 불변식을 코드로 굳히면 예외 목록이 뒷문으로 돌아온다.
  개별 판단 티켓으로 분리.
- **가드 → traps 원장**: 스캔 리포트의 "12개 중 9개가 원장 밖"은 **잘못된 측정이었다**.
  `docs/traps.md:4-5`는 원장이 *가드*가 아니라 "가드로 강제된 **함정**"만 추적한다고 명시한다.
  라이브 함정이 아닌 불변식을 지키는 가드(`check-doc-index.sh` 등)는 원장에 없는 게 정상.

## 이동하는 호출 지점 (9)

| # | 호출자 | 현재 열거 | 이동 후 scope | 언어 |
|---|---|---|---|---|
| 1 | `tools/check-resource-limits.ts:44-47` | readdirSync + charts/barman 제외 | `platform-manifests` | TS |
| 2 | `tools/check-alert-rules.ts:648` | readdirSync(RULES_DIR) | `rules` | TS |
| 3 | `tools/check-alert-rules.ts:377-390` | walkProducers + SKIP_DIRS | `producers` | TS |
| 4 | `tools/audit-orphans.ts:56-58` | readdirSync(apps) | `apps` | TS |
| 5 | `tools/poll-ghcr.ts:192,204` | readdirSync(apps/platform) | `apps` + `platform` | TS |
| 6 | `tools/lib/surface-hash.ts:40-60` | 재귀 readdirSync | `apps` | TS |
| 7 | `scripts/check-image-pins.sh:110,146` | git ls-files + EXCLUDE_RE | `platform-manifests` + `apps-values` | 셸(CLI) |
| 8 | `scripts/check-app-deploy.sh:106` | `for d in apps/*/deploy/prod` | `apps` | 셸(CLI) |
| 9 | `scripts/check-skeleton.sh:42` | `for d in platform/*/` | `platform` | 셸(CLI) |

(`check-app-netpol.sh:20`은 `grep -rl`로 파일을 찾으므로 `apps` 유닛 열거 후 자체 필터로 전환.)

⚠️ #4(`audit-orphans`)와 #8(`check-app-deploy`)은 **같은 `apps` scope를 쓰되 의미론적 필터가 다르다**
(design-r1 R-1). `audit-orphans`는 `values.yaml` 있는 앱만 보면 되고, `check-app-deploy`는 `values.yaml`이
**없는** 앱을 잡아야 한다. 필터가 워커에 있으면 후자가 무력화되므로, **필터는 반드시 소비자 쪽에** 둔다.
이것이 scope 정의를 짤 때 매번 물어야 할 질문이다 — *"이 필터를 통과 못 한 항목이, 어떤 소비자에게는
찾아내야 할 위반은 아닌가?"*

## 마이그레이션 — 점진 + 차이 리포트

**호출자를 하나씩** 옮긴다. 호출자마다:

1. 워커 scope 열거 집합 vs 기존 열거 집합의 **차집합을 출력**한다 — **단언이 아니라 리포트**
2. 차이 0 → 교체
3. 차이 있음 → 각 항목이 **의도인지 사고인지 한 줄로 설명**하고, 의도면 scope 정의에 근거를 남긴다
4. 교체 후 패리티 스캐폴드는 **삭제**한다

패리티를 *단언*으로 걸면 안 된다. 제외 통일은 **의도적으로 동작을 바꾸는 일**이기 때문이다 —
예: `check-resource-limits.ts`는 현재 `tests/`·`fixtures/`를 제외하지 않아서, 픽스처 매니페스트가
`platform/` 아래 들어오면 그걸 상주 워크로드로 센다(지금은 그런 파일이 없어 안 터질 뿐). 단언이면
사람은 통과시키려고 scope를 옛 동작에 맞추게 되고 **개선이 원복된다**.

패리티 테스트를 영구 유지해서도 안 된다 — 옛 열거 로직을 테스트가 붙들게 되어 9벌 중복이 `tests/`로
이사할 뿐이다.

**순서**: 첫 호출자 = `check-resource-limits.ts`(이미 TS라 CLI 불요 · 이미 `MIN_SCAN=10`이 있어 열거
바닥값 설계의 참조 · 제외가 가장 느슨해 첫 차이 리포트가 곧바로 의미 있는 결정을 강제).
마지막 = `check-alert-rules.ts`의 producer walk(레포 전역이라 scope 정의가 가장 까다로움 —
앞 8개에서 어휘가 안정된 뒤).

## 살아남는 테스트

- **전부 살아남는다.** 각 가드의 기존 bats는 **불변식**을 검사하지 별 열거 방식을 검사하지 않는다.
  이게 이 심층화가 안전한 이유다 — 9개 가드의 불변식은 하나도 안 바뀐다.
- **새로 필요한 것**: `tools/tests/test_repo-walk.bats` — 픽스처 트리에 대해 scope별 열거·제외·
  열거 바닥값 동작. 워커 하나를 테스트하면 9개 호출자의 열거 정확성이 한 번에 증명된다.
  **필수 red-green 하나**: `apps` scope가 `values.yaml` 없는 앱 디렉토리를 **여전히 반환하는지**
  (design-r1 R-1 회귀 차단 — 이걸 거르면 `check-app-deploy`가 조용히 무력화된다).
- **삭제되는 것**: 각 호출자의 인라인 제외 로직과, 마이그레이션 중 만든 패리티 스캐폴드.
- **G1·G2의 가드 테스트**: `check-bats-accounting.sh` + `tools/tests/test_bats-accounting.bats`가
  형태의 참조. 단 **판정 술어가 다르다** — red-green 픽스처는 `0=고아 / 2+=이중소유`가 아니라
  **`권위 경로 0 = FAIL` / `권위 1 + 비권위 N = PASS`**를 증명해야 한다.
  특히 "비권위 경로가 여러 개여도 통과한다"는 케이스를 반드시 포함할 것 —
  초안의 `count == 1` 모델이면 `check-skeleton.sh`(ci.yaml + make verify)가 오탐이었다.

## 용어

⚠️ **"레인"을 쓰지 않는다.** `CONTEXT.md:14-23`이 이미 **배포 핀**의 레인(`apps 레인`/`베스포크 레인`)으로
그 단어를 점유한다. 워커의 스캔 슬라이스는 **"스코프(scope)"**다.

`CONTEXT.md`에 추가할 용어(설계 확정 후):
- **스코프 (scope)** — 워커가 열거하는 이름 붙인 저장소 슬라이스. 무엇을 뺄지·tracked인지 filesystem인지·
  열거 바닥값이 얼마인지를 함께 담는다. **의미론적 필터는 담지 않는다** — 그건 소비자의 것이다.
  _Avoid_: 레인(배포 핀 전용), 경로 집합
- **권위 경로 (authoritative path)** — 어떤 가드를 required check `gate`까지 실제로 이어주는 실행 경로.
  `make verify`·pre-commit 같은 mirror는 권위가 아니다(있어도 좋지만 판정에 안 들어간다).
  _Avoid_: venue(중립적이라 권위/비권위를 못 가른다), 실행처
- **권위 소유자 (authoritative owner)** — 어떤 아티팩트의 갱신을 책임지는 단 하나의 메커니즘.
  일반 갱신기가 그 파일에 *도달 가능*한 것과는 다르다(그건 freshness 채널).
  _Avoid_: 관리자, 소유 메커니즘
- **소유권 회계 (ownership accounting)** — 모든 항목이 **권위 있는 소유자/경로를 최소 하나** 갖는지
  계산하는 검사. 선언이 아니라 계산이다. `정확히 하나`는 도메인이 실제로 상호배타적임이 증명된
  경우에만 쓴다. _Avoid_: 커버리지 검사, 등록 확인

## 결정 기록 (grilling + design-r1)

| Q | 결정 | 기각한 것 |
|---|---|---|
| 1 | 공유 열거자(워커)가 심층화의 실체 | 회계 커널 — ③은 12줄, 커널화해도 복잡도가 이동만 함 |
| 2 | 한 module · 두 진입점(`walkManifests`/`listUnits`) | 단일 interface(9중 3만 서빙) · `resolveFiles`만(depth 없음) |
| 3 | 셸 가드는 얇은 CLI로 열거만 소비 | TS 이관(CONTRIBUTING이 허용한 것) |
| 4 | scope는 이름 붙인 고정 집합 | 조합 가능한 기술자(제외 어휘가 호출자로 되밀림) |
| 5 | 소유권은 계산한다, 선언하지 않는다 | `policy/` 레지스트리(같은 병 재생산) · 예외 목록 |
| 6 | G1(가드→권위 경로) + G2(아티팩트→권위 소유자) | G3 메트릭→소비자(참인 불변식이 아님) |
| 7 | 점진 + 차이 **리포트**(단언 아님), 스캐폴드는 삭제 | 빅뱅 · 영구 패리티 테스트 |
| **r1 R-1** | scope는 의미론적 필터를 담지 않는다 · 바닥값은 **열거 붕괴**만 본다 | 워커가 vacuity를 일괄 해소한다는 초안 주장 |
| **r1 R-2·R-3** | 술어 = **`authoritative >= 1`** | `count == 1`(mirror를 이중소유로, 미등록을 정상으로 오판) |
| **r2 R-4** | 권위 = **"불변식이 실제 도메인에 평가됐는가"** · owner-local은 권위 클래스 · skip-only bats는 비권위 | 권위를 venue 종류로 정의(skip 경로가 거짓 권위를 줌) |
| **r2 R-5** | Renovate가 권위 소유자인 곳엔 **차단성 적용성 검사** 필수(fail-closed + 센티넬) | Renovate를 전 도메인에서 비판정으로 강등(분류만으로 통과) |

### 초안에서 철회한 주장 3건 (다음 독자를 위해)

1. ~~"scan-floor를 워커가 강제하면 vacuous pass 3건이 한 번에 닫힌다"~~ — 워커 바닥값은 열거 붕괴만
   본다. `check-app-netpol`의 vacuity는 필터 이후에 생기고, 0이 정당할 수도 있다.
2. ~~"`check-credential-expiry.sh`는 고아다"~~ — cron 워크플로가 직접 호출한다. 스캔 리포트의 오류.
3. ~~"G2의 정확히-하나 계산이 D-1을 잡는다"~~ — 정확히 반대다. 등록된 4파일이 이중소유로 오탐되고
   누락된 2파일이 통과한다. D-1은 소유권 카운팅이 아니라 **권위 목록 완전성 검사**로 잡아야 한다.
