# Verification — image-digest-drift-false-positive

red.sha `e9b69c3` → green.sha `f9e7381` · 2026-07-13 · 증거는 **스크립트(`bugfix-status.mjs --verify-flip`)가
두 SHA를 실제로 체크아웃해 재실행**한 결과다(주장 아님).

## RED→GREEN flip (B2 배리어)

| | red.sha `e9b69c3` | green.sha `f9e7381` |
|---|---|---|
| **회귀**(`DRIFT_E2E_LEGS="L9"`) | **exit 1 (FAIL)** — 증상 토큰 `ImageDigestDrift FIRED while the deployed content is identical` 존재 | **exit 0 (PASS)** — 오탐 침묵 |
| **characterization**(`L1,L2,L3,L4,L5,L7,L8,L10`) | exit 0 (green) | exit 0 (green) |
| repro | 재현됨 | **사라짐** |

verify-record: `bugfix-verify-red-400c1b0e….json` · `bugfix-verify-green-410ca865….json`(둘 다 커밋).

## 단일 flip (B4 배리어)

`git diff e9b69c3..f9e7381`의 **비-테스트 변경**:
```
platform/victoria-stack/prod/rules/r6-ci-staleness.yaml   ← scope[]의 유일 항목
```
(테스트/문서 외 다른 소스 변경 0.)

## 보존 계약이 실제로 지켜졌는가 (green.sha에서 재실행)

| 레그 | 결과 |
|---|---|
| L1 진짜 드리프트 | **firing=191** — 계속 발화 ✓ |
| L2 정상 | series=0 — 침묵 ✓ |
| L3 정합적 bump | firing=0 — phantom 없음 ✓ |
| L4 동결 결함 픽스처 | firing=0(pending=132) — 여전히 못 움 ✓ |
| L5 가짜 픽스 | firing=0(pending=254) — 여전히 거부 ✓ |
| **L7 KSM 장애** | firing=0 — 전 앱 오귀속 없음 ✓(**우변 셀렉터를 건드렸으므로 최대 위험 지점**) |
| L8 과대 윈도 | firing=19 — 상한 계약 유지 ✓ |
| **L10 막힌 롤아웃** | **firing=191** — **fail-open 없음** ✓(plan 게이트 R-1이 예측한 함정) |

## 미검증으로 남는 것

- **라이브**: 머지 후 ArgoCD 싱크 → vmalert reload → `ImageDigestDrift{app="page"}`가 **resolve**되는지
  실측(현재 firing 중). `live-verification.md`에 기록한다.
