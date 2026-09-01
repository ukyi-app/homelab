#!/usr/bin/env python3
"""vmalert-gha-liveness-firing-e2e 하네스용 합성 시계열 생성기 — VictoriaMetrics /api/v1/import(JSON lines).

usage: vmalert-gha-liveness-gen.py <out> <scenario> <from> <to> <push_s> <age_s>
       <wf_over> <wf_under> <budget_small> <budget_large> <n_cfg> <n_partial> <n_zero> <n_back> <back_s>

⚠️ 독립 파일인 이유: 셸 heredoc에 python을 내장하면 typecheck·lint 사각이 된다 —
   CONTRIBUTING.md 「새 코드 배치 규칙」의 명시적 금지. 형제 관용구 = vmalert-drift-gen.py.
   (2026-09-01 이관 — 종전 하네스의 인라인 `<<'PY'` 블록과 동일한 코드이며,
    하네스 전건 통과가 산출물 동일성의 증인이다.)
"""
import json, sys
out, scen, frm, to, push, age, wf_o, wf_u, b_small, b_large, n_cfg, n_part, n_zero, n_back, back_s = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]),
    int(sys.argv[6]), sys.argv[7], sys.argv[8], int(sys.argv[9]), int(sys.argv[10]),
    int(sys.argv[11]), int(sys.argv[12]), int(sys.argv[13]), int(sys.argv[14]), int(sys.argv[15]))

# ⚠️ fail-closed(2026-09-01). 종전 인라인 블록은 시나리오 디스패치가 `if zero / elif partial / else`로
#    끝나 **미지 시나리오가 else 분기로 조용히 흘렀다** — 오타 하나가 다른 시나리오를 재생하고,
#    그 레그의 판정은 무측정이 된다(형제 생성기 vmalert-meta-gen.py는 이미 SystemExit로 닫혀 있다).
#    호출부가 `gen "$VME_TMP/$scen.jsonl" "$scen"`으로 **변수**라 리터럴 보증도 없다.
KNOWN = ("stale", "healthy", "hbstale", "hbabsent", "partial", "zero", "regress")
if scen not in KNOWN:
    raise SystemExit(f"unknown scenario {scen} (known: {', '.join(KNOWN)})")

ts = list(range(frm, to + 1, push))          # push 주기마다 한 샘플(라이브와 같은 간격)
lines = []
def series(metric, labels, values):
    m = {"__name__": metric}; m.update(labels)
    lines.append(json.dumps({"metric": m,
                             "values": values,
                             "timestamps": [t * 1000 for t in ts]}))

# 워크플로 타임스탬프: 각 샘플 시점 기준 age 초 전에 마지막 성공.
# healthy·regress면 방금 성공(age=0)으로 둔다 — regress의 결함은 나이가 아니라 **역행**이다.
eff_age = 0 if scen in ("healthy", "regress") else age
over_vals = [t - eff_age for t in ts]
under_vals = [t - eff_age for t in ts]
# regress: 공급원(GitHub API)이 낡은 스냅샷을 준 상태 — 시계열 **끝**의 n_back 샘플만 back_s 뒤로 튄다.
# ⚠️ 끝에 두는 것이 최악 배치다. 창 안 뒤쪽에 두면 그 뒤의 신선한 샘플이 last_over_time마저 구제해
#    결함 픽스처가 발화하지 않는다(= L9 무측정).
# ⚠️ wf_o(예산이 작은 쪽)에는 심지 않는다 — 흡수 후 남는 나이가 그 예산과 정확히 같아져 경계에 앉는다.
if scen == "regress":
    for i in range(len(ts) - n_back, len(ts)):
        under_vals[i] = ts[i] - back_s
series("gha_workflow_last_success_timestamp", {"workflow": wf_o}, over_vals)
series("gha_workflow_last_success_timestamp", {"workflow": wf_u}, under_vals)
series("gha_workflow_max_age_seconds", {"workflow": wf_o}, [b_small] * len(ts))
series("gha_workflow_max_age_seconds", {"workflow": wf_u}, [b_large] * len(ts))

# 하트비트: hbstale이면 창 초반에서 멈춘 값(= 오래된 타임스탬프가 계속 보인다),
# hbabsent면 시리즈 자체를 내보내지 않는다(absent 가지 검증).
if scen != "hbabsent":
    if scen == "hbstale":
        frozen = frm  # 창 시작 시각에 마지막 성공 → 창 끝에서 SPAN_S만큼 낡음
        series("gha_liveness_last_success_timestamp", {}, [frozen] * len(ts))
    else:
        series("gha_liveness_last_success_timestamp", {}, list(ts))

# 수집 카운트
if scen == "zero":
    cfg, scraped = n_zero, n_zero
elif scen == "partial":
    cfg, scraped = n_cfg, n_part
else:
    cfg, scraped = n_cfg, n_cfg
series("gha_liveness_configured", {}, [cfg] * len(ts))
series("gha_liveness_scraped", {}, [scraped] * len(ts))

open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
