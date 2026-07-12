---
feature: digest-exporter-stale
invariant-class: feature
entry-track: feature
review-track: full
pipeline-stage: prd-gate
issue-tracker: local
prd-published: false
skeleton-issue: []
structure-gate: pending
issues: []
---

# digest-exporter 자기관측 — 하트비트 + 수집 카운트 + staleness 알림

## Problem Statement

**감시견의 감시견이 없다.** 이번 세션에 죽은 알림 2건을 살렸지만(ImageDigestDrift #339 ·
FilesBulkSSDLow #341), 살려낸 `ImageDigestDrift`의 **먹이 공급선인 digest-exporter 자체가
자기 생존을 알리지 않는다**.

`platform/victoria-stack/prod/digest-exporter.yaml`(CronJob `*/10`)의 조용한 실패 3모드 —
모두 **초록 Job(exit 0)** 으로 통과한다:

| 모드 | 코드 | 결과 |
|---|---|---|
| skopeo 실패(GHCR 장애·`ghcr-read` 토큰 만료) | `DIGEST=$(skopeo … \|\| true)` + `[ -z "$DIGEST" ] && continue` | 그 앱만 조용히 스킵 |
| push 실패(vmsingle 장애·네트워크) | `curl … \|\| echo "vmsingle push failed" >&2` | Job은 여전히 exit 0 |
| CronJob 미실행(스케줄러·노드 문제) | — | 메트릭 전체 정지 |

`KubeJobFailed`(core.yaml)는 `kube_job_failed{condition="true"}`만 보므로 **초록 Job을 원리적으로
못 잡는다.** 그리고 `ghcr_latest_digest` 시리즈가 끊기면, ImageDigestDrift의 기록 룰은
`last_over_time(ghcr_latest_digest[15m])`이라 **마지막 성공 push + 15분**부터 좌변이 빈 벡터가 되어
**조용히 실명**한다. 아무도 페이징하지 않는다 — 원래 버그(60일간 발화 0)와 **같은 실패 양식의
2차 실명**이다.

겪는 사람: owner(단독 운영자). 증상이 없다는 것이 바로 이 버그 클래스의 정의다.

## Solution

exporter가 **같은 push 본문에** 자기관측 메트릭 3개를 함께 실어 보내고, 그 위에 알림 2건을 세운다.

1. **하트비트**(타임스탬프 값) — "push 경로가 살아 있다"를 증명한다. 크론 미실행·push 실패는
   하트비트 미적재로 나타난다(같은 curl 페이로드에 실리므로 **fail-closed**).
2. **수집 카운트 2개**(설정 앱 수 / skopeo 성공 앱 수) — "GHCR 수집이 성공했다"를 증명한다.
   push는 됐는데 앱 절반(또는 전부)이 skopeo 실패한 **부분 고장**을 하트비트와 분리해 관측한다.

**왜 별도 alertname인가.** 감시 대상 룰(ImageDigestDrift)에 per-rule `absent()`를 덧붙이면 exporter
사망을 "이미지 불일치"로 **오귀속**한다 — 이 레포가 이미 원칙으로 못박고 게이트로 강제하는 사항이다
(`tests/gates/test_vmalert-config.bats`: per-rule absent는 잘못된 원인 페이지 + TargetDown 중복).

**왜 F-1 스케치를 대체하는가.** `docs/bugfixes/image-digest-drift-never-fires.md`의 F-1은
`absent(last_over_time(ghcr_latest_digest[30m]))` 하나로 exporter 사망을 잡자고 적어 두었다. 그러나
`ghcr_latest_digest` 부재는 원인이 **3갈래**(push 경로 사망 / GHCR 수집 실패 / 앱 0개)라 알림이 원인을
지목하지 못한다. 하트비트(push 경로)와 카운트(수집 성공)를 **분리 관측**하면 각 알림이 정확한 원인을
가리킨다. 이 PRD는 F-1을 흡수·대체한다.

**범위는 관측 추가만.** exporter의 fail-loud화(Job 종료코드 변경, F-3)는 이 기능에 넣지 않는다
(intake 확정) — 아래 Out of Scope 참조.

## User Stories

1. owner로서, digest-exporter의 push 경로가 죽으면(크론 미실행·push 실패·파드 기동 실패) **텔레그램
   경고를 받고** 싶다 — ImageDigestDrift가 조용히 실명한 채 방치되는 것을 막기 위해.
2. owner로서, GHCR 자격 만료·레지스트리 장애로 **일부 또는 전부 앱의 digest 수집이 실패**하면 그
   사실을 알고 싶다 — 지금은 해당 앱이 조용히 스킵돼 드리프트 감시에서 소리 없이 빠진다.
3. owner로서, 이 새 알림들이 **"구조적으로 발화 가능"함을 CI가 증명**하길 원한다 — 이 알림 클래스는
   4번 재발했고, required 게이트인 `vmalert -dryRun`은 파싱만 하므로 발화를 증명하지 못한다.

## Implementation Decisions

**메트릭(3개, 기존 단일 curl 페이로드에 추가)** — 이름 확정(owner 결정 2026-07-13):

| 메트릭 | 종류 | 값 |
|---|---|---|
| `digest_exporter_last_success_timestamp` | 하트비트(타임스탬프-값) | push 직전 epoch 초 |
| `digest_exporter_apps_configured` | 게이지 | `APPS` 엔트리 수(= 루프 반복 수) |
| `digest_exporter_apps_scraped` | 게이지 | skopeo digest 획득에 성공한 앱 수 |

`_total` 접미는 쓰지 않는다 — Prometheus 규약상 카운터를 뜻하는데 이들은 게이지이고, 레포의 기존
push 메트릭 11건 중 `_total`은 0건이다(미래에 `rate()`/`increase()`를 유도하는 함정).

- 기존 `OUT` 누적 → 단일 `curl … --data-binary @-` 경로를 그대로 쓴다. 결과적으로 **netpol·자원·메모리
  원장 변경 0**(egress는 이미 `vmsingle:8428` 허용; 원장과 `check-resource-limits`는 CronJob 비대상).
- **bare 시리즈(라벨 0)** 로 push한다. `(time() - last_over_time(m[W])) > T or absent(last_over_time(m[W]))`
  에서 좌·우 브랜치가 **같은 (빈) 라벨셋**을 내야 시리즈가 윈도 밖으로 만료될 때 알림 identity가 유지되고
  `for:` pending이 리셋되지 않는다. 형제 하트비트 4종이 전부 bare인 것은 우연이 아니다.
- 하트비트 값 = **epoch 초**(`date +%s`), 명시 sample timestamp 없음(형제 관용구). 기존
  `ghcr_latest_digest`만 ms sample timestamp를 쓰는 예외는 **그대로 둔다**(행위 보존).
- **하트비트의 의미론 = "push 경로 생존"이지 "수집 성공"이 아니다.** skopeo가 전건 실패해도 하트비트는
  발행된다 — 그 케이스는 카운트 알림이 잡는다(역할 분리). 형제들의 "녹색 하트비트 금지" 규율은 여기서
  **카운트 알림이 대신 충족**한다(digest-exporter는 fail-loud가 이번 범위 밖이므로).
- **POSIX sh 제약**: `run.sh`는 `#!/bin/sh` + `set -eu`(pipefail 없음) + `readOnlyRootFilesystem: true`
  (tmp 볼륨 없음). 카운터는 `N=$((N+1))` **대입 형태만** 쓴다 — `((N++))`·`<<<`·배열·임시파일은 불가
  하고, `: $((N++))`는 결과 0에서 non-zero 반환이라 `set -e`가 스크립트를 죽인다.

**린터 계약(어기면 `make verify`와 required `gate`가 FAIL)**

- 신규 메트릭 3개를 `tools/check-alert-rules.ts`의 `DEFAULT_REGISTRY`에 등재한다
  (`producer` = digest-exporter.yaml, `schedule` = `{kind:'cron', file: 동일}`). 완전성 가드는
  **양방향**이다 — push하는데 미등재도 FAIL, 등재했는데 추출 불가도 FAIL.
- exposition 라인은 **정적 추출 가능한 형태**로만 쓴다(`OUT="${OUT}<이름> ${VAL}\n"`). 이름을 변수로
  조립하거나 대문자를 쓰면 추출기가 못 본다. 새 로그 문구에 `단어 + 공백 + 숫자` 형태를 쓰지 않는다
  (추출기가 메트릭으로 오인한다).
- **CronJob 구조 불변**: 두 번째 CronJob 추가 금지(레지스트리 `schedule=cron`은 파일당 정확히 1건 요구),
  `*/10` 스케줄 변경 금지(바꾸면 모드 C 하한과 `vmalert-drift-firing-e2e.sh` preflight가 동시에 깨진다).
- **APPS env의 `- name: APPS` / `value: "…"` 2줄 구조 불변** — `tools/lib/digest-exporter.ts`의 정규식
  계약이고 create-app/teardown-app이 여기 의존한다(YAML 재포맷 금지).

**알림 룰** — 배치·임계 확정(owner 결정 2026-07-13): **`platform/victoria-stack/prod/rules/r4-storage-backup.yaml`**
(group `storage-backup`). 근거: 이 레포에서 **유일하게 문서화된 파일링 규약**이 "도메인이 스토리지가
아니어도 push-metric staleness 알림은 r4에 모은다"이고(`AdguardRewriteReconcilerStale` 선례), 형제
하트비트 알림 4건이 전부 거기 있다. 신규 룰 파일을 만들지 않으므로 5곳 배선(kustomization·vmalert
`--rule`·volumeMounts·volumes·`test_telegram-alert-korean.bats`의 하드코딩 spec 목록)도 불필요하다.

- push 주기 600s > vmalert 룩백 300s → 신규 메트릭은 **모드 C 강제 대상**이다. 모든 참조는
  `last_over_time(m[W])`(ROLLUP_OK) 안에서 **W ≥ 10m**. `absent()`는 메트릭에 직접 걸 수 없고
  반드시 `absent(last_over_time(m[W]))` 형태여야 한다. `rate`/`increase`는 2샘플을 요구해 무력이며
  린터가 "가짜 픽스"로 거부한다.
- **윈도 상한은 없다** — 타임스탬프-값 하트비트에서 윈도는 탐색 지평일 뿐이다. ImageDigestDrift의
  `W < for` 상한은 **라벨-값 상태 게이지 전용**이며 여기 복사하면 누락 내성만 잃는다(traps-detail의
  명시된 비대칭). **W = [2h]** 를 채택한다(형제 `AdguardRewriteReconcilerStale`과 동형).
- **`DigestExporterStale`**:
  `(time() - last_over_time(digest_exporter_last_success_timestamp[2h])) > 1200`
  `or absent(last_over_time(digest_exporter_last_success_timestamp[2h]))`, **`for: 10m`**,
  `severity: warning`. → **T0+30분 발화**. 쌍둥이 클론(T=1800·for:15m)보다 조인 값을 택한 이유는 아래
  산술 — 클론은 ImageDigestDrift가 이미 실명한 뒤 **30분간 무통보**로 둔다. T=1200s는 2주기(20분)
  누락을 관용하므로 **단발 크론 누락에는 여전히 무발화**다(플랩 없음).
- **`DigestExporterScrapeIncomplete`**: 두 bare 시리즈의 **스칼라 비교**
  `last_over_time(digest_exporter_apps_scraped[2h]) < last_over_time(digest_exporter_apps_configured[2h])`,
  `for: 30m`(= 3주기 관용 — 단발 GHCR 블립을 흡수), `severity: warning`. bare끼리의 1:1 매치라
  `on()`/`ignoring()`이 **불필요** → 모드 B 비대상(KSM 조인으로 기대값을 구하면 모드 B가 양변 사전
  집계를 강제한다).
- **카운트 알림에는 `absent` 가드를 달지 않는다** — 전면 침묵(push 사망)은 하트비트 알림이 이미
  fail-closed로 잡는다. 같은 고장에 두 번 페이징하는 형태는 FilesBulkSSDLow가 명시적으로 거부한 패턴이다.
- **zero-app vacuity는 의도된 공백이다**(owner 결정): 마지막 앱을 teardown하면 `APPS`가 빈 문자열이 되어
  `configured=0`·`scraped=0` → `0 < 0`이 false라 카운트 알림이 침묵한다. 앱이 0개면 감시할 대상 자체가
  없으므로 가드(`configured == 0` 발화)를 **넣지 않는다** — 대신 룰 주석에 이 공백을 명시해 다음 사람이
  "왜 안 잡히지"로 헤매지 않게 한다.
- 라벨은 **`severity`만** 단다(telegram 기본 라우트, `repeat_interval` 4h). `component`·`runbook_url`은
  레포 사용례 0건이라 도입하지 않고, `disk` 라벨은 inhibit와 연동되므로 절대 달지 않는다.
- `summary`·`description`은 **한국어 필수**(gate bats가 non-ASCII 포함을 강제). Alertmanager 한국어
  제목 매핑 2건을 함께 추가한다(미매핑이어도 summary 폴백이라 red는 아니지만 관례).

**롤아웃·롤백 계약 — 이 기능은 `main`에 두 번 랜딩한다** (plan 게이트 P-2, r1 + r2 반영):

신규 시리즈는 최초 배포 시 이력이 없다 → 룰이 먼저 로드되면 `absent(last_over_time(hb[2h]))`가 **즉시
pending**에 들어가고, `for: 10m`이 producer 주기(`*/10`)와 같아 첫 CronJob이 완주하기 전에 발화할 수
있다(스케줄 대기 + 이미지 기동 + skopeo 지연). **롤아웃 자체가 원인인 거짓 페이지**다.

⚠️ **배포 경계는 `main` 머지뿐이다.** victoria-stack ArgoCD Application은 **`main`만 감시**하므로,
feature 브랜치 안에서 슬라이스를 나누는 것은 **배포를 나누는 것이 아니다**(r2가 잡은 결함). 그렇다고
"structure 게이트만 거친 중간 랜딩"을 만들 수도 없다 — 파이프라인은 `landing`을 **`finishing`에서만**,
verification + 승인된 release 게이트 **뒤에** 호출하며, 그 랜딩이 흐름을 끝낸다(r3가 잡은 결함).

**해법: 게이트는 브랜치 전체에 사전 실행하고, 배포만 `finishing` 안에서 2-PR로 단계화한다.**
producer 코드도 release 리뷰를 받으므로 "리뷰 없는 배포"가 아니고, 파이프라인의 단일 흐름
(plan → structure → verification → release → finishing → done) 모델도 그대로다.

- **게이트(전부 랜딩 전, 브랜치 전체 = 두 슬라이스에 대해)**: plan → executing(슬라이스 1 = skeleton,
  슬라이스 2) → **structure 게이트**(skeleton diff) → **verification**(hermetic: producer 행위 테스트
  + 발화 e2e 6레그 + `make verify`) → **release 게이트**(브랜치 전체 diff) → `finishing`.
- **`finishing` = 2-PR 단계 배포**(`landing`이 수행):

  | 단계 | 내용 | 확인 |
  |---|---|---|
  | **PR-A** | 슬라이스 1 커밋만(= exporter `run.sh` 메트릭 3개 + `DEFAULT_REGISTRY` 등재 + producer 행위 테스트) | required `gate` green → `main` 스쿼시 머지 |
  | **라이브 체크포인트**(차단) | ArgoCD 싱크 → 크론 1주기(≤10분) 대기 | vmsingle에 하트비트·카운트 3개가 적재됐음을 rollup 질의로 확인. **확인 전에는 PR-B를 열지 않는다** |
  | **PR-B** | 슬라이스 2 커밋(= 알림 룰 2건 + 발화 e2e + 함정 원장 tie + alertmanager 제목 매핑). PR-A 스쿼시로 SHA가 재작성되므로 갱신된 `main` 위로 re-anchor | required `gate` green → `main` 머지 → vmalert 30s reload. 이 시점 하트비트는 **신선**하므로 `absent`도 `time()-hb > 1200`도 거짓 → **거짓 페이지 0** |

- **PR-A는 단독으로 `main`에 있어도 안전하고 게이트 green이다**: 새 메트릭을 push하고 레지스트리에
  등재했으므로 모드 C 완전성 가드(양방향)를 만족하고, 그 메트릭을 참조하는 룰이 아직 없으므로 모드 C의
  rollup 검사 대상도 없다. 즉 "관측만 하고 알림은 없는" 중간 상태가 **정상 상태**다.
- **라이브 체크포인트는 게이트가 아니라 랜딩 절차의 차단 조건**이다(랜딩 전에는 관측할 수 없는 사실이므로
  hermetic verification으로 대체 불가). 그 증거(질의 + 출력)는 `finishing` 완료 시
  `docs/reviews/digest-exporter-stale/verification.md`에 **추가 기록**한다.
- **파이프라인 상태 연속성**: 흐름은 하나다 — `finishing`은 두 머지가 **모두** 끝나야 완료되고, 그때
  `pipeline-stage: done`이 된다. PR-A만 머지된 중간 상태에서 세션이 끊기면 state가 `finishing`으로
  남아 다음 세션이 PR-B부터 재개한다.
- **롤백은 역순**: 룰을 먼저 되돌리고(알림 침묵) 그다음 exporter 메트릭을 되돌린다. 역순을 어기면
  메트릭이 사라진 상태로 룰만 남아 **즉시 페이징**한다.
- **거부된 단일-랜딩 대안 2건**(기록):
  - `for:` **유예 인플레**(예: `for: 25m`) — 발화가 T0+45분으로 밀려 Question ③에서 좁힌 15분 실명
    구간이 그대로 원복된다(위 산술표).
  - `absent` 가지를 **별도 룰로 분리**해 긴 `for:`를 주는 방식 — alertname이 2개가 되어 같은 고장에
    두 번 페이징한다(FilesBulkSSDLow가 명시적으로 거부한 중복 페이지 패턴).

**탐지 지연 산술(임계 결정의 근거)** — 마지막 성공 push를 T0라 할 때:

| 값 | 발화 시각 | ImageDigestDrift 실명 시작 | 무방비·무통보 구간 |
|---|---|---|---|
| 쌍둥이 클론(T=1800s, for:15m) | T0+45m | T0+15m | 30분 |
| **채택: T=1200s, for:10m** | **T0+30m** | T0+15m | **15분** |

(실명 시작 = ImageDigestDrift 기록 룰의 `[15m]` 윈도 만료 시점 — 그 뒤로는 좌변이 빈 벡터라 드리프트가
있어도 발화하지 못한다.)

## Testing Decisions

| User stories | Observable seam | Why this seam | Prior art / command |
|---|---|---|---|
| 1, 2, 3 | **hermetic vmalert replay 발화 e2e** — `tests/gates/vmalert-digest-stale-firing-e2e.sh`(신규, `.sh` + ci.yaml `gate` 명시 스텝) | 룰이 "구조적으로 발화 가능"함은 **실제 평가로만** 증명된다. dryRun은 파싱만, 모드 C는 하한 정적 검사만 한다 — 이 클래스가 4번 뚫린 이유이자 3부작이 확립한 유일한 실효 증명 | `tests/gates/vmalert-bulkssd-firing-e2e.sh`(복사 원본 — 유일한 lib 소비자) + `tests/gates/lib/vmalert-e2e.sh` |
| 1, 2 | **정적 린터**(기존 seam 재사용) — 모드 C + 레지스트리 완전성 | 신규 메트릭 3건의 등재와 신규 룰 2건의 rollup 착용·윈도 하한을 **레포 전역**으로 강제(e2e는 겨냥한 룰만 증명) | `make verify` → `tools/check-alert-rules.ts`; required gate → `tests/test_alert_rules.bats` |
| 1, 2 | **producer 행위 seam** — ConfigMap에서 `run.sh`를 추출해 **stub `skopeo` + `curl` 페이로드 캡처**로 실제 실행하고 출력 페이로드를 단언(신규 bats, 비-docker → `run-bats` 자동 수집) | **합성 replay는 룰만 증명하고 producer를 증명하지 않는다.** 카운터 증가를 빈-digest 검사 앞에 두는 것만으로도 문법 검사·레지스트리·replay·전건성공 라이브 확인을 전부 통과하면서 US2가 조용히 깨진다 — `scraped == configured`로 오보고. 스크립트를 **실행**하는 것만이 카운트 의미론을 증명한다 | 기존 `tests/gates/test_digest-exporter.bats`(정적 grep 단언)를 이 실행 seam으로 **승격**. 입력 4종: 전건성공 / 부분실패 / 전건실패 / zero-app |
| 1, 2 | **라이브 검증**(verification 단계) | 배포된 룰의 실제 로드와 메트릭 가시성은 클러스터에서만 증명된다 | ArgoCD 싱크 → vmalert `configCheckInterval=30s` reload → vmsingle에 3 메트릭 rollup 질의 |

**신규 seam(발화 e2e)의 상세 계약** — 새로 만드는 유일한 seam이므로 형태를 못박는다:

- **레그 구성(6)** — plan 게이트 P-3 반영(L5·L6 추가, L2 강화):

  | 레그 | 입력 | 단언 |
  |---|---|---|
  | L1 | 오래된(stale) 하트비트 샘플 | `DigestExporterStale` firing |
  | L2 | 정상 하트비트 + 같은(비-0) 카운트 | 두 알림 모두 **firing==0 AND pending==0** + **대조 알림 `FilesBackupStale` firing>0**(HARNESS FAULT로 강제 — vacuous pass 차단; r4 배치 결정 덕에 bulkssd 게이트의 대조군을 그대로 재사용) |
  | L3 | **동결 결함 픽스처**(맨 참조 expr) | `firing==0 && pending>0` — 하네스의 이빨(거짓 GREEN 최종 보증) |
  | L4 | `scraped < configured` | `DigestExporterScrapeIncomplete` firing |
  | L5 | **하트비트 샘플 전무**(한 번도 push된 적 없음 / `[2h]` 만료) | `DigestExporterStale` firing — `or absent(...)` **가지의 유일한 증명**(L1의 stale-샘플과는 다른 코드 경로) |
  | L6 | `configured=0, scraped=0`(zero-app) | `DigestExporterScrapeIncomplete` **무발화** — owner 결정 ④(의도된 침묵)를 락한다. `<`를 `<=`로 바꾸거나 zero-app 가드를 나중에 추가하면 여기서 죽는다 |
- **배포 룰은 픽스처로 복제하지 않는다** — 매 실행 배포 ConfigMap에서 `yq '.data["r4.yaml"]'`로 바이트
  추출 + 겨냥 alertname 존재를 fail-closed grep(리네임 시 무성 무측정 차단).
- **`?max_lookback` 핀은 load-bearing이다**: 신규 하트비트는 `ghcr_latest_digest`와 **동일 CronJob·동일
  600s 주기**로 push되므로, 드리프트 하네스가 바로 그 10분 주기에서 실증한 range-질의 보간 조건과 같다
  (files-bulk의 "핀 무관" 실측은 **일 단위 구멍에만** 스코프된다). `vme_replay`가 핀을 위치인자로 강제
  하므로 공짜로 얻는다. **핀 제거 1회 실측**을 L3에 대해 수행하고 결과를 헤더 주석에 기록한다(사변 →
  실측 승격, bulkssd 선례).
- **drift 게이트의 `push ≤ W < for` preflight는 복사 금지**(상태 게이지 전용 상한). 신규 preflight는
  **하한(W ≥ push 600s)** + `for`가 eval(30s)의 정수배 + 룩백 < push(구멍 전제)로 한정한다.
- **exit 코드**: `2` = HARNESS FAULT/CONTRACT(전제 붕괴·vacuity), `1` = leg FAIL, `0` = OK.
- **bats로 만들지 않는다** — `run-bats.sh`가 `tests/.ci-exclude`로 docker 의존 테스트를 빼므로 죽은
  커버리지가 된다. ci.yaml `gate`의 명시 `run: bash …` 스텝이어야 한다.
- **비용**: 레그마다 vmsingle 컨테이너를 새로 띄운다(형제 실측: drift ≈69~95s, bulkssd 4레그 ≈142s).
  6레그면 required `gate`의 wall-clock에 **약 3~4분**이 더해진다 — 이 알림 클래스가 4번 재발한 비용에
  비하면 수용 가능하다고 판단한다.
- **함정 원장 tie**: 신규 게이트 경로를 `docs/traps.md` 행 45의 guard 셀 + `docs/traps-detail.md`의
  대응 `> 가드:` 줄에 **양방향으로** 추가한다(새 `### ` 섹션은 만들지 않는다 — 새 함정 클래스가
  아니고, 새 섹션은 AGENTS.md 인덱스 불릿 개수까지 연동된다).

## Out of Scope

- **F-3 — exporter fail-loud화**(skopeo·push 실패를 Job 실패로 승격): intake 확정. 승격은 vmsingle
  롤링 재시작 중 단발 실패가 Job Failed → ArgoCD Degraded로 번지는 위험(adguard 리컨실러가 라이브에서
  만나 `--retry-connrefused`로 흡수한 함정)을 별도로 검토해야 한다. 이번엔 **조용한 실패를 보이게만** 한다.
- **F-4 — `make ci` ↔ ci.yaml 패리티**: `gate`가 도는 `tests/gates/*.sh` 6개 중 5개가 `make ci`에 없다
  (패리티 bats도 그 갭을 못 본다). 신규 e2e도 같은 갭에 놓이지만, 흡수하면 이 기능의 표면이 흐려진다.
  별건 백로그로 유지.
- **F-5 — drift 하네스를 공유 lib으로 이관**: 보존 계약의 **측정 도구를 기능 추가 중에 바꾸지 않는다**.
  별건(gated-refactor).
- **메모리 원장 변경**: CronJob은 원장에도 `check-resource-limits`(KINDS = Deployment/DaemonSet/
  StatefulSet/Pooler/Cluster)에도 계상되지 않는다 → **원장 무변경이 정답**이다.
- **APPS ↔ `apps/` 정적 parity 감시**: 이미 `tests/gates/test_digest-exporter.bats`가 CI에서 강제한다.
  런타임 카운트 알림은 **"수집 성공" 층만** 본다(정적 설정 층과 혼동 금지).
- **`ghcr_latest_digest`의 기존 형태 변경**(ms sample timestamp·`{app,digest}` 라벨): 행위 보존.

## Questions

- None. (초안이 남긴 4건은 owner가 2026-07-13에 전부 확정했고 위 Implementation Decisions에 반영했다.)

확정 기록:

| # | 질문 | 결정 |
|---|---|---|
| ① | 룰 배치 r4 vs r6 | **r4-storage-backup.yaml** — 문서화된 파일링 규약 + 형제 4건 + e2e 대조 알림(`FilesBackupStale`) 재사용 |
| ② | 카운트 메트릭 이름 | **`_apps_configured` / `_apps_scraped`** — `_total`(카운터 규약) 회피, 알림명 `DigestExporterScrapeIncomplete` |
| ③ | staleness 임계·`for:` | **T=1200s · for:10m**(T0+30분 발화) — 클론(T0+45분)이 남기는 30분 무통보 구간을 15분으로 단축 |
| ④ | zero-app vacuity 가드 | **넣지 않는다** — 앱 0개면 감시 대상 없음. 룰 주석에 의도된 공백임을 명시 |

## Review Decision Log

### Codex Plan Review — r1: needs-attention → 3건 전부 Accept (owner triage 2026-07-13)

아티팩트: `docs/reviews/digest-exporter-stale/plan-r1.json` (reviewedSha `b8353c1`)

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| P-1 | high | `Open question: which seam tests mixed-success counter production?` — 혼합-성공 카운터 생산 로직을 **어느 seam도 실행하지 않는다** — 합성 replay는 룰만, `sh -n`은 문법만, 라이브는 성공 경로만 증명한다. 카운터 증가를 빈-digest 검사 앞에 두면 모든 게이트를 통과하면서 US2가 조용히 깨진다 | **Accept** | Testing Decisions seam 3을 **producer 행위 seam**으로 승격 — ConfigMap에서 `run.sh` 추출 → stub `skopeo` + `curl` 페이로드 캡처로 실행 → 입력 4종(전건성공·부분실패·전건실패·zero-app)의 출력값 단언 |
| P-2 | medium | `Initial deployment can fire before the first heartbeat` — 최초 배포 시 이력이 없어 `absent(...)`가 즉시 pending → `for:10m`이 producer 주기와 같아 **롤아웃이 원인인 거짓 페이지** 가능. 계획에 배포·롤백 순서가 없다 | **Accept(수정 수용)** | 롤아웃 순서를 계약으로 명시(슬라이스 1 = exporter+레지스트리+행위테스트 → 라이브 하트비트 확인 → 슬라이스 2 = 룰+e2e), 롤백은 역순. **Codex가 대안으로 제시한 `for:` 유예 인플레는 거부** — 발화가 T0+45분으로 밀려 Question ③에서 좁힌 15분 실명 구간이 원복되기 때문. 이 순서가 skeleton 경계를 확정 |
| P-3 | medium | `Open question: which seam tests first-run absence and zero-app silence?` — replay 매트릭스에 **`absent` 가지(하트비트 전무)** 와 **zero-app 침묵**이 없다 → `absent` 누락·`<`→`<=` 변경·거부된 zero-app 가드 추가가 계획된 레그를 통과하면서 US1/결정 ④를 위반할 수 있다 | **Accept** | 발화 e2e 레그 4 → **6**: L5(하트비트 전무 → 발화, `absent` 가지의 유일한 증명) · L6(0/0 → 무발화, 결정 ④를 락) 추가. L2를 `firing==0 AND pending==0`으로 강화. 비용 +≈70초 |

Codex 총평: "검증된 코드베이스 전제들은 정확했고, 확정된 결정 범위 안에서 실질적으로 더 단순한 안전한
대안은 발견되지 않았다."

### Codex Plan Review — r2: needs-attention (escalated)

아티팩트: `docs/reviews/digest-exporter-stale/plan-r2.json` (reviewedSha `5a37ba3`). P-1·P-3은 해소
확인. **P-2는 미해소** — 하드룰 4에 따라 owner에게 에스컬레이션했고 게이트는 **BLOCKED** 상태다.

| ID | 심각도 | 잔여 발견 | 상태 |
|---|---|---|---|
| P-2 | high | `P-2 remains unresolved: slice boundaries are not deployment boundaries` — full 트랙 파이프라인은 skeleton과 종속 슬라이스를 **격리 브랜치에 두었다가 마지막에 한 번 랜딩**하는데, victoria-stack ArgoCD Application은 **`main`을 감시**한다. 따라서 슬라이스 1을 skeleton으로 지정하는 것만으로는 **배포되지 않는다** — 통상 파이프라인을 따르면 producer와 룰이 **함께 랜딩**되어 P-2가 제거하려던 최초 실행 `absent(...)` 경주가 그대로 재현된다 | **Accept** (owner 2026-07-13: waive 거부, 수동 round 3 승인) |

**해소 시도 1(r3에서 기각)**: 배포 경계가 `main` 머지뿐임을 명시하고 2회 랜딩으로 재설계했으나,
**PR-A를 structure 게이트만 거쳐 랜딩**하는 형태였다 → r3가 critical로 반려:
`P-2 remains unresolved: PR-A has no valid gated landing transition` — 파이프라인은 `landing`을
`finishing`에서만(verification + 승인된 release 게이트 뒤에) 호출하고 그 랜딩이 흐름을 끝내므로,
producer를 release 리뷰 없이 배포하거나(계약 우회) 아니면 PR-A 자체가 불가능해진다(단일 랜딩으로 붕괴).

**해소(최종)**: **게이트를 브랜치 전체에 사전 실행하고, 배포만 `finishing` 안에서 2-PR로 단계화**한다.
producer 코드도 release 게이트를 통과한 뒤 랜딩되므로 "리뷰 없는 배포"가 아니고, 파이프라인의 단일 흐름
(plan → structure → verification → release → finishing → done)과 아티팩트 모델(`release-r*.json` 단수
계보)도 그대로 유지된다. 라이브 하트비트 확인은 **게이트가 아니라 랜딩 절차의 차단 조건**으로 못박았다.
owner가 하드룰 4의 (b) 수동 라운드를 승인했고(2026-07-13), 그 승인 하에 r4로 재검증한다.
