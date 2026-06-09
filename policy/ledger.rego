package main

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
