# Live Verification — image-digest-drift-false-positive (랜딩 후)

머지: PR #358 → `main` `61ccae7` · ArgoCD `victoria-stack` Synced(rev `61ccae7`) · 2026-07-13/14

## 배포 전파

| 단계 | 확인 |
|---|---|
| ConfigMap → vmalert 파드 마운트 | `grep -c image_spec /rules/r6/r6.yaml` → **11** (전파됨) |
| vmalert 룰 reload(`configCheckInterval=30s`) | `/api/v1/rules`의 `app:image_digest_drift` 조인 소스 → **`image_spec`** (구 `image_id` 아님) |

## 오탐 해소 (단일 flip의 라이브 증명)

```
# reload 직후
app:image_digest_drift   health=ok  lastSamples=0   ← 기록 룰이 더 이상 샘플을 만들지 않는다
ImageDigestDrift         state=firing lastSamples=1 ← 룩백(5m) 안에 남은 마지막 샘플로 아직 유지

# 2분 뒤
record 시리즈 = 0 · ImageDigestDrift 알림 = 0   ← ✅ 오탐 완전 해소
```

`app:image_digest_drift`의 `lastSamples=0`이 결정적이다 — **룰이 page를 더 이상 드리프트로 판정하지
않는다**(파드가 선언한 핀 `image_spec`(`sha256:98db4e11…`)이 GHCR 최신 인덱스와 일치하므로 `unless`가
지운다). 남아 있던 알림은 마지막 기록 샘플이 instant 룩백 밖으로 빠지면서 resolve됐다.

## 보존 확인

- `firing` 알림 목록에 **`Watchdog`만** 남았다(다른 알림 오발화 0).
- exporter 자기관측(직전 기능 #355)도 정상: `digest_exporter_apps_scraped = 2` / `_configured = 2`,
  하트비트 신선(수백 초 이내).
- 진짜 드리프트 발화 능력은 hermetic e2e 8레그(특히 **L1**·**L10**)가 락하고 있다 — 라이브에서 진짜
  드리프트를 인위로 만들지는 않았다(정직한 공백).

## 판정

랜딩 성공. 롤백 불필요.
