---
bugfix: image-digest-drift-false-positive
invariant-class: bugfix
entry-track: incident
review-track: standard
pipeline-stage: done
issue-tracker: local
symptom: "ImageDigestDrift{app=\"page\"}가 라이브에서 firing 중 — 그러나 배포된 컨테이너는 GHCR 최신과 바이트 동일한 arm64 이미지를 서빙하고 있다(실제 드리프트 없음). warning 라우트라 4시간마다 텔레그램 반복 통보되고, 진짜 드리프트가 나도 구분 불가."
red-baseline: e9b69c3cdc5d3b96c8dd1a9ea54c6c91ae81c3b0
bugfix-lock: green
first-increment: [B-1]
increments: [B-1]
spike-1:
---

# ImageDigestDrift 오탐 — 인덱스 digest vs containerd `image_id`

## Root cause

`app:image_digest_drift`(r6-ci-staleness.yaml) 기록 룰은 **두 개의 서로 다른 digest 정체성**을 같은 것으로
간주해 조인한다:

| 좌변 | `ghcr_latest_digest{app,digest}` — digest-exporter가 `skopeo inspect`로 **태그에서** 읽는 값 = **OCI 인덱스** digest |
|---|---|
| **우변** | KSM `kube_pod_container_info`의 **`image_id`** — **containerd가 보고하는 repo digest**(그 콘텐츠를 **최초 저장**했을 때의 참조) |

buildx는 태그에 **인덱스**(arm64 이미지 매니페스트 + provenance/SBOM **attestation** 매니페스트)를 push한다.
attestation은 **비결정적**(빌드 타임스탬프 등)이라 **소스가 동일한 재빌드에도 인덱스 digest가 새로 생긴다**.
그러나 arm64 자식 매니페스트는 **바이트 동일**하므로, containerd는 이미 가진 콘텐츠를 재사용하고
`image_id`로 **구 인덱스 digest를 계속 보고**한다.

**라이브 실측(page, 2026-07-13)** — skopeo 실물 프로브로 확정:

```
GHCR 최신 인덱스 (ghcr_latest_digest)   = sha256:98db4e11…
파드 spec / values 핀 (KSM image_spec)  = sha256:98db4e11…   ← 일치(드리프트 없음)
containerd 보고 (KSM image_id)          = sha256:54211c26…   ← 구 인덱스
  ├─ 구 인덱스(54211c26)의 arm64 자식   = sha256:d68dbeb6…
  └─ 신 인덱스(98db4e11)의 arm64 자식   = sha256:d68dbeb6…   ← 동일 콘텐츠
```

→ 좌변(신 인덱스)과 우변(구 인덱스)이 **영구 불일치** → `unless on (app, digest)`가 아무것도 빼지 못함 →
`app:image_digest_drift == 1` 영구 → **ImageDigestDrift 영구 firing**.

trip-mate-api가 멀쩡한 이유: 그쪽 재빌드는 **콘텐츠가 실제로 바뀌어** 새 arm64 매니페스트를 pull했고, 그래서
`image_id`가 신 인덱스와 일치한다. 즉 이 오탐은 **"코드 변경 없이 재빌드된 앱"에서만** 발현한다(따라서 이제껏
드러나지 않았다).

## The fix

조인 우변에서 **셀렉터와 라벨 추출의 역할을 분리**한다(plan 게이트 R-1 반영):

| 역할 | 라벨 | 왜 |
|---|---|---|
| **materialization 가드**(어떤 파드를 셀 것인가) | **`image_id=~"ghcr[.]io/ukyi-app/.*"` — 그대로 유지** | 이미지를 **실제로 당겨 실행 중인** 파드만 남긴다. ImagePullBackOff 파드는 KSM이 `image_id=""`로 내보내므로 이 셀렉터에서 **자동 제외**된다 |
| **비교 대상 digest**(무엇과 비교할 것인가) | **`label_replace`의 소스를 `image_id` → `image_spec`** | `image_spec` = 파드가 **쓰기로 선언한** digest 핀. 좌변(GHCR 최신 인덱스 digest)과 **같은 정체성 공간**에 있다 |

두 곳(`unless` 우변과 존재 가드 우변)은 **바이트 쌍둥이**여야 하므로(게이트
`tests/gates/test_digest-exporter.bats`가 강제) **동시에 동일하게** 바꾼다.

**왜 이 분리가 근본 원인을 제거하는가**: 버그의 정체는 "**containerd의 콘텐츠 저장 아티팩트**(`image_id`)를
**레지스트리 인덱스 digest**와 같은 정체성으로 취급한 것"이다. `image_id`는 재빌드 dedup에 영향받아 인덱스
digest와 다른 공간에 산다 — **비교 대상**으로 부적절하다. 그러나 "이 파드가 이미지를 실제로 실현했는가"라는
**존재 신호**로는 여전히 정확하다. 그래서 비교는 `image_spec`으로, 존재 판정은 `image_id`로 나눈다.

**대안 검토**:
- ① **`image_spec`-only 조인**(셀렉터까지 교체) → **fail-open**: RollingUpdate 중 신 파드가 pull에 실패하면
  (`image_spec=NEW`, `image_id=""`) 그 **실행되지 않는 파드**가 최신 digest와 매치돼 알림을 억제하는데, 실제
  서빙 중인 것은 구 파드다 → **진짜 드리프트를 놓친다**. plan 게이트 R-1이 지적했고 **실측으로 재현**했다
  (naive 픽스 적용 시 L9는 통과하지만 **L10이 죽는다**). 기각.
- ② exporter가 인덱스 대신 **arm64 자식 digest**를 push → 우변(`image_id`)이 인덱스 digest이므로 **오히려 전
  앱이 불일치**(더 나빠짐). 기각.
- ③ containerd 아티팩트를 해석해 정규화 → 관측 가능한 신호가 없다. 기각.

## Single-Flip Contract

**flip(하나)**: "파드가 핀한 digest = GHCR 최신"인데 **containerd `image_id`만 옛 인덱스**인 상태에서
`ImageDigestDrift`가 **발화하던 것 → 침묵**.

- **before**: 소스 무변경 재빌드 후 배포된 앱에 대해 영구 firing(오탐), 4시간마다 텔레그램 반복.
- **after**: 침묵. 콘텐츠가 실제로 같으니 알릴 것이 없다.

**변경 표면(`scope[]`)**: `platform/victoria-stack/prod/rules/r6-ci-staleness.yaml` **단 하나**.
(테스트 파일은 scope 밖 — B4는 비-테스트 경로만 본다.)

## Preserved Contract

`characterizationCmd`(drift e2e의 기존 8레그)가 고정하는 행위:

| 레그 | 보존되는 행위 |
|---|---|
| L1 | **진짜 드리프트**(배포 핀 = 옛 digest, GHCR = 새 digest)에서 **계속 발화** — `image_spec`도 옛 digest이므로 조인이 여전히 불일치 |
| L2 | 정상(핀 = 최신)에서 계속 침묵 |
| L3 | 정합적 이미지 bump 직후 phantom 무발화(rollup 윈도 계약) |
| L4 | **동결 결함 픽스처**(맨 참조 expr)는 여전히 발화 못 함 |
| L5 | 가짜 픽스(rollup 밖 `or absent()`)를 여전히 거부 |
| L7 | **KSM/스크레이프 장애**(우변 시계열 소멸) 시 전 앱을 "이미지 불일치"로 **오귀속하지 않음** — 존재 가드가 살아 있어야 한다(우변 셀렉터를 바꾸므로 **여기가 가장 위험한 회귀 지점**) |
| L8 | 과대 윈도(W=30m)가 phantom을 되살린다는 상한 계약 |
| **L10** | **막힌 롤아웃**(구 파드가 OLD 서빙 중 + 신 파드 ImagePullBackOff로 `image_id=""`)에서 **계속 발화** — plan 게이트 R-1이 지적한 fail-open을 락한다. `image_spec`-only 픽스는 여기서 죽는다(실측 확인) |

## Regression test (already RED at red.sha)

- **seam**: hermetic vmalert replay 하네스 `tests/gates/vmalert-drift-firing-e2e.sh`(배포 ConfigMap에서 룰
  바이트 추출 + 합성 KSM/GHCR 시계열 + `?max_lookback` 핀). 실물 클러스터 없이 룰의 **발화 여부**를 직접 측정한다.
- **신규 레그 L9(`attestation`)**: `ghcr_latest_digest{digest=NEW-index}` + 파드
  `image_spec=repo@NEW-index` / `image_id=repo@OLD-index` → **콘텐츠 동일**. vacuity 차단(대조 알림
  `ArgoCDOutOfSync`가 같은 replay에서 발화 + 백필 sanity).
- `regressionCmd`: `DRIFT_E2E_LEGS="L9" bash tests/gates/vmalert-drift-firing-e2e.sh`
- `characterizationCmd`: `DRIFT_E2E_LEGS="L1,L2,L3,L4,L5,L7,L8,L10" bash tests/gates/vmalert-drift-firing-e2e.sh`
- `symptomToken`: `ImageDigestDrift FIRED while the deployed content is identical`
- RED verify-record: `docs/reviews/image-digest-drift-false-positive/bugfix-verify-red-2423172…json`
  (스크립트 재실행 증명 — 회귀 `exit=1` + 증상 토큰, characterization `exit=0`).

## Increment plan

| id | what the fix does here | blocked-by | notes |
|---|---|---|---|
| **B-1** | **(a) 룰**(`scope[]`): r6 기록 룰 우변에서 **셀렉터는 `image_id=~"ghcr[.]io/…"` 그대로 두고**(materialization 가드), 두 `label_replace`(digest 추출·app 추출)의 **소스 라벨만 `image_spec`으로** 교체. `unless` 우변과 존재 가드 우변을 **바이트 쌍둥이로 동시에**.<br>**(b) 정적 게이트**(`tests/gates/test_digest-exporter.bats` — 테스트 파일이라 `scope[]` 밖): 현재 이 게이트는 **app 추출이 `image_id`에서 이뤄질 것**을 하드코딩해 단언한다(51행 `grep -q '"app", "$1", "image_id"'`, 72행 `lr="$(grep -oE '"app", "\$1", "image_id", …')`). 수정 후에는 red가 되므로 **B-1 안에서 함께 갱신**한다 — 새 단언: ①우변 셀렉터 2개가 **여전히 `image_id=~"ghcr…"`** 이고 서로 **동일**(materialization 가드 유지) ②digest 추출과 app 추출의 **소스가 `image_spec`** ③두 `label_replace` 블록이 여전히 **바이트 쌍둥이** | none | `first-increment`. plan 게이트 r2가 잡은 결합: (a)만 하면 (b)가 red가 되어 구현자가 계획을 이탈하거나 막힌다. ⚠️ 셀렉터까지 `image_spec`으로 바꾸면 L10(fail-open)이 죽는다 |

## Follow-up backlog

- **F-1**: 이 오탐이 60일 넘게 잠복하다 라이브에서 처음 드러난 이유는 **"코드 무변경 재빌드"가 드물었기 때문**이다.
  bump-poll이 **콘텐츠 동일 재빌드에도 새 인덱스 digest로 PR을 여는 것**(무의미한 배포 회전)이 별개 문제로 남는다
  → 별도 파이프라인(gated-pipeline/refactor) 후보.
- **F-2**: `tests/gates/vmalert-drift-firing-e2e.sh`의 공유 lib(`tests/gates/lib/vmalert-e2e.sh`) 이관은
  여전히 백로그(F-5) — 이번 수정에서 건드리지 않는다.

## Review Decision Log

### Landing — PR #358 머지(`61ccae7`) · 라이브 검증 통과 (2026-07-13/14)

라이브 기록: `docs/reviews/image-digest-drift-false-positive/live-verification.md`

- vmalert가 수정 룰을 로드(`app:image_digest_drift`의 조인 소스 = `image_spec`) 확인.
- **`lastSamples=0`** — 기록 룰이 page를 더는 드리프트로 판정하지 않는다 → 2분 뒤 **알림·기록 시리즈 모두 0**.
- 다른 알림 오발화 0(firing = Watchdog뿐). 롤백 불필요.

### Codex Release Review — **판정 미획득(review-incomplete ×6) → owner waive** (2026-07-13)

**사실**: release 게이트를 6회 시도했고 전부 `status: review-incomplete`, `parseError:
"Selected model is at capacity. Please try a different model."` 로 실패했다 —
기본 모델 `gpt-5.6-sol` ×4(12분 간격 백오프 포함), 대안 모델 4종 ×1(전부 이 ChatGPT 계정에서
`not supported` — 지원 모델은 `gpt-5.6-sol` 단 하나), reasoning effort를 `xhigh → high`로 낮춰 ×1.
같은 시점에 codex 단순 호출은 정상 응답했다(모델 자체 장애가 아니라 **대용량·장시간 리뷰 요청의 용량 차단**).
아티팩트 `docs/reviews/image-digest-drift-false-positive/release-r1.json`에 그 상태가 기록돼 있다.

**owner 결정(2026-07-13)**: **잔여 리스크를 waive하고 랜딩한다.** 근거:

| 확보된 증거 | 상태 |
|---|---|
| plan 게이트 | **approve**(r3) — 3라운드에서 **실제 결함 2건**을 잡았다(`image_spec`-only 조인의 fail-open, 정적 게이트와의 결합) |
| structure 게이트 | **approve**(r1, 발견 0) — anti-cheat(테스트 약화·characterization 삭제·증상 특례화) 통과 |
| **flip 증명** | **스크립트가 두 SHA를 체크아웃해 재실행** — 회귀 FAIL@red(`e9b69c3`) → PASS@green(`f9e7381`), characterization 양쪽 green, repro gone |
| 보존 계약 | 8레그 green — 특히 **L10**(막힌 롤아웃 = fail-open 없음)·**L7**(KSM 장애 오귀속 없음) |
| 단일 flip 표면 | 비-테스트 변경 **1파일**(r6 룰) = `scope[]` |
| 롤백 | 룰 revert 1회(라이브 영향 = 알림 룰 하나, 데이터 위험 0) |

**waive되는 것**: 브랜치 전체에 대한 codex의 최종 적대 리뷰 1회. 그것이 새로 잡을 표면은 위 게이트들이
이미 덮은 영역과 대체로 겹친다(단일 룰 변경 + 테스트).

**잔여 리스크**: 라이브에서 이 룰이 예상과 다르게 동작할 가능성. 랜딩 후 **즉시 라이브 검증**으로 상쇄한다
(오탐 resolve 확인 + `app:image_digest_drift` 시리즈 확인). 실패 시 룰만 revert.

### Codex Structure Review — r1: clean — **approve**(발견 0) (2026-07-13)

아티팩트: `docs/reviews/image-digest-drift-false-positive/structure-r1.json`. B-1이 PromQL 조인 seam에서
정체성 공간 불일치를 고쳤고, RED L9 테스트를 건드리지 않았으며, `image_id` materialization 가드를 보존하고,
선언된 scope 안에 머문다.

### Codex Plan Review — r3: clean — **approve**(발견 0). "Ship the plan." (2026-07-13)

아티팩트: `docs/reviews/image-digest-drift-false-positive/plan-r3.json`. B-1이 룰 변경과 정적 게이트 갱신을
결합해 r2를 해소했고, 쌍둥이 `image_id` 셀렉터를 정확히 보존하면서 digest/app 추출만 `image_spec`으로 옮긴다.
`e9b69c3`의 RED 증거가 L9 및 L10 보존 계약과 정합한다.

### Codex Plan Review — r1: needs-attention → 1건 Accept (owner 2026-07-13)

아티팩트: `docs/reviews/image-digest-drift-false-positive/plan-r1.json`(reviewedSha `9234a0d`).

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-2 | high | `B-1 cannot pass the gate it names without an undeclared test change` — 정적 게이트 `test_digest-exporter.bats`가 **app 추출을 `image_id`에서 할 것**을 하드코딩 단언한다(51·72–74행). 룰만 고치면 그 게이트가 red가 되어 구현자가 계획을 이탈하거나 막힌다 | **Accept** | B-1을 **(a) 룰 + (b) 정적 게이트 갱신** 2부로 명시. 새 단언: 우변 셀렉터는 여전히 `image_id`(쌍둥이 동일) · 추출 소스는 `image_spec` · 두 `label_replace`는 여전히 바이트 쌍둥이 |
| R-1 | high | `Blocker: the spec-only selector lets a non-running replacement suppress real drift` — RollingUpdate 중 신 파드가 pull에 실패하면 KSM이 `image_spec=NEW` + **`image_id=""`** 를 내보내는데, `image_spec`-only 조인은 그 **실행되지 않는 파드**로 알림을 억제한다(실제 서빙은 구 파드) → **진짜 드리프트를 놓치는 fail-open**. L1·L9는 단일 파드 시나리오라 이 두 번째 flip이 무방비 | **Accept** | Codex의 더 단순한 대안 채택: **`image_id` 셀렉터를 materialization 가드로 유지**하고 `label_replace`의 **소스 라벨만** `image_spec`으로 교체. 보존 계약 레그 **L10**(막힌 롤아웃)을 red.sha에 추가해 락(characterization)에 편입 — naive 픽스를 적용하면 **실제로 L10이 죽는 것을 실측 확인**했다 |
