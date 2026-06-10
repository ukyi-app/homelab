package main

# CI의 핀 버전 conftest(OPA)는 v1 문법(in/contains/if)에 이 import가 필요하다 — 로컬 신버전은
# 기본 v1이라 통과해 차이가 라이브 CI에서야 드러났다.
import rego.v1

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
