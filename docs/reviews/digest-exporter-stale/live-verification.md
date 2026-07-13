# Live Verification — digest-exporter-stale (랜딩 후)

머지: PR #355 → `main` `bbc9bde` · ArgoCD 싱크 완료 **09:18:09 UTC** (2026-07-13)
이 파일은 **리뷰된 브랜치 밖**의 운영 기록이다(release freshness 무효화 방지 — release 게이트 r1의 R-2 지적).

## ① 싱크 직전 레거시 Job 활성 여부 (`Replace` 전이 관측)

```
$ kubectl get jobs -n observability -l app.kubernetes.io/name=digest-exporter
digest-exporter-29732210   2026-07-13T08:50:00Z   완료(ACTIVE=none)
digest-exporter-29732220   2026-07-13T09:00:00Z   완료(ACTIVE=none)
digest-exporter-29732230   2026-07-13T09:10:00Z   완료(ACTIVE=none)
```

**활성 Job 없음** → `Forbid → Replace` 전이 경로는 **이번 랜딩에서 발생하지 않았다**(정직한 기록:
전이 자체는 관측되지 않았고, 매니페스트 선언만 확인됐다). plan 게이트 r7에서 owner가 Reject+waive한
"레거시 Job 전이 테스트"의 잔여 리스크는 그대로 남아 있다.

```
$ kubectl get cronjob digest-exporter -n observability -o jsonpath='{.spec.concurrencyPolicy} ADS={...activeDeadlineSeconds}'
Replace  ADS=180        ← 배포 확인
```

## ② 후속 Job + ③ 첫 하트비트 실측 지연 (강제 상한 840s 대비)

| 시각(UTC) | 사건 |
|---|---|
| 09:18:09 | ArgoCD 싱크 완료(`bbc9bde`) |
| 09:20:00 | 신규 스크립트 첫 Job(`digest-exporter-29732240`, uid `f1121db4-…`) 시작 |
| **09:20:04** | **첫 하트비트 적재**(`digest_exporter_last_success_timestamp = 1783934404`) |

- **실측 첫 하트비트 지연 = 115초**(싱크 → 적재). **강제 상한 840초의 13.7%** — 여유 725초.
- Job 실행 시간 = **4초**(크론 경계 09:20:00 → push 09:20:04). `activeDeadlineSeconds: 180`의 2.2%.
- 인-데드라인 예산(`60 + 2×10 + 30 + 10 = 120 < 180`)이 실측과 정합적이다.

## ④ 메트릭 적재 + 거짓 페이지 없음 (L7의 라이브 확인)

```
last_over_time(digest_exporter_last_success_timestamp[2h]) → 1783934404 (나이 77초)
last_over_time(digest_exporter_apps_configured[2h])        → 2
last_over_time(digest_exporter_apps_scraped[2h])           → 2
ALERTS{alertname=~"DigestExporter.*"}                       → EMPTY  ← pending도 firing도 없음
```

**최초 배포가 거짓 페이지를 내지 않았다** — e2e L7이 hermetic하게 증명한 성질(`for: 15m` > 강제 상한
840s)이 라이브에서 그대로 확인됐다(실측 지연 115s ≪ 900s).

## ⑤ Alertmanager 제목 매핑 (release 게이트 R-4)

```
# 재기동 전(실행 중 파드의 렌더된 설정)
$ kubectl exec deploy/alertmanager -c alertmanager -- grep -c DigestExporter /etc/alertmanager/alertmanager.yml
0        ← ConfigMap은 갱신됐으나 실행 중 파드는 옛 설정(= R-4가 지적한 바로 그 상태)

$ kubectl rollout restart deploy/alertmanager -n observability   # 랜딩 절차의 필수 스텝
deployment "alertmanager" successfully rolled out

# 재기동 후
$ kubectl exec deploy/alertmanager -c alertmanager -- grep -c DigestExporter /etc/alertmanager/alertmanager.yml
2        ← 매핑 적용됨
```

R-4의 진단이 **라이브에서 실증**됐다(ConfigMap → emptyDir initContainer 경로는 reloader가 없어 파드
재기동 전까지 옛 설정을 쓴다). 항구적 해결은 Follow-up **F-8**(checksum/reloader).

## ⑥ vmalert 룰 로드

```
$ curl vmalert/api/v1/rules
DigestExporterStale            → LOADED
DigestExporterScrapeIncomplete → LOADED
총 룰 수: 43
```

## 별건 관찰 — `ImageDigestDrift`가 firing 중 (이 기능과 무관)

```
app:image_digest_drift{app="page"} = 1
```

`page` 앱의 GHCR 최신 digest와 배포된 digest가 **실제로 다르다**. 이 기능이 만든 것이 아니라, 이번
세션에 살려낸 `ImageDigestDrift`(#339)가 **실제 드리프트를 정상 탐지**하고 있는 것이다(bump-poll
사이클 중이거나 배포가 뒤처진 상태). **별도 확인 필요** — 이 PR의 롤백 사유가 아니다.

## 판정

랜딩 성공. 원인별 롤백 조건(하트비트 미발행·`ghcr_latest_digest` 정지·거짓 페이지) **어느 것도
발생하지 않았다**. 롤백 불필요.
