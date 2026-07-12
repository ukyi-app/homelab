---
bugfix: image-digest-drift-never-fires
invariant-class: bugfix
entry-track: bug
review-track: full
pipeline-stage: design
issue-tracker: local
worktree:
branch: fix/image-digest-drift-never-fires
consent-scope:
symptom: "ImageDigestDrift 알림이 60일간 한 번도 발화하지 않았다 — 드리프트 상태가 실제로 발생했는데도(app:image_digest_drift에 page 81샘플·trip-mate-api 84샘플) 통보가 0건이다. 배포 드리프트 감시견이 fail-open으로 죽어 있다."
red-baseline: 736eeb198d4c8aab6375c2bdee9794ac084ad6f2
bugfix-lock: red
spike-1:
---

## Track note

**Rule 0**: 관측 행위가 정확히 하나 뒤집힌다 — "ImageDigestDrift가 실제 드리프트에도
발화하지 않는다" → "발화한다". net-new 없음, 2개 이상 flip 없음 → `invariant-class: bugfix`.

**review-track: full** — 이 클래스(알림 룰이 조용히 안 울림)는 레포에서 이미 4번 재발했고
(메모리 `alert-instance-label-churn-2026-07-09`), 알림 룰 수정은 "근본원인을 고쳤나 vs 증상만
특수처리했나"(예: `for:`를 0으로 낮추기)가 갈리기 쉬워 구조 게이트의 anti-cheat 판정이 값을 한다.

**진단 상태**: 근본원인 확정 + 라이브 실측 완료(Fork A). 아키텍처 문제 아님 — 고칠 좌표가
단일 파일의 단일 표현식이라 Fork B(gated-refactor) 아님.

## 진단 요약 (라이브 실측 — 2026-07-12)

**근본원인**: `platform/victoria-stack/prod/rules/r6-ci-staleness.yaml`의 record
`app:image_digest_drift`가 **push 메트릭** `ghcr_latest_digest`를 rollup 없이 맨 참조하고
`absent()` fail-closed 가드도 없다.

**메커니즘**: digest-exporter는 10분 주기 CronJob(`*/10 * * * *`)으로 단일 샘플만 push하는데,
vmalert의 instant 질의 룩백은 5분이다. 마지막 push 기준 instant 질의 실측:

| push 이후 | 시리즈 |
|---|---|
| +60초 | 2개 |
| +240초 | 2개 |
| +360초 | **0개** |
| +540초 | **0개** |

→ 매 10분 주기의 후반 5분간 메트릭이 vmalert 눈에서 사라진다 → 기록룰 시리즈에 구멍 →
`for: 20m` pending이 매 주기 리셋 → 20분을 누적할 수 없다 → **어떤 드리프트에도 발화 불가**.

**증거**:
- `count_over_time(ALERTS{alertname="ImageDigestDrift",alertstate="firing"}[60d])` → 빈 결과.
  대조군 15개 알림(Watchdog·PodOOMKilled·PgDumpHedgeStale 등)은 firing 시리즈 정상 기록 →
  기록 경로는 살아있고 이 알림만 발화 불가.
- `count_over_time(app:image_digest_drift[60d])` → page 81샘플 · trip-mate-api 84샘플 →
  감시 대상 상태는 실제로 발생했는데 무발화.

**수정 방향(같은 레포에 증명된 패턴 존재)**: `r4-storage-backup.yaml`은 동일 함정을 명시적으로
방어한다 — 주석 원문 `# 일 1회 push라 last_over_time [3d] 윈도 필수(instant staleness 함정).`,
`# 10분 주기 push라 last_over_time[2h] 윈도 + absent가 fail-closed(push-metric 함정).`
BulkStorageLow·PvcDuExporterStale·FilesBulkSSDLow가 전부 `last_over_time[윈도]` +
`or absent(last_over_time(...))` 형태다. **r6만 이 규약을 안 지켰다.**

**프로세스 갭**: r6 룰 주석에 작성자가 `⚠️ 라이브 미검증 죽은 식 → 발화 검증 필수`라고 스스로
적어뒀으나 그 검증이 끝내 수행되지 않았다.

## Red-capture — seam 판정 (2026-07-12)

3 후보를 스파이크로 실증하고 판정했다(전부 실제 실행 증거 기반).

**채택 = hermetic vmalert replay e2e 게이트**(`tests/gates/vmalert-drift-firing-e2e.sh`, 69초).
배포 ConfigMap에서 룰을 **바이트 그대로 추출**(`for: 20m` 무변형)하고 합성 드리프트를 심어
`ALERTS{alertname="ImageDigestDrift",alertstate="firing"}` 시리즈의 부재(RED)/존재(GREEN)를
직접 단언한다 — 사용자의 정확한 증상을 룰 변형 없이 단언하는 유일한 seam.

**기각**:
- **시간 압축**(`for: 20m`→40s sed 변형): 배포되는 계약을 테스트가 바꾼다 → 구조 게이트 anti-cheat 위반.
- **정적 shape 단언 단독**: 윈도만 `[24h]`로 키운 **의미론적으로 틀린 픽스도 GREEN**(스파이크가 실증).
  회귀 가드로는 가치 있으나 "픽스가 검증됐다"고 말할 수 없다 → 락 불가.
- **docker 의존 bats**: `tests/.ci-exclude` 관례상 required gate에서 빠져 죽은 커버리지.
- **naive vmalert replay**: replay는 `/api/v1/query_range`를 쓰고 VM이 10분 간격 push를 연속
  보간해버려 **버그 룰이 firing 191로 통과**한다(거짓 GREEN). datasource URL에 `?max_lookback=5m`을
  주입해 라이브 instant-query 룩백을 복원해야 비로소 RED가 재현된다.

**하네스 6레그**: L1(증상=발화해야 함, 지금 실패=RED) · L2(오발화 금지) · L3(phantom bump 무발화) ·
L4/L5(버그 픽스처·가짜 픽스 거부 = 하네스 이빨) · L6(ArgoCDOutOfSync 발화 = 하네스 생존).
버전·룩백·push 주기는 전부 매니페스트에서 파생(하드코딩 0).

**픽스 설계를 구속하는 발견**: 가장 자연스러운 픽스 `last_over_time(ghcr_latest_digest[30m])`은
구 digest를 되살려 **이미지 bump마다 오발화**한다(30m 링거 > `for: 20m`). L3가 이걸 문다
(실증: `[30m]` → L3 FAIL(firing=18), `[15m]` → 전 레그 PASS). 안전 윈도: `push(10m) ≤ W < for(20m)`.

## 별건 발견 (이 PR에 섞지 않는다)

**`FilesBulkSSDLow`(r4-storage-backup.yaml:158-161)도 같은 클래스로 죽어 있을 가능성** — rollup·absent
가드 없이 push 메트릭 참조 + `for: 30m`. 사실이면 외장 bulk SSD가 꽉 차도 영원히 페이징되지 않는다.
**별건 gated-bugfix로 분리**(여기서 고치면 두 번째 행동 flip = 단일 flip 불변식 위반). 미검증 — 착수 전
독립 실측 필요.

## 범위 밖 (섞지 않는다)

- `check-alert-rules` 린터 모드 C(push 메트릭을 rollup/absent 가드 없이 참조하면 FAIL) =
  net-new 게이트 → 단일 flip 위반. **별건 후속**(레포 선례: 룰 #327 / 린터 #328 분리).
- image-pin 리팩터의 F-1/F-2/F-3 백로그(전부 오늘 도달 불가·low).
