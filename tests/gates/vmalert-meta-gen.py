#!/usr/bin/env python3
"""vmalert-meta-firing-e2e 하네스용 합성 시계열 생성기 — VictoriaMetrics /api/v1/import(JSON lines).

메타 관측 알림 3종의 픽스처를 시나리오별로 만든다:
  - AlertRuleFlapping        ← ALERTS_FOR_STATE{alertname}의 activeAt 갱신 횟수(flap/flap-quiet)
  - AlertPipelineWriteStale  ← Watchdog 샘플의 나이(stale/quiet)
  - AlertSuppressionProlonged← alertmanager_alerts{state="suppressed"}의 지속(sup/sup-quiet/sup-short)
  - GrafanaPluginBudgetLow · GrafanaDuFingerprintLost ← du 사용률·지문(graf/graf-quiet/fp-lost)

usage: vmalert-meta-gen.py <scenario> <rp_from> <rp_to> <step> <sup_step>
                           <flap_w> <flap_n> <stale_t> <sup_w> <graf_denom>

⚠️ 독립 파일인 이유: 셸 heredoc에 python을 내장하면 typecheck·lint 사각이 된다 —
   CONTRIBUTING.md 「새 코드 배치 규칙」의 명시적 금지. 형제 관용구 = vmalert-drift-gen.py.
   (2026-09-01 이관 — 이 파일은 종전 vmalert-meta-firing-e2e.sh:100-157의 `cat > $GEN <<'PY'`
    블록과 **바이트 동일한 산출물**을 내며, 10 시나리오 JSONL diff로 검증했다.)
⚠️ 미지 시나리오는 fail-closed다(SystemExit) — 오타가 다른 시나리오로 조용히 재생되면
   그 레그의 판정이 무측정이 된다.
"""
import json, sys
scenario, rp_from, rp_to, step, sup_step = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
flap_w, flap_n = int(sys.argv[6]), int(sys.argv[7])
stale_t = int(sys.argv[8]); sup_w = int(sys.argv[9]); graf_denom = int(sys.argv[10])
out = []
def series(metric, labels, pairs):
    m = {"__name__": metric}; m.update(labels)
    out.append({"metric": m, "values": [v for _, v in pairs], "timestamps": [t * 1000 for t, _ in pairs]})
def grid(a, b, st): return list(range(a, b + 1, st))
# 공통: Watchdog ALERTS — 정상이면 replay 끝까지 신선(stale 시나리오만 절단).
wd_end = rp_to if scenario != "stale" else rp_from - stale_t - 300
series("ALERTS", {"alertname": "Watchdog", "alertstate": "firing", "severity": "none"},
       [(t, 1) for t in grid(rp_from - 2 * 3600, wd_end, step)])
if scenario == "flap":       # activeAt이 창 안에서 flap_n+3회 갱신 — 임계 초과(마진 ≥2 — 리뷰 L2)
    start = rp_to - flap_w + 600
    n = flap_n + 3
    pairs = []
    for i in range(n):
        seg_a = start + i * (flap_w - 1200) // n
        seg_b = start + (i + 1) * (flap_w - 1200) // n - step
        pairs += [(t, seg_a) for t in grid(seg_a, min(seg_b, rp_to), step)]
    series("ALERTS_FOR_STATE", {"alertname": "SyntheticFlappy", "severity": "warning"}, pairs)
elif scenario == "flap-quiet":   # 2회 갱신 — 임계 미만(정상 해소·재발)
    mid = rp_to - flap_w // 2
    pairs = [(t, rp_to - flap_w) for t in grid(rp_to - flap_w + 600, mid, step)]
    pairs += [(t, mid) for t in grid(mid + step, rp_to, step)]
    series("ALERTS_FOR_STATE", {"alertname": "SyntheticFlappy", "severity": "warning"}, pairs)
elif scenario == "sup":          # suppressed ≥1이 창 전체(30s 밀도 — 밀도 가드 충족) + replay 내내
    series("alertmanager_alerts", {"state": "suppressed", "namespace": "observability"},
           [(t, 1) for t in grid(rp_from - sup_w - 600, rp_to, sup_step)])
elif scenario == "sup-quiet":    # 창 중간 4h 동안 0 — min이 0이라 침묵
    a = rp_from - sup_w - 600; hole_a = rp_to - sup_w // 2; hole_b = hole_a + 4 * 3600
    pairs = [(t, 0 if hole_a <= t <= hole_b else 1) for t in grid(a, rp_to, sup_step)]
    series("alertmanager_alerts", {"state": "suppressed", "namespace": "observability"}, pairs)
elif scenario == "sup-short":    # 시리즈가 40분치뿐 + 내내 1 — 밀도 가드가 "24h 지속" 참칭을 막는다(리뷰 M3)
    series("alertmanager_alerts", {"state": "suppressed", "namespace": "observability"},
           [(t, 1) for t in grid(rp_to - 2400, rp_to, sup_step)])
elif scenario == "graf":         # 사용률 0.70(임계 초과) + 지문 1·하트비트(FingerprintLost 침묵 대조)
    v = int(graf_denom * 0.70)
    series("grafana_data_dir_size_bytes", {}, [(rp_from - 86400, v), (rp_from - 600, v)])
    series("grafana_du_fingerprint_matches", {}, [(rp_from - 86400, 1), (rp_from - 600, 1)])
    series("pvc_du_last_success_timestamp", {}, [(rp_from - 86400, rp_from - 86400), (rp_from - 600, rp_from - 600)])
elif scenario == "graf-quiet":   # 사용률 0.50 — 침묵
    v = int(graf_denom * 0.50)
    series("grafana_data_dir_size_bytes", {}, [(rp_from - 86400, v), (rp_from - 600, v)])
    series("grafana_du_fingerprint_matches", {}, [(rp_from - 86400, 1), (rp_from - 600, 1)])
    series("pvc_du_last_success_timestamp", {}, [(rp_from - 86400, rp_from - 86400), (rp_from - 600, rp_from - 600)])
elif scenario == "fp-lost":      # 지문 0 + 하트비트 실재 — FingerprintLost 발화(리뷰 M8 레그)
    series("grafana_du_fingerprint_matches", {}, [(rp_from - 86400, 0), (rp_from - 600, 0)])
    series("pvc_du_last_success_timestamp", {}, [(rp_from - 86400, rp_from - 86400), (rp_from - 600, rp_from - 600)])
elif scenario == "stale":
    pass
elif scenario == "quiet":
    pass
else:
    raise SystemExit(f"unknown scenario {scenario}")
for s_ in out: print(json.dumps(s_))
