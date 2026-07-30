# 만성 flapping 탐지 — `CronJobFlapping` (S-6 후속)

`#401`이 `KubeJobFailed`에 "실패 이후 소유 CronJob이 성공하면 억제" 절을 넣어 해소된 과거 실패의
영구 발화를 닫았다. 그 대가로 자체 감사가 지목한 갭이 남았고(S-6), 이 작업이 그 갭을 닫는다.

## 갭 — 교대 실패는 어떤 알림에도 잡히지 않는다

CronJob 주기 P가 `for:`(900s)보다 짧으면 실패 Job은 최대 P초 만에 억제되므로 `for:`를 **원리적으로
채우지 못한다.** 즉 실패↔성공이 교대하는 만성 flapping은 `KubeJobFailed`에서 영구 무성이다.

보완 알림도 못 잡는다 — 하트비트 임계가 주기의 3배인 것들이 사각지대다:

| CronJob | 주기 | 하트비트 임계 | 배수 | 50% 교대 시 성공 간격 | 판정 |
|---|---|---|---|---|---|
| `adguard-rewrite-reconciler` | 600s | 1800s | 3배 | 1200s | ❌ 사각지대 |
| `gha-liveness-exporter` | 1800s | 5400s | 3배 | 3600s | ❌ 사각지대 |
| `digest-exporter` | 600s | 900s | 1.5배 | 1200s | ✅ 잡힘 |

adguard가 가장 나쁘다: `*.home` split-horizon rewrite가 절반의 시간 stale인데 **모든 알림이 초록**이다.

## 왜 성공 기반 지표로는 못 닫는가 (기각한 대안)

교대 실패에서 `time() - last_success`는 **주기가 일정한 톱니파**다(0 → P → 0 → P …). 임계를 어디에
두든 그 위에 머무는 구간이 P보다 짧아 `for:`를 채우지 못하고, 임계를 P 아래로 낮추면 **정상 동작에서도**
매 주기 발화한다. 단발 miss와 지속 flapping을 가르는 성분이 이 신호에는 없다.

`kube_cronjob_status_last_failed_time`도 없다(KSM 메트릭 목록 실측 — `last_schedule_time`과
`last_successful_time`뿐). `last_schedule - last_successful`도 같은 톱니파다.

⇒ **실패를 사건으로 세는 것이 유일한 경로**이고, 그 관측 창은 `failedJobsHistoryLimit`다.

## 설계

```
count by (namespace, owner_name) (
  최근 WINDOW 내 시작한, CronJob 소유의, 실패한 Job
) >= 2
```

- **임계 2**: "한 번은 사고, 두 번은 패턴". 단발 실패는 `KubeJobFailed`의 소관이고 그쪽은 후속 성공에
  억제된다 — 이 룰은 그 억제가 삼키는 영역만 본다(두 룰의 역할 분리).
- **WINDOW 1시간**: adguard 기준 6주기. 그 안에 2회 실패면 33% 실패율로 명백히 비정상이다. 창이 지나면
  자동 해소되므로 `#401`이 고친 "영구 발화" 병을 되풀이하지 않는다.
- **관측 가능성 전제**: `failedJobsHistoryLimit >= 2`여야 2를 셀 수 있다. `digest-exporter`와
  `gha-liveness-exporter`가 **1**이라 원리적으로 관측 불가 → 함께 2로 올린다. 이 전제는 정적 게이트가
  강제한다(룰 임계와 각 CronJob의 limit을 레포에서 계산해 대조 — 하드코딩 목록 금지).
- **저빈도 CronJob은 대상 밖**: 주기 > WINDOW면 창 안에 2회가 물리적으로 불가능하다(일 1회 백업류).
  그쪽은 전용 staleness 알림이 이미 지킨다. 룰 주석에 이 경계를 명시한다.

## Seam

- **회귀**: `tests/gates/vmalert-jobfailed-firing-e2e.sh`에 레그 추가 — 같은 메트릭 계열
  (`kube_job_*`)이고 같은 룰 파일(`core.yaml`)이라 새 하네스를 만들 이유가 없다.
  - **L7** 교대 flapping(창 내 실패 2회 + 그 사이 성공) → `CronJobFlapping` **발화** ·
    `KubeJobFailed`는 **침묵**(억제가 삼키는 그 영역임을 같은 픽스처로 증명 — 이게 이 작업의 핵심 대조)
  - **L8** 창 내 실패 1회 → `CronJobFlapping` **침묵**(단발은 이 룰 소관이 아니다)
  - 기존 L1~L6에서 `CronJobFlapping`이 오발화하지 않는지도 함께 본다
- **관측 가능성 게이트**: `tests/gates/test_cronjob-flapping.bats`(신규) — 룰 임계와 `failedJobsHistoryLimit`
  정합을 레포에서 계산해 강제.

## 이빨 (뮤테이션으로 증명할 것)

`#401`에서 배운 규율 — "잠근다"는 주장은 뮤테이션으로만 성립한다.

- 룰 임계 `>= 2` → `>= 1`로 낮추면 **L8이 red**(단발이 발화)
- 최근성 필터(`WINDOW`) 제거하면 **L1이 red**(3일 묵은 실패가 다시 세어짐)
- `failedJobsHistoryLimit`를 1로 되돌리면 **관측 가능성 게이트가 red**
