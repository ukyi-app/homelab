---
id: B-1
title: r6 드리프트 룰의 조인 소스를 image_spec으로(셀렉터는 image_id 유지) + 정적 게이트 갱신
status: open
blocked-by: [none]
plan: docs/bugfixes/image-digest-drift-false-positive.md
created: 2026-07-13
closed:
---

## What to build

**(a) 룰**(`platform/victoria-stack/prod/rules/r6-ci-staleness.yaml` — `scope[]`):
`app:image_digest_drift` 기록 룰 우변에서
- **셀렉터 `image_id=~"ghcr[.]io/ukyi-app/.*"`는 그대로 유지**(materialization 가드 — ImagePullBackOff 파드는
  `image_id=""`라 자동 제외되어야 한다),
- 두 `label_replace`(digest 추출 · app 추출)의 **소스 라벨만 `image_spec`으로** 교체.
- `unless` 우변과 존재 가드 우변은 **바이트 쌍둥이**여야 한다 → **동시에 동일하게** 수정.

**(b) 정적 게이트**(`tests/gates/test_digest-exporter.bats` — 테스트 파일, `scope[]` 밖):
현재 51행·72~74행이 **app 추출을 `image_id`에서 할 것**을 하드코딩 단언한다 → 룰 수정 시 red가 된다.
새 단언으로 갱신: ①우변 셀렉터 2개가 여전히 `image_id=~"ghcr…"`이고 서로 동일 ②digest·app 추출 소스가
`image_spec` ③두 `label_replace` 블록이 여전히 바이트 쌍둥이.

## Acceptance criteria

- [ ] `DRIFT_E2E_LEGS="L9" bash tests/gates/vmalert-drift-firing-e2e.sh` → **exit 0**(오탐 침묵 — RED가 GREEN으로)
- [ ] `DRIFT_E2E_LEGS="L1,L2,L3,L4,L5,L7,L8,L10" …` → **exit 0**(보존 계약 유지 — 특히 **L10**(막힌 롤아웃)과 **L7**(KSM 장애))
- [ ] `bats tests/gates/test_digest-exporter.bats` → green(갱신된 단언)
- [ ] `bun tools/check-alert-rules.ts` → 모드 A/B/C 위반 0
- [ ] `make ci` → rc=0
- [ ] 룰 파일 외 **비-테스트 경로 변경 0**(단일 flip 표면 — B4)

## Blocked by

None - can start immediately
