---
bugfix: files-bulk-ssd-low-never-fires
invariant-class: bugfix
entry-track: bug
review-track: standard
pipeline-stage: intake
issue-tracker: local
worktree:
branch: fix/files-bulk-ssd-low-never-fires
consent-scope:
symptom: "FilesBulkSSDLow가 구조적으로 발화 불가하다 — files_data_bulk_* 는 호스트 launchd가 하루 1회(04:30) 단발 push하는데 vmalert instant 질의 룩백은 5분이라, 알림 표현식이 하루 1440분 중 5분만 보인다. 30초 간격 평가로 최대 10회 연속 참 → for: 30m(60회 필요)에 절대 도달하지 못한다. 외장 bulk SSD가 꽉 차도 이 알림은 영원히 울리지 않는다."
red-baseline: ffa1797eb65a0540129c454ae24cbcf42bbdf0bd
bugfix-lock: red
spike-1:
---

## Track note

**Rule 0**: 관측 행위가 정확히 하나 뒤집힌다 — "여유율이 10% 미만이어도 FilesBulkSSDLow가 발화하지
않는다" → "발화한다". net-new 없음 → `invariant-class: bugfix`.

**review-track: standard** — 단일 증분·단일 표현식이고, **정답 형태가 같은 파일에 이미 존재한다**
(형제 `BulkStorageLow` r4:186이 `last_over_time(...[3d])` 착용). 방금 끝낸
[image-digest-drift-never-fires](../image-digest-drift-never-fires/state.md)에서 이 클래스의 seam·anti-cheat
쟁점을 이미 전부 통과시켰다(구조 게이트 approve). full 트랙의 추가 구조 게이트가 살 값이 낮다.
단, 배리어 1~4는 트랙 무관하게 그대로 적용된다.

## 게이트 이력

| 게이트 | 결과 |
|---|---|
| plan r1 | **approve, 0 findings** (더 단순한 대안 = 알림 삭제 → 이원화 포기라 기각) |
| release r1 | needs-attention 3건 → R-1(백스톱 주장 과장: df 실패 시 0 대입 + 성공 하트비트 → 값 오염이 백스톱 우회) 브랜치 내 교정(주석) · R-2(make ci 패리티) → F-4 · R-3(공유 lib 소비자 1개) → **사용자 승인 후 F-5** |
| release r2 | needs-attention 2건 → R-4(verification이 옛 green.sha 인용 — capturing-evidence 하드룰 위반) · R-5(R-3 승인 미기록) 교정 |
| release r3 | **approve, 0 findings — "SHIP"** (사용자 승인 하의 캡 초과 라운드) |

## 진단 (전수 조사 + 적대 검증 — 2026-07-12)

`ImageDigestDrift` 픽스 직후, **같은 클래스의 죽은 알림이 더 있는지 전수 조사**했다(push 메트릭을
기계적으로 도출 → 41룰 교차 → 라이브 실측 → 회의론자 반박). **위반은 정확히 1건: FilesBulkSSDLow.**

**근본원인**: `(files_data_bulk_avail_bytes / files_data_bulk_size_bytes) < 0.10` — push 메트릭을
rollup 없이 맨 참조.

| 사실 | 실측값 |
|---|---|
| push 주기 | **86400초**(하루 1회 04:30, 호스트 launchd `app.homelab.files-backup`) — 연속 샘플 간격 8개가 전부 86400±5초 |
| vmalert 룩백 | 300초(기본 `queryStep`, override 없음 — vmalert deploy args·vmsingle flags 양쪽 확인) |
| 가시 창 | 하루 **300초 / 86400초** = 0.35% |
| 최대 연속 참 평가 | 10회(30초 간격) — `for: 30m`은 **60회** 필요 → **도달 불가** |

**라이브 재현**(마지막 push 후 10.8시간 시점, 질의 직전 나이 재측정):
- `files_data_bulk_avail_bytes` → **빈 결과**
- 알림 expr 원문 → **빈 결과**
- 임계 제거한 비율 → **빈 결과** (임계 문제가 아니라 **시야 자체가 빔**)
- `last_over_time(...[3d])` 비율 → **0.9991** ← 데이터는 TSDB에 멀쩡히 있다. 차이는 오직 rollup 유무.

**룩백 경계 스윕**: `last+300s` → NON-EMPTY / `last+301s` → **EMPTY**. 경계는 정확히 300초.

**⚠️ 60일 firing 0건은 죽음의 증거가 아니다** — 여유율이 내내 99.91%라 조건(<0.10)이 참인 적이 없었다.
죽음의 증거는 **룩백/`for` 산술**이다. (같은 메커니즘이 실제로 발화를 막는다는 **경험적 증거**는
`ImageDigestDrift`가 제공한다: 조건이 지속적으로 참이었는데 60일간 `pending`만 있고 `firing`은 0.)

**회의론자가 추가로 닫은 문**(반박 실패 → confirmed):
- 다른 pusher 없음(`{__name__=~"files_data_bulk.*"}` 30일 → 정확히 2 시리즈, 단일 작성자)
- 상위 기록룰 rollup 없음(vmalert 로드 룰 전수 스캔 → `files_data_bulk` 참조 룰은 이것 하나뿐)
- per-group query params 없음(`params=None`)
- `remoteRead` 상태 복원 경로도 기본 룩백 1h라 24시간 갭을 못 건넌다

## 위험도: low (완화 강함) — 그래도 고치는 이유

같은 물리 매체를 보는 **in-cluster 짝 `BulkStorageLow`**(r4:186)가 **15%로 더 먼저** 발화하고
`last_over_time(...[3d])` + absent 가드를 착용해 정상 동작한다(`storage_tier_size_bytes` =
`files_data_bulk_size_bytes` = 2000293007360 바이트 일치 → 동일 파일시스템 확정). 따라서 "bulk SSD가
꽉 차는데 아무도 모른다"는 실질 노출은 ≈0이다.

**그럼에도 고치는 이유**: 룰 주석(r4:180-182)이 **독립 신호 2개**(host-side liveness + in-cluster)를
명시적으로 약속한다. 하나가 죽어 있으면 그 약속이 거짓이 되고, 나중에 in-cluster 다리가 흔들릴 때
백스톱이 없다고 착각하게 된다. **감사 무결성 결함**이다.

## 픽스 방향 (형제 룰이 정답 형태)

```
- (files_data_bulk_avail_bytes / files_data_bulk_size_bytes) < 0.10
+ (last_over_time(files_data_bulk_avail_bytes[3d]) / last_over_time(files_data_bulk_size_bytes[3d])) < 0.10
```
`for: 30m` 유지. **`absent()` 가드는 추가하지 않는다** — 같은 스크립트가 push하는
`files_backup_last_success_timestamp`의 생존은 이미 **`FilesBackupStale`(critical, absent 가드 착용)** 이
fail-loud로 페이징한다. 여기 또 달면 **동일 고장에 중복 페이지**가 난다(기존 expr에 absent가 없는 것은
유일하게 옳았던 부분).

**윈도 [3d] 근거**: 하한 = push 주기(1d)의 2배 이상(1회 누락 내성) · 상한 = 매체 교체·언마운트 후
stale한 낮은 값이 무한 페이징하지 않도록 유계. 형제 `BulkStorageLow`·`PvcDuExporterStale`과 동일 윈도로 통일.
⚠️ 이 알림은 **ratio/threshold**(값=수준)이지 라벨-값 상태 게이지가 아니므로 `W < for` 제약은 적용되지
않는다(애초에 일 1회 push라 W<30m은 구성 불가).

## 범위 밖 (섞지 않는다)

- `check-alert-rules` 모드 C(정적 lint) — net-new 게이트 → 별건. **이 픽스가 먼저 머지돼야** 린터가 green.
- `DigestExporterStale` 신설 — net-new 발화 조건 → 별건.
