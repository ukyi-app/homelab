package main

# PSA restricted 패리티 — helm 렌더 워크로드 pod 템플릿을 라이브 admission과 동일 기준으로 검증한다.
# 적대 리뷰 Pass1 #4 + Pass3 #3: drop:ALL·seccomp 존재만 보면 false-green → capabilities.add·
# Unconfined seccomp·init/ephemeral 컨테이너까지 커버. 차트 기본값은 restricted 완전 준수(deny 0).
# CI 핀 conftest(OPA)는 v1 문법(in/contains/if)에 이 import 필요(ledger.rego 선례).
import rego.v1

wl := {"Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet", "Pod"}

ps := input.spec if input.kind == "Pod"

ps := input.spec.template.spec if {
	wl[input.kind]
	input.kind != "Pod"
}

containers contains c if some c in object.get(ps, ["containers"], [])

containers contains c if some c in object.get(ps, ["initContainers"], [])

containers contains c if some c in object.get(ps, ["ephemeralContainers"], [])

# --- pod-level host 격리 ---
deny contains msg if {
	object.get(ps, ["hostNetwork"], false) == true
	msg := "PSA restricted: hostNetwork=true 금지"
}

deny contains msg if {
	object.get(ps, ["hostPID"], false) == true
	msg := "PSA restricted: hostPID=true 금지"
}

deny contains msg if {
	object.get(ps, ["hostIPC"], false) == true
	msg := "PSA restricted: hostIPC=true 금지"
}

deny contains msg if {
	some v in object.get(ps, ["volumes"], [])
	v.hostPath
	msg := sprintf("PSA restricted: hostPath 볼륨 %q 금지", [v.name])
}

# --- container-level (containers + initContainers + ephemeralContainers) ---
deny contains msg if {
	some c in containers
	object.get(c, ["securityContext", "privileged"], false) == true
	msg := sprintf("PSA restricted: %q privileged=true 금지", [c.name])
}

deny contains msg if {
	some c in containers
	object.get(c, ["securityContext", "allowPrivilegeEscalation"], true) != false
	msg := sprintf("PSA restricted: %q allowPrivilegeEscalation=false 필수", [c.name])
}

deny contains msg if {
	some c in containers
	not "ALL" in object.get(c, ["securityContext", "capabilities", "drop"], [])
	msg := sprintf("PSA restricted: %q capabilities.drop에 ALL 필수", [c.name])
}

deny contains msg if {
	some c in containers
	some cap in object.get(c, ["securityContext", "capabilities", "add"], [])
	cap != "NET_BIND_SERVICE"
	msg := sprintf("PSA restricted: %q 금지된 capabilities.add %q", [c.name, cap])
}

deny contains msg if {
	some c in containers
	object.get(c, ["securityContext", "runAsNonRoot"], object.get(ps, ["securityContext", "runAsNonRoot"], false)) != true
	msg := sprintf("PSA restricted: %q runAsNonRoot=true 필수(pod 또는 container)", [c.name])
}

deny contains msg if {
	some c in containers
	not seccomp_ok(c)
	msg := sprintf("PSA restricted: %q seccompProfile RuntimeDefault/Localhost 필수(pod 또는 container)", [c.name])
}

seccomp_ok(c) if {
	t := object.get(c, ["securityContext", "seccompProfile", "type"], object.get(ps, ["securityContext", "seccompProfile", "type"], ""))
	t in {"RuntimeDefault", "Localhost"}
}
