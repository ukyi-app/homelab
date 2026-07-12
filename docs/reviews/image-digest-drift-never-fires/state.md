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
red-baseline: f4497d23d5bc44e254dca736382d0472b8633ef5
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
BulkStorageLow·PvcDuExporterStale·AdguardRewriteReconcilerStale·FilesBackupStale 등이
`last_over_time[윈도]` + `or absent(last_over_time(...))` 형태다. **r6는 이 규약을 안 지켰다.**
(⚠️ r4에도 예외가 하나 있다 — `FilesBulkSSDLow`. 아래 별건 발견 참조.)

**프로세스 갭**: r6 룰 주석에 작성자가 `⚠️ 라이브 미검증 죽은 식 → 발화 검증 필수`라고 스스로
적어뒀으나 그 검증이 끝내 수행되지 않았다.

## 게이트 이력 — 전부 통과 (2026-07-12)

| 게이트 | 결과 |
|---|---|
| plan r1 | needs-attention 3건(P-1 high: rollup만 넣으면 KSM 장애 시 전 앱 오발화 / P-2: 하네스가 윈도 불변식 미강제 / P-3: 부정 단언이 vacuous) → 전부 Accept |
| plan r2 | needs-attention 1건(P-3′: ConfigMap 경로 오류 + 부정 패턴이 우변 가드를 잡음 + 중간 부정 false-green) → Accept. **2라운드 캡 도달 → 인간 트리아지로 executing 진행**(잔여는 기계 루프가 fail-closed 봉쇄) |
| structure r1 | **approve, 0 findings** — "RED 하네스·동결 픽스처가 픽스를 통과해 바이트 동일, characterization 약화 없음, scope 봉쇄" · 의도적 예외 2건(annotations 교체·docs를 scope에) 수용 |
| release r1 | needs-attention 1건(R-1 high, conf 1.0: RED 기록의 2000자 outputTail이 symptomToken을 반토막 내 **자기 검증 불가**) → Accept |
| release r2 | **approve, 0 findings — "Ship."** 래퍼가 하네스 산 FAIL 줄을 재출력하고 저장된 exit 상태로 종료하므로 기계 소유 flip 의미론 보존 |

**stage 부기 주의**: 릴리스 승인(reviewedSha `9a33241`) 이후 `docs/reviews/<slug>/` 밖 경로를 커밋하면
freshness 배리어가 승인을 무효화한다(플랜 문서도 예외가 아니다). 따라서 `pipeline-stage`는
`release-gate`에 둔 채 랜딩하고, **머지 후 main에서 `done`으로 전환**한다(그 시점엔 stage=done이
freshness 검사를 면제한다). 랜딩 결정·라이브 검증 결과는 이 파일(예외 경로)에 기록한다.

## 라이브 검증 — 픽스 확인 (2026-07-12, 머지 `a6d9c61` 후)

ArgoCD `victoria-stack` Synced/Healthy @ `a6d9c61` → r6 ConfigMap 반영 → vmalert가
`--configCheckInterval=30s`로 새 룰 로드.

**① 로드된 룰**: `last_over_time(ghcr_latest_digest[15m])` + `and on (app)` 반영 확인. 전 룰 `health=ok`.

**② 구멍이 메워졌다는 직접 증명 (결정적)** — 마지막 push 후 **339초**(vmalert 룩백 5분 = 300초 **밖**,
즉 버그의 서식지)에서 instant 질의:

| 질의 | 시리즈 |
|---|---|
| `ghcr_latest_digest` (픽스 전 룰이 보던 것) | **0개** ← 구멍 |
| `last_over_time(ghcr_latest_digest[15m])` (픽스) | **2개** ← 구멍이 메워짐 |

`for: 20m` pending을 리셋시키던 바로 그 시리즈 구멍이 프로덕션에서 사라졌다.

> ⚠️ 측정 함정(자기 교정): 첫 시도에서 "판별 창까지 대기" 중 exporter가 새로 push했는데 옛
> 타임스탬프로 나이를 계산해 **맨 참조가 2개**로 나왔다(거짓 negative). 질의 **직전에** 나이를
> 재측정하는 방식으로 고쳐야 정확하다.

**③ 오발화 0**: 현재 드리프트 없음(`app:image_digest_drift` 시리즈 0) → ImageDigestDrift 알림 없음.
firing 중인 알림은 `Watchdog`(deadman)뿐. 가드가 정상 동작(우변 텔레메트리 존재 → 판정 수행, 드리프트
없으므로 침묵).

## 머지 후 락 상태에 대한 정직한 기록

머지 **후** `bugfix-status.mjs`를 main에서 돌리면 `greenValid: false`
("GREEN flip proof is invalid — stale/forged cache")가 뜬다. **squash 머지의 필연이지 결함이 아니다**:
배리어 B2는 `red.sha`(`f4497d2`)와 `green.sha`(`a1f7d21`)가 **현재 HEAD에서 도달 가능**할 것을
요구하는데(dangling sha 위조 방지), squash가 브랜치 커밋을 단일 커밋(`a6d9c61`)으로 접어버려
그 조건이 깨진다.

**증거는 그대로 남는다** — 기계가 재실행해 쓴 verify-record 2개(`bugfix-verify-red-158e7e26….json`,
`bugfix-verify-green-d963ecb3….json`)가 커밋돼 있고, treeSha·exit 코드·symptomToken이 그 안에 있다.
릴리스 게이트 r2는 **머지 전**(양 sha가 도달 가능하던 시점)에 ancestry/tree SHA 일치를 확인하고
approve했다("ancestry/tree SHAs match, and the harness blob is unchanged").

## Red-capture — seam 판정 (2026-07-12)

3 후보를 스파이크로 실증하고 판정했다(전부 실제 실행 증거 기반).

**채택 = hermetic vmalert replay e2e 게이트**(`tests/gates/vmalert-drift-firing-e2e.sh`, 95초).
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

**`FilesBulkSSDLow`(r4-storage-backup.yaml)도 같은 클래스로 죽어 있을 가능성 — 코드 확인 완료**:

```yaml
- alert: FilesBulkSSDLow
  expr: |
    (files_data_bulk_avail_bytes / files_data_bulk_size_bytes) < 0.10   # ← rollup·absent 가드 없음
  for: 30m
```

`files_data_bulk_*`는 **호스트 launchd 백업 잡이 push**하는 저빈도 메트릭이다(주석 원문: "호스트 df를
백업 잡이 함께 push … 호스트 push가 유일 관측"). push 주기가 vmalert 룩백(5m)보다 길면 ImageDigestDrift와
**정확히 같은 메커니즘으로 발화 불가**다. 바로 옆 형제들(BulkStorageLow·PvcDuExporterStale)은 같은 함정을
`last_over_time[3d]` + `absent()`로 방어하는데 이 하나만 맨 참조다.

**완화 요인(위험도 하향)**: 같은 물리 매체를 보는 in-cluster 짝 `BulkStorageLow`(15% 임계, `last_over_time[3d]`
착용)가 **더 먼저** 발화하므로 "외장 SSD가 꽉 차는데 아무도 모른다"는 시나리오는 부분적으로 덮인다.
다만 그건 이원화의 다른 다리이고, `FilesBulkSSDLow` 자체는 죽은 감시견이다.

**별건 gated-bugfix로 분리**(여기서 고치면 두 번째 행동 flip = 단일 flip 불변식 위반).
착수 시 **push 주기 실측 필요**(launchd 스케줄 + `files_data_bulk_avail_bytes` 샘플 간격) — 주기가
5분 미만이면 살아있는 것이고, 그 이상이면 죽은 것이다.

## 범위 밖 (섞지 않는다)

- `check-alert-rules` 린터 모드 C(push 메트릭을 rollup/absent 가드 없이 참조하면 FAIL) =
  net-new 게이트 → 단일 flip 위반. **별건 후속**(레포 선례: 룰 #327 / 린터 #328 분리).
- image-pin 리팩터의 F-1/F-2/F-3 백로그(전부 오늘 도달 불가·low).
