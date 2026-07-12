---
id: B-1
title: 기록룰 좌변에 rollup 착용 + 우변 존재 가드 — ImageDigestDrift가 실제 드리프트에 발화하게 한다
status: open
blocked-by: [none]
plan: docs/bugfixes/image-digest-drift-never-fires.md
created: 2026-07-12
closed:
---

## What the fix does here

`platform/victoria-stack/prod/rules/r6-ci-staleness.yaml`의 record `app:image_digest_drift`
표현식 하나를 고친다. 두 변경은 **분리 불가능한 한 덩어리**다 — ①만 넣으면 단일 flip 계약을 깬다.

**① rollup(근본원인 제거)**: 좌변의 push 메트릭을 `last_over_time(ghcr_latest_digest[15m])`로 감싼다.
10분 주기 push를 5분 룩백 instant 질의로 읽던 의미 불일치가 사라져 시리즈 구멍이 없어지고,
`for: 20m` pending이 누적된다.

**② 우변 존재 가드(단일 flip 보존)**: `and on (app) (max by (app) (label_replace(kube_pod_container_info{...}, "app", ...)))`.
①만 넣으면 좌변이 연속이 되어, KSM/스크레이프 장애로 우변이 사라질 때 `unless`가 아무것도 제거하지
못해 **전 앱이 "이미지 불일치"라는 거짓 사유로 20분 뒤 발화**한다(오늘 없던 두 번째 페이징 조건 —
plan-gate P-1). 가드는 "해당 app에 지금 파드 텔레메트리가 있을 때만 드리프트를 주장한다"를 강제해
KSM 장애 시 **오늘과 동일하게 침묵**시킨다(KSM 사망은 `TargetDown`이 페이징).

**제약**: 우변 파드 셀렉터에는 rollup을 붙이지 않는다(구 파드 digest가 되살아나 진짜 드리프트를 억제 —
같은 fail-open의 거울상). 하네스 preflight가 rollup 2개를 금지한다. 새 recording rule은 만들지 않는다
(eval 순서 의존 회피).

**③ 룰 주석**: 윈도 불변식(`push(10m) ≤ W < for(20m)`)과 r4 비대칭 규칙(타임스탬프-값 하트비트는
윈도 상한 없음 / 라벨-값 상태 게이지는 윈도 < `for`)을 명시해, 크론·`for`·W 중 하나를 바꾸려는
다음 사람이 나머지 둘을 보게 만든다.

**④ characterization 테스트 강화**: `tests/gates/test_digest-exporter.bats`의 리터럴 grep
(버그 표현식 문자열을 못박아 픽스하면 깨짐)을 **yq로 expr만 추출한 계약 단언**으로 교체 —
좌변 digest 라벨 보존 + rollup 착용 + 파손식(`max by (app)`) 금지. plan-gate P-3의 vacuous-단언
교정을 반영해 모든 grep에 대상을 명시한다. **약화가 아니라 강화**다(현 리터럴 단언은 픽스 후
파손식을 못 잡는다).

## Acceptance

- [ ] `bash tests/gates/vmalert-drift-firing-e2e.sh` — L1이 RED→GREEN, **L2~L8 GREEN 유지**, exit 0
- [ ] characterizationCmd 전건 GREEN
- [ ] 변경된 non-test 경로가 전부 `scope[]`(= r6-ci-staleness.yaml) 안
- [ ] L4/L5/L8 결함 픽스처는 **동결** — 절대 갱신하지 않는다(갱신 = 하네스 이빨 제거 = anti-cheat)
- [ ] `for: 20m` 무변경, 우변 파드 셀렉터 무변경, 새 recording rule 없음
- [ ] 테스트 약화 0(skip/xfail 없음, 단언 완화 없음, 증상 특수처리 없음)

## Result

(닫을 때 채운다: 커밋 sha, 결과 한 줄, 이월 항목)
