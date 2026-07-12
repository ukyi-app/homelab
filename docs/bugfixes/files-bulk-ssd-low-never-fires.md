---
bugfix: files-bulk-ssd-low-never-fires
invariant-class: bugfix
entry-track: bug
review-track: standard
pipeline-stage: verification
issue-tracker: local
symptom: "FilesBulkSSDLow가 구조적으로 발화 불가하다 — files_data_bulk_* 는 호스트 launchd가 하루 1회(04:30) 단발 push하는데 vmalert instant 질의 룩백은 5분이라, 알림 표현식이 하루 1440분 중 5분만 보인다. 30초 간격 평가로 최대 10회 연속 참 → for: 30m(60회 필요)에 절대 도달하지 못한다. 외장 bulk SSD가 꽉 차도 이 알림은 영원히 울리지 않는다."
red-baseline: ffa1797eb65a0540129c454ae24cbcf42bbdf0bd
bugfix-lock: green
first-increment: [B-1]
increments: [B-1]
spike-1:
---

# FilesBulkSSDLow가 구조적으로 발화 불가 (ImageDigestDrift와 동일 클래스)

## Root cause

`platform/victoria-stack/prod/rules/r4-storage-backup.yaml`의 `FilesBulkSSDLow`가 **push 메트릭**
`files_data_bulk_{avail,size}_bytes`를 **rollup 없이 맨 참조**한다.

| 요소 | 값 | 출처 |
|---|---|---|
| push 주기 | **86400s**(하루 1회 04:30) | 호스트 launchd `app.homelab.files-backup` → `scripts/backup-files-data.sh` |
| vmalert 룩백 | **300s** | `-datasource.queryStep` 기본값(override 없음 — deploy args·vmsingle flags 확인) |
| `for:` | **30m** = 61회 연속 평가(30s 간격) | 룰 파일 |

가시 창은 하루 **300초뿐**(0.35%) → 최대 11회 연속 참 평가 → `for: 30m`이 요구하는 61회에
**구조적으로 도달 불가**. 외장 SSD가 0% 여유여도 영원히 울리지 않는다.

**라이브 실측**(마지막 push 후 10.8시간, 질의 직전 나이 재측정): 알림 expr → **빈 결과**,
임계 제거한 비율 → **빈 결과**(임계 문제가 아니라 **시야가 빔**), `last_over_time(...[3d])` 비율 →
**0.9991**(데이터는 TSDB에 멀쩡히 있다 — 차이는 오직 rollup 유무). 룩백 경계 스윕: `last+300s`
NON-EMPTY / `last+301s` **EMPTY**.

**⚠️ 60일 firing 0건은 죽음의 증거가 아니다** — 여유율이 내내 99.91%라 조건이 참인 적이 없었다.
죽음의 증거는 **룩백/`for` 산술**이고, 같은 메커니즘의 **경험적 증거**는 방금 고친 `ImageDigestDrift`가
제공한다(조건이 지속 참인데 60일간 pending만·firing 0).

## The fix

형제 룰이 이미 정답 형태다(같은 파일 `BulkStorageLow`, `PvcDuExporterStale`).

```
- (files_data_bulk_avail_bytes / files_data_bulk_size_bytes) < 0.10
+ (last_over_time(files_data_bulk_avail_bytes[3d]) / last_over_time(files_data_bulk_size_bytes[3d])) < 0.10
```

`for: 30m` 유지. severity·labels·annotations·alert명 무변경.

**윈도 [3d] 근거**: 하한 = push 주기(1d)의 **2배 이상**(1회 누락 내성) · 상한 = 매체 교체·언마운트 후
stale한 낮은 값이 무한 페이징하지 않도록 유계. 형제들과 동일 윈도로 통일.
⚠️ 이 알림은 **ratio/threshold**(값=수준)이지 라벨-값 상태 게이지가 아니므로 드리프트 픽스의
`W < for` 제약은 **적용되지 않는다**(애초에 일 1회 push라 W<30m은 구성 불가). 하네스 preflight는
대신 `2×push ≤ W ≤ 7×push`를 강제한다.

### `absent()` 가드는 추가하지 않는다 (의도)

같은 스크립트가 함께 push하는 `files_backup_last_success_timestamp`의 생존은 이미
**`FilesBackupStale`**(severity **critical**, `last_over_time(...[10d])` + absent 가드)이 fail-loud로
페이징한다. 여기 또 달면 **동일 고장에 중복 페이지**가 난다. 기존 expr에 absent가 없는 것은 유일하게
옳았던 부분이므로 보존한다.

## Single-Flip Contract

> 여유율이 임계(10%) 미만이어도 `FilesBulkSSDLow`가 **발화하지 않는다** → **발화한다**.

**변경 표면(`scope[]`)**: `platform/victoria-stack/prod/rules/r4-storage-backup.yaml` 단일.

## Preserved Contract

| # | 보존 대상 | 이를 못박는 것 |
|---|---|---|
| 1 | `for: 30m`·severity·labels·annotations·alert명 | 하네스 preflight가 `for: 30m`을 **계약으로 고정**(낮추면 룩백보다 짧아져 게이트를 속이는 가짜 픽스가 된다) |
| 2 | 드리프트 없을 때(99% 여유) 무발화 | 하네스 **L2** |
| 3 | 형제 `BulkStorageLow`(rollup 착용, 15% 선행 발화) 무변경 | 하네스 **L4**가 매 실행 발화 증명 |
| 4 | **방금 머지한 `ImageDigestDrift` 회귀 금지** | characterizationCmd에 **드리프트 게이트를 포함**시켰다 |
| 5 | `check-alert-rules`(모드 A/B) · `vmalert -dryRun` | characterizationCmd |

## Regression test (already RED at red.sha)

- **seam**: `tests/gates/vmalert-bulkssd-firing-e2e.sh`(142초) — 배포 r4 룰을 **바이트 그대로** 추출
  (`for: 30m` 무변형), 일 1회(86400s) push를 합성 백필해 여유율 5% 지속을 재현하고
  `ALERTS{alertname="FilesBulkSSDLow",alertstate="firing"}` 부재/존재를 직접 단언. required `gate`에 배선.
- **regressionCmd**: 위 스크립트 + 증거 보존 래퍼(실패 레그를 출력 끝에 재출력 — image-digest-drift
  릴리스 게이트 R-1의 교훈: `outputTail` 2000자가 symptomToken을 자르면 기록이 자기 검증 불가가 된다)
- **symptomToken**: `FilesBulkSSDLow did not fire despite`
- **레그**: L1(증상) · L2(오발화 금지) · L3(**이빨** — 동결 결함 픽스처는 pending에 갇힘) ·
  **L4(생존·결정적 대조** — 같은 replay·같은 매체·같은 5% 결핍인데 rollup 착용한 형제
  `BulkStorageLow`는 **firing 181샘플**로 울린다 → 하네스가 못 울리는 게 아니라 **이 알림만** 못 울린다)
- **preflight**: rollup 부재는 HARNESS FAULT가 아니라 **L1의 RED 경로**로 구분 · `for: 30m` 계약 고정 ·
  `2×push ≤ W ≤ 7×push`

### 정직한 공개 — `max_lookback` 핀은 이 하네스에선 load-bearing이 아니다

드리프트 하네스에선 `?max_lookback=5m` 주입이 **필수**였다(없으면 replay의 range 질의가 10분 간격
push를 보간해 **버그 룰이 통과**하는 거짓 GREEN). 그러나 **일 단위(86400s) 간격에선 그 보간이 24시간
갭을 못 건너므로 핀이 없어도 동일 판정**임을 구현자가 실증했다(빼고 돌려 동일 결과). 핀은 미래 VM
버전의 휴리스틱이 공격적으로 바뀔 경우를 대비한 **방어적 상한**으로만 남기고, "이게 이빨을 준다"는
주석은 전부 제거했다. **거짓 GREEN 방어의 권위는 L3**(동결 결함 픽스처가 절대 발화하지 않아야 함)다.

## Increment plan

| id | what the fix does here | blocked-by | notes |
|---|---|---|---|
| B-1 | `FilesBulkSSDLow` expr의 두 피연산자를 `last_over_time(...[3d])`로 감싸고, 룰 주석에 윈도 근거(`2×push ≤ W`)와 "absent를 안 다는 이유(FilesBackupStale 중복 페이지 회피)"를 명시 | none | first-increment. 단일 표현식 |

## Follow-up backlog

- **F-1**: `check-alert-rules` **모드 C** — push 메트릭을 rollup 없이 참조하면 FAIL(정적 lint).
  **이 픽스가 머지돼야 위반 0이 되어 배선 가능**하다. 전수 조사 결과 위반은 이 알림이 마지막이었다.
- **F-2**: `DigestExporterStale` 신설 — exporter의 조용한 실패(skopeo·push 실패해도 Job은 초록)를
  아무도 못 잡는다. net-new 발화 조건이라 별도 파이프라인.

## Review Decision Log

### Codex Plan Review — r1: clean — verdict **approve**, 0 findings

원문: "The RED record matches ffa1797 and fails on the exact firing symptom; the real-rule replay,
L3 anti-false-GREEN control, L4 firing control, 3d window rationale, and FilesBackupStale backstop are
coherent."

**엔진이 제시한 더 단순한 대안(기각)**: "delete FilesBulkSSDLow and rely on the earlier fail-loud
BulkStorageLow alert, but that sacrifices the intended independent host-side sensor." →
룰 주석(r4:180-182)이 명시적으로 약속한 **이원화(host-side 독립 liveness)** 를 포기하는 것이므로
채택하지 않는다. 그 약속을 지킬 수 없다면 주석을 고쳐야 하는데, 그건 **감시 축소**라는 별도 결정이다.
