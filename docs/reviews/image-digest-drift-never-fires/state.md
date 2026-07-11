---
bugfix: image-digest-drift-never-fires
invariant-class: bugfix
entry-track: bug
review-track: full
pipeline-stage: intake
issue-tracker: local
worktree:
branch: fix/image-digest-drift-never-fires
consent-scope:
symptom: "ImageDigestDrift 알림이 60일간 한 번도 발화하지 않았다 — 드리프트 상태가 실제로 발생했는데도(app:image_digest_drift에 page 81샘플·trip-mate-api 84샘플) 통보가 0건이다. 배포 드리프트 감시견이 fail-open으로 죽어 있다."
red-baseline:
bugfix-lock: pending
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

## 범위 밖 (섞지 않는다)

- `check-alert-rules` 린터 모드 C(push 메트릭을 rollup/absent 가드 없이 참조하면 FAIL) =
  net-new 게이트 → 단일 flip 위반. **별건 후속**(레포 선례: 룰 #327 / 린터 #328 분리).
- image-pin 리팩터의 F-1/F-2/F-3 백로그(전부 오늘 도달 불가·low).
