package main

# CI의 핀 버전 conftest(OPA)는 v1 문법(in/contains/if)에 이 import가 필요하다 — 로컬 신버전은
# 기본 v1이라 통과해 차이가 라이브 CI에서야 드러났다.
import rego.v1

# 열거 붕괴 → vacuous green 차단(scan-floor). 아래 두 deny는 **전부** `input.rows` 한정이라
# 행 파서가 0행을 내면 동시에 무발화한다 — 마커/포맷 드리프트 하나로 limit 합계 상한과
# limit ≥ request 불변식이 같이 사라지고, 이 정책을 부르는 `make verify`·`make ci`·required
# check `gate`가 전부 초록이 된다(원장 예산 게이트 전체가 vacuous). 부분 드리프트도 같은 클래스다.
# 게이트는 스크립트가 아니라 **정책**이므로 바닥값도 여기가 제자리다.
# 실 원장 **16행**(2026-09-03 실측 `grep -c 'ledger:row' docs/memory-ledger.md`) → 12
# (행 4개 철거를 견딘다). 래칫 아님 — 도메인이 줄지 않는 한 손댈 일이 없다.
# ⚠️ 초판 주석은 "17행 → 12"였는데 그때도 실측은 15였다(행 2개가 철거되고 근거만 안 따라왔다).
#    바닥값 12 자체는 그대로 정당하다 — 갱신된 것은 마진 계산의 근거뿐이다.
min_rows := 12

deny contains msg if {
	count(input.rows) < min_rows
	msg := sprintf("ledger scan-floor: parsed rows %d < %d — 행 파서/마커 드리프트 의심(예산 검사가 vacuous해진다)", [count(input.rows), min_rows])
}

total_limit := sum([r.limit | some r in input.rows])

deny contains msg if {
	total_limit > input.budget
	msg := sprintf("memory ledger over budget: limit total %dMi > budget %dMi", [total_limit, input.budget])
}

deny contains msg if {
	some r in input.rows
	r.limit < r.req
	msg := sprintf("component %q has limit %dMi < request %dMi", [r.component, r.limit, r.req])
}
