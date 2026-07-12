---
feature: digest-exporter-stale
invariant-class: feature
entry-track: feature
review-track: full
pipeline-stage: intake
issue-tracker: local
prd-published: false
worktree:
branch: feat/digest-exporter-stale
consent-scope:
inbound-issue:
intake-grill:
spike-1:
---

## Track note

**Rule 0**: net-new 관측 행위가 **2개 이상** 새로 생긴다 — (a) digest-exporter가 자기관측
하트비트/카운트 메트릭을 push, (b) 새 `DigestExporterStale` 알림이 발화. → `invariant-class: feature`
(단일 flip이 아니므로 gated-bugfix 아님; 행위 추가이므로 refactor/perf/migration 아님).

**review-track: full** — 알림 룰 클래스는 이 레포에서 4번 재발했고(메모리 alert-instance-label-churn),
방금 이 세션에서 3번 더 뚫렸다(모드 C 적대 검증). skeleton 슬라이스(하트비트 push + 발화 e2e)가
구조 게이트의 정확한 대상이다.

**진행 순서**: intake→prd는 지금 진행. **executing은 모드 C PR(#343) 머지 후 main에서** 시작한다 —
이 기능의 (a) 새 메트릭은 모드 C 완전성 가드 대상이라 린터 레지스트리 등재가 필요하고, (b) 발화 e2e
하네스가 #343의 공유 lib(`tests/gates/lib/vmalert-e2e.sh`)을 재사용하기 때문이다. 브랜치는 머지 후 rebase.

## 배경 — 이번 세션의 죽은-알림 3부작을 잇는 마지막 조각

방금 죽은 알림 2건을 살렸다(ImageDigestDrift #339 · FilesBulkSSDLow #341) + 재발 방지 정적 린터
(모드 C #343, 머지 중). 그런데 **살린 ImageDigestDrift의 먹이 공급선 자체가 무방비**다.

`platform/victoria-stack/prod/digest-exporter.yaml`(CronJob `*/10`)은 **자기 생존을 알리는 하트비트가
없다** — `ghcr_latest_digest`(정보 게이지)만 push한다. 조용한 실패 3모드(코드 확인):

| 모드 | 코드 | 결과 |
|---|---|---|
| skopeo 실패(GHCR 장애·ghcr-read 토큰 만료) | `DIGEST=$(skopeo … \|\| true)` + `[ -z "$DIGEST" ] && continue` | **그 앱만 조용히 스킵** |
| 전체 push 실패 | `curl … \|\| echo "push failed" >&2` | **Job은 여전히 exit 0** |
| CronJob 미실행 | — | 메트릭 전체 정지 |

어느 경우든 `ghcr_latest_digest`가 사라지고, rollup으로 살린 `ImageDigestDrift`도 **원본 시리즈가
없어 다시 침묵**한다. `KubeJobFailed`(core.yaml)는 `kube_job_failed{condition="true"}`만 봐서
**초록 Job(부분/전체 push 실패)은 못 잡는다**.

## 요구 기능 (net-new)

1. **자기관측 메트릭 push**: 형제 선례(`restore_drill_last_success_timestamp`·
   `files_backup_last_success_timestamp`)를 따라 `digest_exporter_last_success_timestamp`.
   **부분 실패도 구분하려면** scrape 성공/전체 카운트(`digest_exporter_apps_total` /
   `..._scraped` 류) — 전체 push는 됐는데 앱 절반이 skopeo 실패한 경우.
2. **`DigestExporterStale` 알림 신설**: 형제 staleness 패턴(`time() - last_over_time(ts[윈도]) > 임계
   or absent(...)`, fail-closed). ⚠️ 하트비트는 push 메트릭(10분 주기)이니 **rollup 필수** — 방금
   만든 함정을 그대로 밟지 말 것. ⚠️ 새 메트릭은 **모드 C 완전성 가드 대상** → 린터 레지스트리 등재 필수.

## 참고 (형제 선례 = 정답 형태)

- `platform/cnpg/prod/restore-drill-script.sh`(하트비트 push) + r4 `CNPGRestoreDrillStale`
- `scripts/backup-files-data.sh`(`push_metrics`) + r4 `FilesBackupStale`
- r4-storage-backup.yaml `PvcDuExporterStale`(저빈도 push staleness 알림)
- 이 세션 산물: 모드 C 린터 · 발화 e2e 하네스(`tests/gates/vmalert-*-firing-e2e.sh` + `lib/vmalert-e2e.sh`)
- 흡수하는 백로그: image-pin 리팩터 F-1 · files-bulk-ssd F-3(exporter 조용한 실패 fail-loud화) —
  이 기능이 그 방향과 겹친다.

## 열린 설계 질문 (intake에서 결정)

- 부분 실패를 **하트비트 하나로** 다룰지(전체 실패 시에만 timestamp 미갱신) vs **카운트 메트릭 추가**로
  앱 단위 실패까지 잡을지. 후자가 더 정확하나 exporter 스크립트 복잡도가 오른다.
- staleness 임계·윈도: `*/10` 주기이므로 rollup 윈도 `[2h]`류(형제 `AdguardRewriteReconcilerStale`과
  동형) + 임계 ≈ 3주기 누락(30~40분). severity(warning vs critical — 이건 감시견의 감시견이라 warning이
  적절해 보이나 논의).
- exporter의 조용한 실패 자체를 **fail-loud화**(F-1/F-3)까지 이 기능에 포함할지, 아니면 하트비트+알림만.
