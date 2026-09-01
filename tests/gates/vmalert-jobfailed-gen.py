#!/usr/bin/env python3
"""vmalert-jobfailed-firing-e2e 하네스용 합성 시계열 생성기 — VictoriaMetrics /api/v1/import(JSON lines).

usage: vmalert-jobfailed-gen.py <out> <scenario> <from> <to> <sample_s> <ns> <cronjob>
       <job_cron> <job_solo> <stale_age_s> <stale_lead_s> <recovery_at> <cronjob2> <job_cron2>
       <flap_threshold> <flap_spread_s> <lifecycle_period_s> <lifecycle_faillimit>

⚠️ 독립 파일인 이유: 셸 heredoc에 python을 내장하면 typecheck·lint 사각이 된다 —
   CONTRIBUTING.md 「새 코드 배치 규칙」의 명시적 금지. 형제 관용구 = vmalert-drift-gen.py.
   (2026-09-01 이관 — 종전 하네스의 인라인 블록과 동일한 코드이며,
    하네스 전건 통과가 산출물 동일성의 증인이다.)
"""
import json, sys
(out, scen, frm, to, step, ns, cj, job_cron, job_solo, stale_age, stale_lead, recovery_at,
 cj2, job_cron2, flap_threshold, flap_spread, lifecycle_period, lifecycle_faillimit) = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]),
    sys.argv[6], sys.argv[7], sys.argv[8], sys.argv[9], int(sys.argv[10]), int(sys.argv[11]),
    int(sys.argv[12]), sys.argv[13], sys.argv[14], int(sys.argv[15]), int(sys.argv[16]),
    int(sys.argv[17]), int(sys.argv[18]))

# ⚠️ fail-closed(2026-09-01). 종전 인라인 블록의 시나리오 디스패치는 `elif`로 끝나 **미지 시나리오가
#    어떤 분기도 타지 않고 조용히 빈 출력을 냈다** — 오타 하나가 그 레그를 무측정으로 만든다
#    (형제 vmalert-meta-gen.py는 이미 SystemExit로 닫혀 있다).
# ⚠️ `unresolved`는 **분기가 없는 것이 의도**다 — 공통 픽스처(실패 Job + 그보다 앞선 마지막 성공)가
#    그대로 L3가 요구하는 "미해소" 상태다. 목록에서 빠뜨리면 그 레그가 통째로 죽으므로 여기 명시한다.
#    (이 목록을 만들면서 실제로 밟았다: 분기 열거만으로 KNOWN을 채우면 `unresolved`가 미지가 된다.)
KNOWN = ("healthy", "standalone", "stale_resolved", "transition", "two_jobs",
         "flapping", "single_failure", "lifecycle_flap", "two_cronjobs_resolved",
         "consecutive_unresolved", "stale_failures", "unresolved")
if scen not in KNOWN:
    raise SystemExit(f"unknown scenario {scen} (known: {', '.join(KNOWN)})")

ts = list(range(frm, to + 1, step))
lines = []
def series(metric, labels, values):
    m = {"__name__": metric}; m.update(labels)
    lines.append(json.dumps({"metric": m, "values": values,
                             "timestamps": [t * 1000 for t in ts]}))

# ★ Job은 **생성되고 회수된다** — 그 수명을 시계열의 존재 구간으로 표현한다. `series()`가 전 구간에
#   값을 싣는 것과 달리, 여기서는 [t_from, t_until) 밖에서 시리즈가 **없다**(KSM이 없는 오브젝트를
#   내보내지 않는 것과 같다). CronJob 컨트롤러의 failedJobsHistoryLimit 회수를 모델링하는 데 쓴다.
def series_window(metric, labels, value, t_from, t_until):
    idx = [i for i, tt in enumerate(ts) if tt >= t_from and (t_until is None or tt < t_until)]
    if not idx:
        return
    m = {"__name__": metric}; m.update(labels)
    lines.append(json.dumps({"metric": m, "values": [value] * len(idx),
                             "timestamps": [ts[i] * 1000 for i in idx]}))

# ⚠️ 타임스탬프 값은 **관측 시점보다 미래일 수 없다.** KSM은 "아직 일어나지 않은 성공"을 내보내지
#    않는다. 그래서 last-success는 상수로 박지 않고 **각 샘플 시점 t의 함수**로 만든다 — 이 규율을
#    깨면 창 밖 미래값이 첫 평가부터 소급 적용돼 전이를 건너뛴 vacuous green이 된다(release-r1 R-2).
def failed_job(job_name, job_start, owner_kind, owner_name):
    series("kube_job_failed", {"condition": "true", "namespace": ns, "job_name": job_name},
           [1] * len(ts))
    series("kube_job_status_start_time", {"namespace": ns, "job_name": job_name},
           [job_start] * len(ts))
    series("kube_job_owner",
           {"namespace": ns, "job_name": job_name,
            "owner_kind": owner_kind, "owner_name": owner_name},
           [1] * len(ts))

if scen == "healthy":
    # 실패 시리즈 자체가 없다. CronJob은 창 내내 성공 중(마지막 성공 = 그 시점).
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj}, list(ts))

elif scen == "standalone":
    # CronJob 소유가 **아닌** Job의 실패 — 억제는 여기 걸리면 안 된다.
    # ⚠️ owner_name을 **소유 CronJob과 같은 이름**으로 두고 그 CronJob의 최신 성공도 함께 내보낸다.
    #    이게 이 레그의 이빨이다: 억제 재료를 **전부 갖춰 놓고** 오직 `owner_kind="CronJob"` 필터
    #    하나만이 억제를 막게 만든다. (초판은 owner_kind/owner_name을 둘 다 `<none>`으로 두고
    #    cronjob 성공 시리즈를 아예 안 냈는데, 그러면 억제식 우변이 빈 벡터라 **필터를 지워도**
    #    결과가 같아 L4가 그 필터를 전혀 잠그지 못했다 — 자체 감사 S-1/S-5/S-11이 뮤테이션으로 실증.)
    #    owner_kind는 비-CronJob 컨트롤러(Argo Workflow·Tekton 등)가 Job을 소유하는 현실 형태를 쓴다.
    failed_job(job_solo, frm, "Workflow", cj)
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj}, list(ts))

elif scen == "stale_resolved":
    # ★ 라이브 adguard 그 자체: 실패 Job은 창 **시작보다 훨씬 전**(3일)에 시작해 그대로 남아 있고,
    #   소유 CronJob은 창 내내 정상 가동한다(마지막 성공이 매 샘플 갱신). 창의 어느 시점을 봐도
    #   `job_start < last_success`이므로 억제가 걸려야 한다 — 수정 전 룰은 여기서 3일 내내 발화했다.
    failed_job(job_cron, frm - stale_age, "CronJob", cj)
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj}, list(ts))

elif scen == "transition":
    # ★ 창 **안에서** 발화 → 복구 → 해소를 실제로 겪는다. 복구 전에는 마지막 성공이 실패보다 앞서고
    #   (미해소 → for: 를 채워 발화), 복구 시점부터는 그 시점의 성공으로 갱신된다(해소 → 침묵).
    job_start = frm
    failed_job(job_cron, job_start, "CronJob", cj)
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj},
           [(job_start - stale_lead) if t < recovery_at else t for t in ts])

elif scen == "two_jobs":
    # ★ 조인 키 granularity를 잠근다: **같은 네임스페이스**에 해소된 실패와 미해소 실패를 하나씩 둔다.
    #   억제가 job 단위(`on (namespace, job_name)`)면 앞의 것만 침묵하고 뒤의 것은 발화한다.
    #   억제가 ns 단위(`on (namespace)`)로 뭉개지면 정상 CronJob의 최신 성공 하나가 **같은 ns의 고장
    #   난 CronJob 실패까지 삼켜** 뒤의 것도 침묵한다 — 이 픽스가 막으려던 것의 정반대 fail-open이다.
    #   라이브에 실재하는 형태다: observability ns 하나에 digest-exporter·gha-liveness-exporter·
    #   pvc-du-exporter 세 CronJob이 공존한다. (자체 감사 S-2가 뮤테이션으로 실증한 공백.)
    failed_job(job_cron, frm, "CronJob", cj)          # 해소 — 소유 CronJob이 창 내내 성공
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj}, list(ts))
    failed_job(job_cron2, frm, "CronJob", cj2)        # 미해소 — 마지막 성공이 실패보다 앞
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj2},
           [frm - stale_lead] * len(ts))

elif scen in ("flapping", "single_failure"):
    # ★ S-6 갭: 실패↔성공이 **교대**하면 각 실패는 다음 주기 성공에 억제돼 `for:`를 채우지 못한다 →
    #   KubeJobFailed는 영구 무성이다. 그 영역을 CronJobFlapping이 **실패를 사건으로 세어** 잡는다.
    #   두 시나리오는 실패 **개수**만 다르다(2 vs 1) — 임계가 실제로 2인지 가르는 대조다.
    #   ⚠️ 두 실패 모두 창 안에서 시작하고, 그 뒤 CronJob이 성공한다(= KubeJobFailed는 억제된다).
    #     그래야 "억제가 삼키는 바로 그 상태"를 재현한다.
    #   실패 개수는 **룰 임계에서 파생**한다: flapping = 임계, single = 임계-1. 임계를 바꾸면
    #   두 픽스처가 함께 따라오므로 "임계가 실제로 N인가"라는 대조가 유지된다.
    n_fail = flap_threshold if scen == "flapping" else flap_threshold - 1
    #   시작 시각은 replay 창 시작 **이전**에 흩뿌린다 — 샘플 시각보다 미래일 수 없기 때문이다.
    #   가장 오래된 것이 frm - spread, 가장 최근이 frm. (겹침 산술은 §3b preflight가 강제한다.)
    for k in range(n_fail):
        off = flap_spread * (n_fail - 1 - k) // max(n_fail - 1, 1)
        failed_job(f"{job_cron}-f{k}", frm - off, "CronJob", cj)
    # 소유 CronJob은 창 내내 성공 중 — 마지막 성공이 항상 최신이라 KubeJobFailed 억제가 걸린다.
    # ⚠️ 이 줄이 빠지면 억제식 우변이 빈 벡터가 되어 **억제가 아예 안 걸리고**, L7b가 "억제 회귀"라는
    #   틀린 사유로 red를 낸다(실제로 한 번 그렇게 만들었다 — 픽스처 결손을 룰 결함으로 오독하게 된다).
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj}, list(ts))

elif scen == "lifecycle_flap":
    # ★★ 교대 flapping의 **전체 수명주기**를 재생한다: F1 → S1 → F2 → S2 → F3 → … 그리고 CronJob
    #   컨트롤러가 failedJobsHistoryLimit개만 남기고 **오래된 실패를 회수**한다.
    #   이 레그가 없으면 "해소된 실패 2건을 창 내내 고정"이라는 정적 스냅샷만 보게 되는데, 라이브에서는
    #   그 2건이 유지되지 않는다 — 새 실패가 오면 가장 오래된 것이 사라지고 그 새 실패는 아직 미해소라
    #   세어지지 않아 count가 임계 아래로 떨어진다(적대적 리뷰 r2가 지목한 pending 리셋).
    #   ⚠️ 주기·limit은 **adguard 매니페스트에서 파생**한다 — 최악 케이스(가장 짧은 주기)가 대상이다.
    P = lifecycle_period
    fails = []
    k = 0
    while True:
        fs = frm - 2 * P + k * 2 * P     # 실패는 2주기 간격(성공↔실패 교대)
        if fs > to:
            break
        fails.append(fs)
        k += 1
    for i, fs in enumerate(fails):
        # i번째 실패는 (i + limit)번째 실패가 생길 때 회수된다.
        del_at = fails[i + lifecycle_faillimit] if i + lifecycle_faillimit < len(fails) else None
        jn = f"{job_cron}-lc{i}"
        series_window("kube_job_failed", {"condition": "true", "namespace": ns, "job_name": jn}, 1, fs, del_at)
        series_window("kube_job_status_start_time", {"namespace": ns, "job_name": jn}, fs, fs, del_at)
        series_window("kube_job_owner",
                      {"namespace": ns, "job_name": jn, "owner_kind": "CronJob", "owner_name": cj},
                      1, fs, del_at)
    # 각 실패 P초 뒤에 성공한다 — last_success는 그 계단이다.
    def last_ok_at(tt):
        best = frm - 3 * P
        for fs in fails:
            s = fs + P
            if s <= tt:
                best = s
        return best
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj},
           [last_ok_at(tt) for tt in ts])

elif scen == "two_cronjobs_resolved":
    # ★ `count by (…, owner_name)`의 **그룹핑 키**를 잠근다: 같은 ns의 **서로 다른 두 CronJob**이 각각
    #   해소된 실패를 1건씩 갖는다. owner_name으로 그룹핑하면 각 1건이라 임계(2) 미만 → 침묵.
    #   그 키를 빼면 두 무관한 실패가 하나로 합쳐져 임계에 도달 → 오발화한다.
    #   ⚠️ L5(two_jobs)로는 이걸 못 잠근다 — 거기는 한쪽이 미해소라 해소 조건에서 걸러져 count가 1이다
    #     (적대적 리뷰 R-3의 뮤테이션이 L5에서 통과해 버린 이유). 두 건 모두 **해소**여야 대조가 산다.
    failed_job(f"{job_cron}-r0", frm, "CronJob", cj)
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj}, list(ts))
    failed_job(f"{job_cron2}-r0", frm, "CronJob", cj2)
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj2}, list(ts))

elif scen == "consecutive_unresolved":
    # ★ 두 룰의 **상보성**을 잠근다: 같은 CronJob에 미해소 실패가 임계 개수만큼 있다(마지막 성공이 둘보다
    #   앞선다). KubeJobFailed는 발화해야 하고, CronJobFlapping은 **침묵**해야 한다 — 세는 대상이
    #   "실패했다가 복구된" 것뿐이기 때문이다.
    #   해소 조건을 지우면 여기서 둘 다 발화하고, Alertmanager가 alertname으로 그룹핑하므로 텔레그램
    #   알림이 2건 간다(적대적 리뷰 R-2가 지목한 중복 통지). 이 레그가 그 회귀를 red로 만든다.
    for k in range(flap_threshold):
        off = flap_spread * (flap_threshold - 1 - k) // max(flap_threshold - 1, 1)
        failed_job(f"{job_cron}-u{k}", frm - off, "CronJob", cj)
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj},
           [frm - flap_spread - stale_lead] * len(ts))

elif scen == "stale_failures":
    # ★ 최근성 필터를 잠근다: 임계 개수만큼의 실패가 **전부 창 밖**(오래됨)에 있다. 필터가 있으면
    #   세어지지 않아 침묵하고, 필터를 지우면 그대로 세어져 오발화한다 — #401이 고친 "과거를 현재로
    #   알리는" 병의 재발이다. 라이브 의미도 같다: 3일 전 2회 실패가 남아 있어도 지금 문제는 아니다.
    for k in range(flap_threshold):
        failed_job(f"{job_cron}-s{k}", frm - stale_age - k * flap_spread, "CronJob", cj)
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj}, list(ts))

else:  # unresolved — 마지막 성공이 실패 **이전**에 멈춰 있다 = 아직 고장 중.
    job_start = frm
    failed_job(job_cron, job_start, "CronJob", cj)
    series("kube_cronjob_status_last_successful_time", {"namespace": ns, "cronjob": cj},
           [job_start - stale_lead] * len(ts))

open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
