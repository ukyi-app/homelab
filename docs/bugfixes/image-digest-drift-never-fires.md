---
bugfix: image-digest-drift-never-fires
invariant-class: bugfix
entry-track: bug
review-track: full
pipeline-stage: done
issue-tracker: local
symptom: "ImageDigestDrift 알림이 60일간 한 번도 발화하지 않았다 — 드리프트 상태가 실제로 발생했는데도(app:image_digest_drift에 page 81샘플·trip-mate-api 84샘플) 통보가 0건이다. 배포 드리프트 감시견이 fail-open으로 죽어 있다."
red-baseline: f4497d23d5bc44e254dca736382d0472b8633ef5
bugfix-lock: green
first-increment: [B-1]
increments: [B-1]
spike-1:
---

# ImageDigestDrift가 구조적으로 발화 불가

## Root cause

`platform/victoria-stack/prod/rules/r6-ci-staleness.yaml`의 record `app:image_digest_drift`가
**push 메트릭** `ghcr_latest_digest`를 rollup 없이 **맨 참조**한다.

메커니즘 — 세 상수의 의미 불일치:

| 요소 | 값 | 출처 |
|---|---|---|
| digest-exporter push 주기 | **10m** | `digest-exporter.yaml` cron `*/10 * * * *` |
| vmalert instant 질의 룩백 | **5m** | `-datasource.queryStep` 미지정 → 기본 5m |
| 알림 `for:` | **20m** | 룰 파일 |

push 주기(10m) > 룩백(5m) → 매 주기 후반 5분간 메트릭이 vmalert 눈에서 **사라진다** →
기록룰 시리즈에 구멍 → `for: 20m` pending이 매 주기 리셋 → **20분을 누적할 수 없다** →
어떤 드리프트에도 발화 불가.

**라이브 실측(진단 근거)**:
- `count_over_time(ALERTS{alertname="ImageDigestDrift",alertstate="firing"}[60d])` → 빈 결과.
  대조군 15개 알림은 firing 시리즈 정상 기록 → 기록 경로는 살아있고 **이 알림만** 발화 불가.
- `count_over_time(app:image_digest_drift[60d])` → page 81샘플·trip-mate-api 84샘플 →
  감시 대상 상태는 실제로 발생했는데 무발화.
- instant 질의 재현: push+60초→시리즈 2개, +240초→2개, **+360초→0개, +540초→0개**.

**프로세스 갭**: 룰 주석에 작성자가 `⚠️ 라이브 미검증 죽은 식 → 발화 검증 필수`라고 스스로
적어뒀으나 그 검증이 수행되지 않았다. required `vmalert -dryRun` 게이트는 **파싱만** 하고,
이 결함 표현식은 문법적으로 유효한 MetricsQL이라 통과했다.

## The fix

기록룰 좌변에 rollup + **우변 존재 가드**. 우변 파드 셀렉터 자체(label_replace 2단)는 무변경.

```
  max by (app, digest) (last_over_time(ghcr_latest_digest[15m]))    ← ① rollup(근본원인)
  unless on (app, digest) (POD)                                     ← (무변경)
  and on (app) (POD_BY_APP)                                         ← ② 우변 존재 가드(P-1)
```

**① rollup** — 근본원인(읽는 쪽의 의미 불일치)을 **읽는 문장 안에서** 해소한다. 레포 선례로의
복귀이기도 하다: `r4-storage-backup.yaml`이 같은 함정을 이미 6번 방어한다(`last_over_time(m[W])`),
r6만 규약을 안 지켰다.

**② 우변 존재 가드 — 플랜 게이트 P-1이 잡은 필수 동반 변경.** rollup만 넣으면 좌변이 **연속**이
되므로, KSM/스크레이프 장애로 우변(`kube_pod_container_info`)이 사라지면 `unless`가 아무것도 제거하지
못해 **전 앱이 20분 뒤 발화**한다 — 그것도 "실행 중인 이미지가 최신 GHCR digest와 불일치"라는 **거짓
사유**로(진실은 "KSM이 죽었다"). 이는 `absent()` 가드를 기각한 것과 **똑같은 원인 오귀속**이며,
현재 행위(좌변이 구멍나서 무발화)에 없던 **두 번째 페이징 조건**이다.

가드는 "해당 app에 **지금 파드 텔레메트리가 있을 때만** 드리프트를 주장한다"를 강제한다 →
KSM 장애 시 **오늘과 동일하게 침묵**(KSM 사망 자체는 `TargetDown`이 이미 페이징한다).
즉 가드는 새 행위 추가가 아니라 **단일 flip 유지를 위한 보존 장치**다.

> ⚠️ 가드 없는 rollup은 **단일 flip 계약 위반**이다. 이 둘은 분리 불가능한 한 덩어리다.
> 실측 증명: 가드 없는 `[15m]` rollup으로 L7을 돌리면 **KSM 장애 중 전 앱이 firing 191샘플**로
> 오발화한다(하네스가 잡음). 가드를 넣으면 record 시리즈 자체가 0이 되어 침묵한다.

### 검증된 최종 표현식 (하네스 8레그 GREEN 확인)

```promql
max by (app, digest) (last_over_time(ghcr_latest_digest[15m]))
unless on (app, digest) (
  label_replace(
    label_replace(
      kube_pod_container_info{namespace="prod", image_id=~"ghcr[.]io/ukyi-app/.*"},
      "digest", "$1", "image_id", ".*@(sha256:[a-f0-9]+)$"
    ),
    "app", "$1", "image_id", ".*/([a-z0-9-]+)[@:].*"
  )
)
and on (app) (
  max by (app) (
    label_replace(
      kube_pod_container_info{namespace="prod", image_id=~"ghcr[.]io/ukyi-app/.*"},
      "app", "$1", "image_id", ".*/([a-z0-9-]+)[@:].*"
    )
  )
)
```

- `unless`/`and`는 동일 우선순위·좌결합 → `(좌변 unless POD) and POD_BY_APP` = 의도한 결합.
- 가드 우변은 **존재 확인**만 하므로 digest 추출 단계가 없다(app 추출 1단). `max by (app)`로 app당
  1 시리즈로 집계해 조인을 명확히 한다.
- 우변 파드 셀렉터에 **rollup 없음**(보존 계약 #5) · **새 recording rule 없음**(eval 순서 의존 회피).

### 왜 W = 15m인가 (양방 제약)

`push(10m) ≤ W < for(20m)`.

- **하한 = push 주기**: W < 10m이면 구멍이 그대로 남는다.
- **상한 = `for: 20m`** — 이게 이 픽스의 비직관적 핵심이다. rollup 윈도는 "최근 W 안에 본 digest를
  지금의 latest로 되살리는 **상태 래치**"다. 이미지 bump 후 구 digest가 W 동안 되살아나는데,
  그 잔존이 `for`를 넘기면 **bump마다 오발화**한다. 하네스 L8이 매 실행 실증(W=30m → phantom 발화).

  > **정정(plan-gate P-2 후 산술 재유도)**: phantom 지속시간을 최악 순서에서 유도하면
  > `phantom = W − lookback`이고, 따라서 **실제 발화 임계는 `W > for + lookback`(= 25m)** 이지
  > `W > for`(20m)가 아니다. 즉 **20~25m 구간은 관측으로 잡히지 않는다**(W=20m은 phantom 15m이라
  > L3를 통과해버린다). 그래서 `W < for`는 **보수적 정책**이고, 하네스는 이를 **preflight 산술로**
  > 강제한다(관측 레그가 구조적으로 볼 수 없는 경계를 닫는다). L3(음성)·L8(양성)·preflight(산술)는
  > 상보적이며 셋 다 필요하다.
- **15m 선택**: 하한·상한 마진을 5분씩 균등화하는 중점. 실측상 push 간격은 30일간 1370건이 정확히
  10.00m, 누락 1회(20.00m)뿐이라 12/15/18은 하한에서 동률이고, 상한에서는 라이브 bump 빈도가
  높아(trip-mate-api 10일 23회) 18m의 2분 마진은 언젠가 터진다.
- **감내하는 비용(명시 수용)**: push 1회 누락(30일 1회) 시 gap 20m > W → 5분 구멍 → 진행 중이던
  pending 리셋 → 페이지 최대 ~25분 지연. 드리프트는 **지속 상태**라 침묵이 아니라 **유한 지연**이며,
  W ≥ 20m은 상한 제약상 구조적으로 금지되므로 이는 선택이 아니라 불가피다.

### r4의 `[2h]`/`[3d]`와 왜 다른가 (룰 주석에 남길 규칙)

- **r4 = staleness 알림**: `time() - last_over_time(m[W]) > threshold`. **값이 타임스탬프**이고 판정도
  값으로 한다. 윈도는 "마지막 하트비트를 어디까지 뒤질까"라는 탐색 지평일 뿐 → **상한 없음**.
- **r6 = state/identity 알림**: 값은 무의미한 1이고 **시리즈의 존재와 `digest` 라벨 자체가 상태**다.
  윈도는 상태 래치라 넓으면 구·신 digest를 동시에 latest라 주장 → 오발화 → **윈도는 `for:` 미만**.

> 한 줄 규칙: **타임스탬프-값 하트비트 → 윈도 상한 없음. 라벨-값 상태 게이지 → 윈도 < `for:`.**

### 기각한 대안

| 안 | 기각 사유 |
|---|---|
| (B) cron `*/10`→`*/2` | 알림 생존이 vmalert의 **문서화되지 않은 기본 상수 5m**에 의존하게 된다(Renovate가 업스트림을 올리면 조용히 재고장 = fail-open by construction). 또 회귀 테스트의 preflight(`룩백 < push`)를 무너뜨려 **RED를 고정한 seam을 버려야만 성립**한다. skopeo 호출 5배·Job 오브젝트 720개/일. |
| (C) `-datasource.queryStep=15m` | vmalert의 **모든 instant 질의**에 적용 → 41개 룰 전체 행위 변경. `absent()` fail-closed 가드 9개가 일제히 10분 둔해지고(감시견 1개 살리려 9개를 늦추는 거래), 모드 B(422) 노출창이 3배가 된다 — 이 레포에서 4번 재발한 바로 그 클래스. |
| (D) vmsingle `-search.maxStalenessInterval` | 룩백은 **질의별 파라미터**임이 하네스로 실증됐다(URL `?max_lookback` 주입 없이는 버그가 재현조차 안 된다) → 증상을 고친다는 증거가 없다. blast radius는 (C)보다 넓다(Grafana·애드혹 질의·전 range 질의). |

## Single-Flip Contract

**뒤집히는 관측 행위(정확히 1개)**:
> 지속 드리프트가 존재해도 `ImageDigestDrift`가 **발화하지 않는다** → **발화한다**.

**변경 표면(`scope[]`)**: `platform/victoria-stack/prod/rules/r6-ci-staleness.yaml` 단일.

`flips[]`는 이 **같은** 행위의 증인 1개(L1). 두 번째 관측 행위는 이 파이프라인에 들어오지 않는다.

### ⚠️ `absent()` fail-closed 가드는 의도적으로 **제외**한다

r6에는 digest-exporter staleness 알림이 **없다**. record 룰에 `or absent(...)`를 넣으면
"exporter 사망 → 무발화"가 "exporter 사망 → 페이징"으로 뒤집힌다 — 버그의 flip과 **논리적으로 독립**인
**두 번째 관측 행위**이고, L1을 GREEN으로 만드는 데 **전혀 필요 없다**(하네스가 rollup만으로 증명).

게다가 넣으면 **거짓말하는 페이지**가 나간다: `absent()`가 만드는 시리즈는 라벨이 비어 있어
`ImageDigestDrift`가 `{{ $labels.app }}` 없이 *"실행 중인 이미지가 최신 GHCR digest와 불일치: "* 를
보낸다 — 진실은 "exporter가 죽었다"인데 **원인을 오귀속**한다. 레포도 이미 같은 원칙을 문서화했다
(`test_vmalert-config.bats:82`: "per-rule absent()를 붙이면 메트릭 부재를 'SSD 여유 부족' critical로
오귀속"). 올바른 형태는 별도 alertname(`DigestExporterStale`) → **후속 F-1**.

## Preserved Contract

| # | 보존 대상 | 이를 못박는 것 |
|---|---|---|
| 1 | `ArgoCDOutOfSync` 전체(expr·`absent(argocd_app_info)`·for: 15m) | 하네스 **L6**(매 실행 발화 증명) + `test_vmalert-config.bats` |
| 2 | `ImageDigestDrift` 알림 룰 — `== 1`, **`for: 20m`**, severity, alert명, annotations.summary | **`for:`는 절대 손대지 않는다**(anti-cheat 1순위이자 하네스 preflight 산술의 입력) |
| 2b | ⚠️ **의도적 예외 — `annotations.description`은 고친다**(아래 공개 참조) | 구조 게이트 판단 대상 |
| 3 | 드리프트 없을 때 무발화 | 하네스 **L2** |
| 4 | 이미지 bump 직후 무발화 | 하네스 **L3** (W < `for` 강제) |
| 5 | **우변 파드 셀렉터 무변경** — `kube_pod_container_info{...}` + `label_replace` 2단. **우변에 rollup 금지** | 여기에 rollup을 붙이면 **구 파드 digest가 되살아나 진짜 드리프트를 억제**한다(같은 fail-open의 거울상) |
| 5b | **KSM/스크레이프 장애 시 무발화**(오늘의 행위) | **하네스 L7 신설**(P-1) — 우변 텔레메트리 부재 시 ImageDigestDrift 시리즈 0. 우변 존재 가드가 이를 보존한다. KSM 사망 자체는 `TargetDown`이 페이징 |
| 5c | **`for: 20m`**(페이징 임계) | 하네스 preflight가 `for`를 파싱해 못박는다(P-2) — 낮추면 페이징이 빨라지는 행위 변경 |
| 6 | record명·alert명 | 하네스 fail-closed grep(리네임 시 "아무것도 측정하지 않는다"로 즉시 실패) |
| 7 | `check-alert-rules`(모드 A/B, 41룰) | **실측 OK** — `last_over_time`은 ROLLUP 목록 밖(모드 A 무관), `unless on(...)`은 SET_OP로 스킵(모드 B 무관) |
| 8 | `vmalert -dryRun` | **실측 통과** |
| 9 | digest-exporter 매니페스트(authfile·netpol·APPS parity·curl push) | 무변경 |
| 10 | vmalert/vmsingle 배포·플래그·메모리 원장 | 무변경(알림 엔진 재시작 없음) |

### ⚠️ 정직한 공개: characterization 테스트 1개를 **수정해야 한다**

`tests/gates/test_digest-exporter.bats`가 버그 표현식의 **문자열을 리터럴로 못박고 있다**:

```bash
grep -q 'max by (app, digest) (ghcr_latest_digest)' "$R"   # 좌변 digest 보존
```

픽스 후 이 문자열은 사라진다 → **실측 확인: FAIL 확정**. characterizationCmd에 포함돼 있으므로
피할 수 없다.

**판정: 이 단언은 *행위*가 아니라 *구문*을 못박은 과잉명세다.** 주석이 밝힌 의도는 "좌변이 `digest`
라벨을 떨구지 않는다 = 조인 양변 정렬"이고, 픽스는 그 계약을 **완전히 보존**한다
(`max by (app, digest)` 그대로). 따라서 **의도는 유지하고 커버리지는 넓히는** 편집으로 바꾼다.

**교체 단언(플랜 게이트 P-3 → r2 재지적까지 반영한 최종형)**:

```bash
# ① $R은 ConfigMap — 룰 YAML은 .data["r6.yaml"]에 문자열로 박혀 있다(.spec.groups 아님!)
EXPR="$(yq '.data["r6.yaml"]' "$R" \
        | yq '.groups[].rules[] | select(.record == "app:image_digest_drift") | .expr')"
[ -n "$EXPR" ]                                                          # 추출 실패 = 즉시 FAIL(빈 문자열 false-green 차단)

grep -qE 'max by \(app, digest\) \(' <<<"$EXPR"                         # 좌변 digest 라벨 보존(조인 정렬)
grep -qE 'last_over_time\(ghcr_latest_digest\[[0-9]+m\]\)' <<<"$EXPR"   # push 메트릭에 rollup 착용

# ② 부정 단언은 ghcr_latest_digest **주변으로 좁힌다** — 넓게 쓰면 P-1 가드의 정당한
#    `max by (app) (label_replace(kube_pod_container_info…))`까지 잡아 가드를 못 넣게 된다
# ③ 중간 부정(`! grep`)은 이 레포가 bats false-green으로 검출하는 함정 → run + status로
run grep -qE 'max by \(app\) \([^)]*ghcr_latest_digest' <<<"$EXPR"      # 파손식(좌변 digest 소실) 금지
[ "$status" -ne 0 ]
```

> **P-3 교정 이력(2라운드)**:
> - **r1 지적(confidence 1.0)**: 최초 부정 단언이 `run grep -qE '…'`에 **대상 인자 `"$R"`을 빠뜨려**
>   stdin을 읽었다 → EOF로 항상 non-zero → **룰 내용과 무관하게 통과하는 vacuous 단언**. "강화"라던
>   줄이 실은 아무것도 검사하지 않았다.
> - **r2 지적(3중)**: ㉠ `$R`은 ConfigMap이라 `.spec.groups[]` 경로가 **빈 EXPR**을 낳아 긍정 단언이
>   영구 실패(characterization 영구 RED) → `.data["r6.yaml"]` 추출 후 `.groups[].rules[]` 파싱 +
>   **비어있지 않음 단언** 필수. ㉡ 넓은 부정 패턴이 **P-1 가드의 정당한 `max by (app) (`를 매치** →
>   통과시키려면 가드를 빼야 하고 그러면 P-1이 재발(테스트가 결함을 강요) → `ghcr_latest_digest`
>   주변으로 좁힌다. ㉢ 맨 `! grep` 중간 부정 = 레포가 명시 검출하는 bats false-green → `run`+`status`.
> - **전부 수용**. 위 최종형이 세 지적을 모두 반영한다.

세 번째 줄이 요점이다 — **현재의 리터럴 단언은 픽스 후 오히려 약해진다**
(`max by (app) (last_over_time(...))`라는 파손식을 못 잡는다). 위 형태로 바꾸면 가드가 **강해진다**.
즉 테스트 약화가 아니라 **강화**다. 구조 게이트의 anti-cheat 렌즈에 이 논거를 제출한다.
(B4 배리어상 `tests/` 경로는 non-test scope 검사에서 제외되므로 `scope[]` 변경은 불필요.)

### ⚠️ 의도적 예외 공개 — `annotations.description`의 stale 문구를 고친다

Preserved Contract는 원래 "annotations 무변경"을 약속했다. 그러나 컨덕터측 code-review(Standards 축)가
잡았다: 현재 description이 이렇게 말한다.

> `⚠️ 이미지 bump 직후 digest-exporter APPS 갱신 전까지 일시 오발화 가능(B9 bump-tag 배선 후 해소).`

**픽스 후 이 문장은 거짓이다.** bump phantom은 이제 rollup 윈도 불변식(`W < for`)이 관장하고,
L3(음성)·L8(양성)·preflight(산술)가 회귀로 막는다. 이 문구를 그대로 두면 **온콜에게 "무시해도 되는
일시 알람"이라고 오도**한다 — 60일간 죽어 있던 감시견을 살리면서, 그 감시견이 짖을 때 무시하라고
적어둔 채 배포하는 셈이다. 안전 관련 결함이라 판단해 **고친다**.

- 바뀌는 것: `annotations.description`의 phantom caveat 문장 → "발화하면 실제 드리프트다 + 윈도
  불변식이 bump phantom을 막는다"로 교체.
- **바뀌지 않는 것**: `summary`·`severity`·`for: 20m`·alert명·record명·expr 판정 조건.
- **왜 flip이 아닌가**: 알림의 **발화 조건**은 그대로다(단일 flip 유지). 바뀌는 것은 발화 시 전달되는
  설명 문구뿐이고, 그 문구는 새 행위를 **정확히 기술하도록** 고치는 것이다. 어떤 테스트도 약화되지
  않고 증상 특수처리도 아니다.
- 구조 게이트의 anti-cheat 렌즈에 이 판단을 그대로 제출한다.

### 윈도·`for` 불변식을 **기계로 강제한다** (플랜 게이트 P-2 교정)

게이트 지적: 하네스가 W를 추출·비교하지 않고 `FOR`를 **가변 룰에서 파생**하므로, `for: 15m`으로
바뀌거나 W=20m이어도 L3를 통과할 수 있다 — 즉 **주장한 불변식이 강제되지 않는다**. 수용하고 3중으로 막는다:

1. **하네스 preflight가 파싱·단언**: 룰 expr에서 W, cron에서 push, 룰에서 `for`를 파싱해
   `push ≤ W < for`를 단언. 위반 시 **HARNESS FAULT로 즉시 실패**(룰 판정이 아니라 전제 붕괴로).
2. **`for: 20m`을 characterization에 못박는다** — `for`를 낮추면 페이징이 빨라지는 **행위 변경**이므로
   조용히 통과시키면 안 된다.
3. **과대 윈도 증인 레그 추가**(L8): 결함 픽스처로 W=30m(= `for` + 룩백 초과)을 넣어 **phantom 발화가
   실제로 관측됨**을 매 실행 증명 → L3가 상한에서 이빨을 갖고 있음이 회귀로 고정된다.
   (수동 1회 관측 `[30m]`→FAIL은 증거이지 게이트가 아니다.)

## Regression test (already RED at red.sha)

- **seam**: hermetic vmalert replay e2e 게이트 — `tests/gates/vmalert-drift-firing-e2e.sh`(69초).
  배포 ConfigMap에서 룰을 **바이트 그대로** 추출(`for: 20m` 무변형), 합성 드리프트를 심어
  `ALERTS{alertname="ImageDigestDrift",alertstate="firing"}` 시리즈의 부재/존재를 직접 단언.
  버전·룩백·push 주기는 매니페스트에서 파생(하드코딩 0). required `gate` 잡에 배선됨.
- **regressionCmd**: `bash tests/gates/vmalert-drift-firing-e2e.sh`
- **symptomToken**: `ImageDigestDrift did not fire despite`
- **RED 기록**: `docs/reviews/image-digest-drift-never-fires/bugfix-verify-red-e46ee376….json`
  (스크립트 재실행 증명: regression exit=1·symptomTokenPresent=true·characterization green=true) @ `736eeb1`
- **하네스가 매 실행 자기 이빨을 증명한다**: L4(결함 표현식 픽스처 거부)·L5(rollup 밖 `or absent()`
  가짜 픽스 거부)·L6(대조 알림 발화 = 하네스 생존). ⚠️ **naive replay는 거짓 GREEN**이다
  (range 질의가 10분 push를 보간해 버그 룰이 firing 191로 통과) → datasource URL에 `max_lookback`을
  주입해 라이브 instant-query 룩백을 복원해야 RED가 재현된다.

### 플랜 게이트 후 하네스 하드닝 (red-capture 재캡처)

플랜 게이트 P-1/P-2를 수용해 **픽스 전에** 하네스를 보강한다(룰은 여전히 무변경 = 여전히 RED).
`red.sha`는 보강 커밋으로 **재고정**하고 `--verify-red`를 다시 돌린다.

| 레그 | 시나리오 | 기대 | 왜 |
|---|---|---|---|
| **L7 (신설)** | 지속 드리프트 + **우변 텔레메트리 소실**(KSM 장애: `kube_pod_container_info` 없음) | ImageDigestDrift **무발화** | P-1. 가드 없는 rollup은 여기서 전 앱 오발화 → 이 레그가 잡는다. baseline에서도 통과(오늘도 무발화) |
| **L8 (신설)** | 결함 픽스처 W=30m(= `for`+룩백 초과) + 이미지 bump | phantom **발화가 관측됨** | P-2. L3가 상한에서 이빨을 갖고 있음을 매 실행 증명(수동 1회 관측을 게이트로 승격) |
| **preflight (신설)** | 룰 expr에서 W·`for`, cron에서 push 파싱 | `push ≤ W < for` 위반 시 **HARNESS FAULT** | P-2. 주장한 불변식을 기계가 강제 |

## Increment plan

| id | what the fix does here | blocked-by | notes |
|---|---|---|---|
| B-1 | ① 기록룰 좌변 `last_over_time([15m])` rollup + ② **우변 존재 가드**(KSM 장애 시 오발화 방지 — 단일 flip 유지에 필수) + ③ 윈도 불변식(`push ≤ W < for`)·r4 비대칭 규칙을 룰 주석에 명시 + ④ `test_digest-exporter.bats`의 과잉명세 grep을 yq-추출 계약 단언으로 강화(P-3 교정 반영) | none | first-increment. 표현식 1개의 결합된 변경이라 단일 증분 |

**검증**: L1이 RED→GREEN으로 뒤집히고 **L2~L8 GREEN 유지**(L4/L5/L8 픽스처는 결함 상태로 **동결** —
절대 갱신 금지) + characterizationCmd 전건 GREEN.

## Follow-up backlog

- **F-1 (net-new 발화 조건 → gated-pipeline/별도 bugfix)**: `DigestExporterStale` 신설 —
  r4 관용구(`absent(last_over_time(ghcr_latest_digest[30m]))`, `for: 15m`, warning)로 **별도 alertname**.
  liveness 알림이므로 W > `for`가 허용된다(위 비대칭 규칙). 동반: digest-exporter의 조용한 실패
  경로를 fail-loud로 — `DIGEST=$(skopeo … || true)` + `[ -z "$DIGEST" ] && continue`(앱 무성 skip),
  `curl … || echo "push failed" >&2`(push 실패해도 Job 성공) → **ghcr-read 토큰 만료·GHCR 장애·
  vmsingle write 실패 시 Job은 초록인 채 시리즈만 사라진다**. `KubeJobFailed`는 이 침묵 경로를 못 잡는다.
- **F-2**: `check-alert-rules` 모드 C — push 메트릭을 rollup/absent 가드 없이 참조하면 FAIL(정적 lint).
  이 클래스의 유일한 실효 방어(`vmalert -dryRun`은 파싱만). 레포 선례와 동형(룰 #327 / 린터 #328 / 원장 #329).
- **F-3**: `FilesBulkSSDLow`(`r4-storage-backup.yaml:158`) 동일 클래스 사망 의심 — rollup·absent 없이
  push 메트릭 참조 + `for: 30m`. 사실이면 외장 bulk SSD가 꽉 차도 영원히 페이징되지 않는다. **미검증** —
  착수 전 독립 실측 필요. 별도 gated-bugfix(여기서 고치면 두 번째 flip).
- **정리 완료(기록)**: red-capture 스파이크가 라이브 vmsingle TSDB에 합성 시리즈를 import했다
  (`ghcr_latest_digest{app=page,digest=sha256:aaaa…}` 2샘플 + 합성 pod info 1 + 그로부터 파생된
  `app:image_digest_drift`/`ALERTS(pending)`). 발화·통보는 없었다. **사용자 승인 후 digest 라벨 완전일치
  매처로 정밀 삭제 완료**(잔존 0, 실제 시리즈 무사 확인). 커밋된 게이트는 hermetic(docker 전용, 라이브
  참조 0)이라 재발 경로 없음.

## Review Decision Log

### Codex Plan Review — r1 (verdict: needs-attention, 3 findings)

| ID | Finding | Severity | Decision | Reason | Action |
|----|---------|----------|----------|--------|--------|
| P-1 | RHS telemetry loss becomes a second, mislabeled paging condition | high | **Accept** | 정확하다. rollup으로 좌변이 연속이 되면 KSM/스크레이프 장애 시 `unless`가 아무것도 제거하지 못해 **전 앱이 20분 뒤 발화**한다 — 그것도 "이미지 불일치"라는 거짓 사유로. 이는 오늘 없던 두 번째 페이징 조건이며, 내가 `absent()` 가드를 기각한 것과 **똑같은 원인 오귀속**이다. 내 픽스가 내 논리에 걸렸다. | 픽스에 **우변 존재 가드** 추가(단일 flip 유지를 위한 보존 장치) + 하네스 **L7**(우변 소실 → 무발화) 신설. 가드 없는 rollup은 계약 위반으로 명시 |
| P-2 | L3 does not enforce the claimed window / for invariants | medium | **Accept** | 하네스가 W를 파싱하지 않고 `for`를 가변 룰에서 파생하므로 `for: 15m`이나 W=20m도 통과할 수 있다 — 주장한 불변식이 강제되지 않는다. | preflight가 W·push·`for`를 파싱해 `push ≤ W < for`를 단언(위반 시 HARNESS FAULT) + `for: 20m` characterization 고정 + **L8**(과대 윈도 결함 픽스처 → phantom 발화 관측) 신설 |
| P-3 | The planned negative characterization never reads the rule file | medium | **Accept** | confidence 1.0으로 정확. `run grep -qE '…'`에 `"$R"`을 빠뜨려 stdin을 읽고 EOF로 항상 non-zero → 룰 내용과 무관하게 통과하는 **vacuous 단언**. "강화"라던 줄이 실은 아무것도 안 했다. | `yq`로 `app:image_digest_drift` **expr만 추출**해 판정(주석·타 표현식 오염 차단) + 모든 grep에 대상 명시. 긍정 2 + 부정 1 단언 |

**엔진 노트(수용)**: "No materially simpler safe fix than a left-side rollup was found" — 대안 기각 근거는 유지된다.

### Codex Plan Review — r2 (verdict: needs-attention, 1 finding)

**P-1·P-2 해소 확인**(엔진 원문: "P-1 and P-2 are resolved, and the RED record matches f4497d2 and the
exact firing symptom"). 잔여 1건:

| ID | Finding | Severity | Decision | Reason | Action |
|----|---------|----------|----------|--------|--------|
| P-3′ | P-3 characterization cannot accept or reliably validate the planned rule | medium | **Accept** | 3중으로 정확하다. ㉠ `$R`은 ConfigMap이라 `.spec.groups[]`는 빈 EXPR → 긍정 단언 영구 실패(characterization 영구 RED). ㉡ 넓은 부정 패턴이 **P-1 가드의 정당한 `max by (app) (`를 매치** → 테스트를 통과시키려면 가드를 빼야 하고 그러면 P-1이 재발한다(테스트가 결함을 강요하는 최악의 형태). ㉢ 맨 `! grep` 중간 부정은 레포가 bats false-green으로 검출하는 함정. | 위 "교체 단언 최종형"으로 교정: `.data["r6.yaml"]` 추출 + 비어있지 않음 단언 + 부정 패턴을 `ghcr_latest_digest` 주변으로 좁힘 + `run`/`status` |

### 컨덕터측 code-review — B-1 (Spec: 통과 / Standards: 하드 위반 0, 지적 3건 수용)

| ID | Finding | 축 | Decision | Action |
|----|---------|-----|----------|--------|
| CR-1 | 중복된 파드 셀렉터 계약이 **무가드** — `label_replace(kube_pod_container_info…)`가 `unless` 우변과 `and` 가드에 바이트 쌍둥이로 존재하는데, 한쪽만 고치면 **가드의 app 집합이 조용히 좁아져 진짜 드리프트를 억제**한다(고치려던 fail-open의 재발 경로) | Standards | **Accept** | bats에 쌍둥이 단언 추가(app-추출 label_replace occurrence == 2 + 두 셀렉터 문자열 동일). 중복 자체는 유지 — 대안(새 recording rule=eval 순서 의존 / 우변 rollup=fail-open 거울상)이 더 나쁘다 |
| CR-2 | `annotations.description`의 phantom caveat이 **stale** — 픽스 후 거짓이 되어 온콜을 오도 | Standards | **Accept**(의도적 예외) | 위 "의도적 예외 공개" 참조. 발화 조건 무변경이라 단일 flip 유지 |
| CR-3 | 새로 라이브 확증된 함정 2건이 **`docs/traps-detail.md` SSOT·`docs/traps.md` 원장에 미등록**(레포 규약 위반) | Standards | **Accept** | traps-detail 섹션 2개 + AGENTS 인덱스 2줄 + 원장 행(guard=`tests/gates/vmalert-drift-firing-e2e.sh`). `make verify-traps` 통과 필수. 겸사겸사 r6 룰 주석을 불변식+포인터로 압축(지식이 두 사본으로 갈리는 것 방지) |

### Codex Release Review — r1 → r2

| ID | Finding | Severity | Decision | Reason | Action |
|----|---------|----------|----------|--------|--------|
| R-1 | Inconsistent verify-record — 기록이 `symptomTokenPresent: true`를 주장하는데 bounded `outputTail`(마지막 2000자)이 토큰을 반토막 내 **증거에 토큰이 안 보인다** | high (conf 1.0) | **Accept** | 판정 자체는 옳았다(토큰 검사는 전체 출력 기준). 문제는 **감사 가능성** — 아티팩트가 자기 검증되지 않으면 anti-forgery 일관성 검사를 통과할 수 없다. 8레그로 출력이 길어진 결과다. | 아티팩트 손수정 금지 지시 준수: **하네스는 바이트 동결**한 채 락의 `regressionCmd`가 출력 전문 후 **실패 레그 줄을 맨 끝에 재출력**하도록 감쌈(exit 코드 그대로 전달, 단언 무변경) → `--verify-flip` 재실행 → RED tail이 토큰 포함 줄로 종료. 폐기된 red.sha의 stale 기록도 삭제 |

**r2: clean — verdict approve, 0 findings — "Ship."** 원문: "the RED tail contains the exact symptom token
with exit 1, GREEN shows harness success with exit 0, both characterization runs remain green,
ancestry/tree SHAs match, and the harness blob is unchanged. The wrapper only re-emits harness-produced
FAIL lines and exits the saved harness status, so it preserves machine-owned flip semantics."

### Landing (2026-07-12)

- **머지 ref**: `a6d9c61` — PR [#339](https://github.com/ukyi-app/homelab/pull/339) squash 머지
  (required check `gate` 통과 후 auto-merge). strict 보호라 rebase 대신 `gh pr update-branch`로 base 흡수
  (rebase는 SHA를 재작성해 red.sha/green.sha 락과 게이트 reviewedSha를 통째로 무효화한다).
- **배포**: ArgoCD `victoria-stack` Synced/Healthy @ `a6d9c61` → r6 ConfigMap에 새 룰 반영 확인.
- **라이브 검증**: 아래 `docs/reviews/…/state.md`의 "라이브 검증" 절 참조.
- **증분**: B-1 done(단일 증분). 스파이크 0. `[DEBUG-]` 계측 0.

### Codex Structure Review — r1: clean — verdict **approve**, 0 findings

원문: "The 15m rollup fixes the cadence/lookback mismatch at the correct rule seam, while the RHS guard
preserves silence during telemetry loss. The RED harness and frozen fixtures are byte-identical through
the fix, characterization was not weakened, scope is contained, and no material coupling blocks the
follow-ups." → **의도적 예외 2건(annotations.description 교체 · docs를 scope에 포함) 모두 수용**.

**2라운드 캡 도달 → 인간 트리아지**: 잔여 P-3′는 플랜 **산문의 단언 스니펫** 결함이고, 실제 계약은
B-1 구현이 작성하는 bats 코드다. 그 코드는 (a) characterizationCmd로 **매 증분 실행**되므로 추출
경로가 틀리면 즉시 RED로 잡히고, (b) 부정 패턴이 가드를 잡으면 올바른 픽스에서 RED가 되어 역시 잡히며,
(c) **구조 게이트가 실제 diff를 anti-cheat 렌즈로 재심사**한다. 즉 이 잔여 결함은 기계 루프가
fail-closed로 봉쇄한다. 사용자 승인 하에 r3 없이 executing으로 진행한다.
