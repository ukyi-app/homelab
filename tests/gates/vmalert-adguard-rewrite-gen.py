#!/usr/bin/env python3
"""vmalert-adguard-rewrite-firing-e2e 하네스용 합성 시계열 생성기 — VictoriaMetrics /api/v1/import(JSON lines).

usage: vmalert-adguard-rewrite-gen.py <out> <scenario> <from> <to> <push_s> <stop_before_s>
                                      <fix_t_s> <hb> <fix_metric>

⚠️ 독립 파일인 이유: 셸 heredoc에 python을 내장하면 typecheck·lint 사각이 된다 —
   CONTRIBUTING.md 「새 코드 배치 규칙」의 명시적 금지. 형제 관용구 = vmalert-drift-gen.py.
   (2026-09-01 이관 — 종전 하네스의 인라인 `<<'PY'` 블록과 동일한 코드이며,
    하네스 전건 통과가 산출물 동일성의 증인이다.)
"""
import json, sys
out, scen, frm, to, push, stop_before, fix_t, hb, fixm = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]),
    int(sys.argv[6]), int(sys.argv[7]), sys.argv[8], sys.argv[9])

ts = list(range(frm, to + 1, push))   # push 주기마다 한 샘플(라이브와 같은 간격)
lines = []
def series(metric, values, stamps):
    lines.append(json.dumps({"metric": {"__name__": metric},
                             "values": values,
                             "timestamps": [t * 1000 for t in stamps]}))

if scen == "healthy":
    # 매 주기 방금 성공 — 값 = 그 시점 자신.
    series(hb, list(ts), ts)
elif scen == "stale":
    # 창 끝 stop_before 이전까지만 push하고 멈춘다 → 이후 나이가 임계를 넘어간다.
    cut = [t for t in ts if t <= to - stop_before]
    if not cut:
        sys.exit("gen: stale 시나리오의 샘플이 0건 — 창/정지시점 산술 오류")
    series(hb, list(cut), cut)
elif scen == "absent":
    pass   # 시리즈 자체를 만들지 않는다 → absent() 가지 검증
elif scen == "fixed":
    # 하트비트는 정상이고, 최근에 fix가 있었다(창 끝 기준 임계 안).
    series(hb, list(ts), ts)
    recent = [t for t in ts if t >= to - fix_t // 2]
    if not recent:
        sys.exit("gen: fixed 시나리오의 최근 샘플이 0건")
    series(fixm, list(recent), recent)
else:
    sys.exit(f"gen: 알 수 없는 시나리오 {scen}")

# ⚠️ absent 시나리오는 시리즈가 0개다. 그래도 vmsingle에 **무언가**는 넣어야 replay가 대상 없이 돌지
#    않는다 — 백필 sanity가 잡을 수 있도록 대조용 상수 시리즈를 하나 둔다.
lines.append(json.dumps({"metric": {"__name__": "harness_alive"},
                         "values": [1] * len(ts),
                         "timestamps": [t * 1000 for t in ts]}))
open(out, "w").write("\n".join(lines) + "\n")
