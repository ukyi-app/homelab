---
id: B-1
title: FilesBulkSSDLow의 두 피연산자에 last_over_time([3d]) 착용 — 일 1회 push 메트릭을 vmalert가 볼 수 있게
status: done
blocked-by: [none]
plan: docs/bugfixes/files-bulk-ssd-low-never-fires.md
created: 2026-07-12
closed: 2026-07-12
---

## What the fix does here

`platform/victoria-stack/prod/rules/r4-storage-backup.yaml`의 `FilesBulkSSDLow` expr:

```
(last_over_time(files_data_bulk_avail_bytes[3d]) / last_over_time(files_data_bulk_size_bytes[3d])) < 0.10
```

`for: 30m`·severity·labels·annotations 무변경. `absent()` 추가 금지(FilesBackupStale이 이미 critical로
페이징 — 중복 페이지 회피).

룰 주석에 명시: 윈도 하한(`2×push` = 1회 누락 내성)·상한(stale 값 무한 페이징 방지) 근거, absent를
안 다는 이유, 그리고 이 알림은 ratio/threshold라 드리프트 룰의 `W < for` 제약이 적용되지 않는다는 것.

## Acceptance

- [x] `bash tests/gates/vmalert-bulkssd-firing-e2e.sh` — L1이 RED→GREEN, L2/L3/L4 유지, exit 0
- [x] characterizationCmd 전건 GREEN(**드리프트 게이트 포함** — 방금 머지한 알림 무회귀)
- [x] 변경된 non-test 경로가 `scope[]`(r4-storage-backup.yaml) 안
- [x] 동결 결함 픽스처(`r4-bulkssd-buggy-expr.yaml`) 무변경 — 갱신 = 하네스 이빨 제거
- [x] `for: 30m` 무변경, 형제 `BulkStorageLow` 무변경
- [x] 테스트 약화 0

## Result

커밋 = green.sha. L1 RED→GREEN(firing=181·pending=60=정확히 30m/30s hold), L2/L3/L4 유지.
characterization 전건 GREEN(드리프트 게이트 포함 — ImageDigestDrift 무회귀). 이월 없음.

**보고**: bats 과잉명세 없음 — `FilesBulkSSDLow`의 expr을 리터럴로 못박는 단언이 애초에 0이었다
(형제 `BulkStorageLow`는 rollup 윈도까지 bats로 고정돼 있는데 이 알림엔 대응물이 없었다 = 커버리지 갭이
버그를 방치한 한 원인). 지금은 게이트 preflight(`2×push ≤ W ≤ 7×push`)가 bats 리터럴보다 강한 계약으로
그 자리를 지킨다.
