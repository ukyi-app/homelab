---
bugfix: image-digest-drift-false-positive
invariant-class: bugfix
entry-track: incident
review-track: standard
pipeline-stage: red-capture
issue-tracker: local
worktree:
branch: fix/image-digest-drift-false-positive
consent-scope:
symptom: "ImageDigestDrift{app=\"page\"}가 라이브에서 firing 중 — 그러나 배포된 컨테이너는 GHCR 최신과 바이트 동일한 arm64 이미지를 서빙하고 있다(실제 드리프트 없음). warning 라우트라 4시간마다 텔레그램 반복 통보되고, 진짜 드리프트가 나도 구분 불가."
red-baseline: e9b69c3cdc5d3b96c8dd1a9ea54c6c91ae81c3b0
bugfix-lock: red
spike-1:
---

## Track note

**증상(라이브 2026-07-13)**: `ImageDigestDrift{app="page"}` firing. 그러나 실제로는 드리프트가 없다.

**근본 원인(실물 프로브로 확정)**:

| 층 | 값 |
|---|---|
| GHCR 최신(= exporter의 `ghcr_latest_digest`, skopeo가 태그에서 읽는 값) | **인덱스** digest `sha256:98db4e11…` |
| 파드 spec / values 핀 (KSM `image_spec`) | `sha256:98db4e11…` — **일치** |
| containerd가 보고하는 `imageID` (KSM `image_id`) | `sha256:54211c26…` — **구 인덱스** digest |
| 구 인덱스의 arm64 자식 매니페스트 | `sha256:d68dbeb6…` |
| 신 인덱스의 arm64 자식 매니페스트 | `sha256:d68dbeb6…` — **동일** |

즉 **arm64 이미지는 바이트 동일**하고 **attestation 매니페스트만 다르다**(buildx가 push하는 OCI 인덱스에
provenance/SBOM attestation이 붙는데 이는 비결정적이라 소스 무변경 재빌드에도 인덱스 digest가 바뀐다).
containerd는 동일 콘텐츠를 이미 갖고 있어 **최초 저장 시점의 repo digest**를 `imageID`로 계속 보고한다.

`app:image_digest_drift` 기록 룰은 `ghcr_latest_digest`(신 인덱스)와 KSM **`image_id`**(구 인덱스)를
`unless on (app, digest)`로 조인하므로 **영구 불일치 → 영구 firing**. trip-mate-api는 재빌드에서 콘텐츠가
실제로 바뀌어 새로 pull됐기에 일치한다 — 즉 이 오탐은 **"코드 변경 없이 재빌드된 앱"에서만** 발현한다.

**단일 flip**: 콘텐츠가 동일한데(파드 spec 핀 = GHCR 최신) 발화하던 오탐 → **침묵**. 진짜 드리프트
(배포 핀 ≠ GHCR 최신)는 **계속 발화**한다(보존 계약).

**Fork A**(정확한 seam 존재 — 룰 expr의 조인 대상 라벨). 아키텍처 문제 아님 → gated-refactor 아님.

**seam**: 기존 hermetic 발화 e2e 하네스 `tests/gates/vmalert-drift-firing-e2e.sh`(vmalert replay).
"콘텐츠 동일 + 인덱스 digest만 다름" 레그를 추가하면 **현행 룰에서 RED**(발화), 수정 후 **GREEN**(침묵).
기존 레그(진짜 드리프트 발화 / 정상 침묵 / 결함 픽스처)가 characterization이다.
