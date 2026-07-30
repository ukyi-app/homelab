# 진단 — 반복 발화하는 3건의 알림 (alert-stale-firing)

작성: 2026-07-30 · 증상: `KubeJobFailed`(adguard) 1건 + `GHAWorkflowStale`(bump-poll·tf-reconcile) 2건이
계속 재전송된다.

**결론 먼저: 세 알림 모두 오탐이다. 라이브 시스템은 정상이다.** 그러나 오탐의 근본 원인은 서로 다른
**두 개의 독립 결함**이며, 둘 다 알림 룰/예산의 설계 오류다. 감시 대상 인프라는 건강하다.

---

## 결함 A — `KubeJobFailed`는 이미 해소된 과거 실패를 영구히 발화한다

### 근본 원인

룰(`platform/victoria-stack/prod/rules/core.yaml:187`)은 실패 **사건**을 재려 하지만 실제로는 실패 Job
**오브젝트의 존재**를 재고 있다.

```
kube_job_failed{condition="true", namespace!~"kube-system|…", job_name!~"cnpg-local-basebackup.*|…"} > 0
for: 15m
```

`kube_job_failed`는 Job 오브젝트가 클러스터에 남아 있는 한 계속 `1`이다 — 시간 개념이 없다. 그 오브젝트의
수명은 `failedJobsHistoryLimit`이 지배하는데, 그 회수는 **뒤이은 실패가 더 쌓여야만** 일어난다. 즉
**정상 운영(= 이후 전부 성공)일수록 실패 Job이 영원히 남는다.** `for: 15m`은 "실패가 15분간 지속됐다"가
아니라 "실패 Job 오브젝트가 15분간 존재했다"만 증명한다. 이것이 룰 주석의 문장("Job이 실패 상태로 15분
이상 머뭅니다")과 실제 의미가 갈라지는 지점이다.

클러스터의 **모든 CronJob에 `ttlSecondsAfterFinished`가 없다**(8개 전부 `<none>`) — 회수 경로가 하나도 없다.

### 증거 (red)

```console
$ kubectl get jobs -n edge
NAME                                  STATUS     COMPLETIONS   DURATION   AGE
adguard-rewrite-reconciler-29751320   Failed     0/1           3d1h       3d1h   ← 3일 전 1회 실패
adguard-rewrite-reconciler-29755760   Complete   1/1           5s         82s    ← 82초 전 성공

$ curl -s .../api/v1/alerts   # vmalert
firing  KubeJobFailed  adguard-rewrite-reconciler-29751320  activeAt=2026-07-26T15:26:00Z
```

**3일 넘게 연속 firing.** 그 사이 이 CronJob(`*/10`)은 약 430회 성공했다. 메트릭이 그 사실을 알고 있다:

```console
kube_job_status_start_time{job_name="adguard-rewrite-reconciler-29751320"}      = 1785079499  (07-26 15:24:59Z)
kube_cronjob_status_last_successful_time{cronjob="adguard-rewrite-reconciler"}  = 1785345605  (3.08일 뒤)
kube_job_owner{job_name="…-29751320"}  → owner_kind=CronJob, owner_name=adguard-rewrite-reconciler
```

즉 **"이 정기 작업은 그 실패 이후 성공했다"를 표현할 재료가 이미 전부 수집되고 있는데 룰이 쓰지 않는다.**

### 최초 실패 자체는 진짜 고장이 아니었다 (기여 요인)

```console
$ kubectl logs -n edge adguard-rewrite-reconciler-29751320-mwg9g
curl: (6) Could not resolve host: kubernetes.default.svc
traefik-ts LB IP 추출 실패
```

3일 전 노드 재시작 직후(관측성 파드 전체가 `RESTARTS … (3d1h ago)`) CoreDNS 미준비 구간에 걸린
일시적 DNS 해석 실패다. 리컨실러의 `CURL`은 `--retry 3 --retry-connrefused`를 갖지만, **curl의 `--retry`는
DNS 해석 실패(exit 6)를 재시도하지 않는다**(`--retry-all-errors` 필요). `backoffLimit: 0`이라 단발 실패가
곧 Job Failed다. 설계 주석은 connrefused와 4xx만 고려했고 DNS 해석 실패는 고려 밖이었다.

이는 **재발 빈도를 높이는 기여 요인**이지 근본 원인은 아니다 — 어떤 종류의 일시적 실패든 결과는 같은
영구 알림이다. 재부팅은 정기적으로 일어나므로(호스트 uptime 가드 운영) 이 경로는 다시 열린다.

### 노출 범위

`job_name!~` 블랙리스트로 제외된 백업 3종을 뺀 **모든 CronJob**이 같은 결함에 노출된다 —
`adguard-rewrite-reconciler`(2), `digest-exporter`(1), `gha-liveness-exporter`(1), `pvc-du-exporter`(2),
`cache-backup`(3). 한 번의 일시적 실패가 영구 페이지가 된다.

---

## 결함 B — `GHAWorkflowStale` 예산이 선언 cron에서 파생됐는데 GitHub은 그 cron을 지키지 않는다

### 근본 원인

`platform/victoria-stack/prod/gha-liveness-exporter.yaml`의 `WORKFLOWS`는 워크플로별 나이 예산을
**선언된 cron 주기 × N**으로 잡는다. 게이트
`tests/gates/test_gha-liveness-exporter.bats:every age budget is at least three cron periods`가
`budget >= 3 × cron_period`를 강제한다.

**전제가 틀렸다: 선언 cron은 실제 실행 간격의 대리 변수가 아니다.** GitHub Actions 스케줄러는 짧은
주기를 그대로 실행하지 않는다 — 실측 하한이 약 49분이다. `*/10`이든 `*/30`이든 실제 도달 간격은
사실상 **같은 분포**를 따른다. 그래서 주기가 짧을수록 예산과 현실의 괴리가 커진다.

### 증거 (red) — 성공 run 59건, 4일치 실측

```console
$ gh run list --workflow=<wf>.yaml --event=schedule --status=success --limit 60 → 인접 간격 분포

워크플로            선언 cron    min     p50     p90      MAX          현재 예산   판정
bump-poll.yaml      */10 (600s)  3103s   4996s   10649s   13001s(3.6h)  3600s     p50조차 초과 → 상시 발화
tf-reconcile.yaml   */30 (1800s) 2936s   5549s   11484s   14120s(3.9h)  10800s    p90 초과 → 간헐 발화
pr-sweeper.yaml     */30 (1800s) 3427s   5243s   11793s   14134s(3.9h)  10800s    동일 결함 · 아직 미발화
dns-drift.yaml      23 */6       —       —       —        30537s(8.5h)  86400s    여유 55863s → 안전
```

**bump-poll은 예산 3600s가 실측 중앙값 4996s보다도 작다** — 시간의 절반 이상 조건이 참이다. 라이브 확인:

```console
$ vmalert /api/v1/alerts
pending  GHAWorkflowStale  bump-poll.yaml  activeAt=2026-07-29T17:00:00Z

$ (time() - last_over_time(gha_workflow_last_success_timestamp[3h])) - last_over_time(gha_workflow_max_age_seconds[3h])
bump-poll.yaml     over_budget_by = +1474s      ← 초과 중 (마지막 성공은 불과 84분 전)
tf-reconcile.yaml  over_budget_by = -6620s
```

이 시점 bump-poll의 마지막 성공은 **3분 전**(`2026-07-29T17:18:07Z`)이었고 워크플로는 `active`다. 즉
**정상 동작 중인 워크플로를 두고 발화**한다.

### 게이트가 통과시킨 이유가 곧 결함의 정체

게이트는 하한 `budget >= 3 × cron_period`만 본다. bump-poll은 `3 × 600 = 1800s` 하한을 만족(3600s)하지만
현실이 요구하는 값은 13001s — **하한의 7배**다. 검사식의 기준량(cron 주기)이 현상(GitHub 스케줄 지연)과
무관하므로, 이 게이트는 통과 여부와 무관하게 오탐을 막지 못한다.

### 정정 대상

짧은 주기 3종만 해당한다 — `bump-poll`(3600), `tf-reconcile`(10800), `pr-sweeper`(10800). 긴 주기
워크플로는 GitHub 지연(~4h)이 예산에 비해 작아 영향이 없다(dns-drift 여유 15.5h, audit·renovate 등 동일).

---

## Seam

두 결함은 파일·메커니즘·수정 종류가 전부 다르므로 회귀 테스트도 각각 별도다.

- **결함 A**: `tests/gates/vmalert-jobfailed-firing-e2e.sh` (신규) — 기존 발화 e2e 패턴
  (`vmalert-drift-firing-e2e.sh` + `vmalert-drift-gen.py`)을 따르고 `Makefile:178`의
  `git ls-files 'tests/gates/vmalert-*-firing-e2e.sh'` 열거에 자동 편입된다.
  락할 레그: **(1)** 실패 Job 이후 CronJob이 성공한 픽스처 → `KubeJobFailed` **발화 부재**(현재 red),
  **(2)** 실패 후 성공이 없는 픽스처 → **발화 존재**(억제가 진짜 실패를 삼키지 않음을 증명하는 fail-open 거울상),
  **(3)** CronJob 소유가 아닌 단발 Job의 실패 → **발화 존재**(기존 백스톱 보존).

- **결함 B**: `tests/gates/test_gha-liveness-exporter.bats` —
  기존 `@test "every age budget is at least three cron periods (single miss must not page)"`가 결함의
  본체다. 실제 관측된 스케줄 지연을 반영하는 하한으로 교체/보강한다(선언 cron이 아니라 GitHub이 실제로
  달성하는 간격이 기준량이어야 한다). 현재 3종의 예산이 red가 되어야 한다.

---

---

## 구현 중 드러난 것 — lint의 false positive가 결함 A 수정을 막고 있었다

결함 A의 억제 절은 `kube_job_owner`로 job↔owner를 잇는 **many-to-one 조인**이라 `group_left`가 문법적으로
필수다. 그런데 `tools/check-alert-rules.ts`의 모드 B가 `on(...)` 뒤의 rhs를 읽을 때
**`group_left(...)` 매칭 수식어를 피연산자의 시작으로 읽어**, 정상적으로 `max by (...)`로 사전 집계된
우변을 raw 셀렉터로 오판했다.

이 오판은 조용하지 않다 — many-to-one 조인은 group_left 없이 표현할 수 없으므로 그 형태를 쓰는 룰은
전부 allowlist로 밀려나고, **allowlist는 룰 단위라 모드 A/C 검사까지 함께 꺼진다.** 즉 lint를 고치지
않으면 결함 A의 수정은 배포 불가이거나, 배포하는 대신 그 룰의 다른 검사를 전부 끄는 대가를 치른다.

따라서 lint 수정(`GROUP_MOD_RE`로 수식어만 벗기고 그 뒤 피연산자는 그대로 판정)은 **결함 A 수정을
성립시키는 필수 부수 작업**이지 별도 범위가 아니다. 회귀는 두 방향으로 잠갔다 — 집계된 우변은 통과하고,
`group_left` 뒤의 **raw** 우변은 여전히 red다(수식어 건너뛰기가 검사 구멍으로 퇴화하지 않는다).

한편 lint가 제기한 문제 자체는 옳았다: 사전 집계 없는 raw 조인은 KSM 시리즈가 잠깐이라도 겹칠 때
many-to-many가 되어 **422로 룰 평가가 통째로 죽는다** — 알림이 틀리는 게 아니라 사라진다. 수정된 expr은
세 피연산자를 모두 `max by (...)`로 집계한다.

---

## ⚠️ 범위 판정 — `/bugfix`의 단일 flip 제약 초과 → **사용자 승인으로 해소됨**

확정된 근본 원인이 **2개**이고, 각각 다른 파일에서 **서로 독립적인 동작을 flip**한다:

1. `platform/victoria-stack/prod/rules/core.yaml` — `KubeJobFailed` 룰에 해소 조건 추가
2. `platform/victoria-stack/prod/gha-liveness-exporter.yaml`(+ 게이트 공식) — 예산 산정 기준량 교체

`/bugfix` Stage 2는 "정확히 하나의 관찰 가능한 동작이 flip"을 요구하며, 초과 시 STOP하고 `/feature`
또는 `/deepen`으로 넘기도록 규정한다.

**Stage 1 게이트에서 이 초과를 사용자에게 명시적으로 제시했고, 사용자가 "두 결함 모두 이번에 수정"을
선택해 단일 flip 제약을 명시적으로 완화했다**(분리 릴리스는 선택지로 제시됐고 반려됐다). 전문·근거는
같은 디렉토리의 `decisions.md` 「범위 승인」 절이 원장이다. 근거 요약: 두 결함이 같은 증상(알림 오탐
반복)을 내고, 사용자가 겪는 문제는 둘 다 고쳐야 멈춘다.

**검증·롤백 표면은 flip별로 분리해 둔다** — 하나가 문제를 일으켜도 다른 하나를 되돌릴 필요가 없다:

| flip | 제품 변경 | 회귀 seam | 독립 롤백 단위 |
|---|---|---|---|
| A (KubeJobFailed) | `rules/core.yaml`의 `unless` 절 | `tests/gates/vmalert-jobfailed-firing-e2e.sh` (L1/L2a/L2b/L3/L4/L5) | 그 절만 제거하면 이전 동작 |
| B (GHA 예산) | `gha-liveness-exporter.yaml`의 `WORKFLOWS` 3값 | `tests/gates/test_gha-liveness-exporter.bats` (lag-ceiling 테스트) | 그 3값만 되돌리면 이전 동작 |

두 seam은 서로를 참조하지 않으며, 공통 테스트로 묶지 않았다.
