{{/* 시험 ns 이름. tools/olive-o02/의 스크립트가 같은 이름을 쓴다(바꾸면 함께 바꾼다). */}}
{{- define "o02.namespace" -}}
olive-o02-test
{{- end }}

{{- define "o02.labels" -}}
app.kubernetes.io/part-of: olive-o02
{{- end }}

{{/*
시험 이미지. 방화벽 init과 봇 자리 시험 파드가 이미 쓰는 netshoot의 같은 digest다(platform/sandbox/templates/_helpers.tpl,
platform/bot-slot/templates/probe.yaml). 노드에 이미 받아져 있고 bash, python3, curl, util-linux(setsid, unshare), strace가 있다.
uid 10001과 읽기 전용 root로 도는 것은 봇 자리 시험 파드가 실측했다.
*/}}
{{- define "o02.image" -}}
docker.io/nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70
{{- end }}

{{/* 모든 컨테이너 공통. 티켓 할 일 1: 권한 상승 금지, 읽기 전용 root, capability drop ALL. uid는 컨테이너마다 따로 적는다. */}}
{{- define "o02.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{/*
대기만 하는 컨테이너의 PID 1. sleep infinity는 PID 1일 때 SIGTERM을 무시해 지울 때마다 유예 시간을 다 쓴다.
*/}}
{{- define "o02.idleCommand" -}}
workingDir: /
command: ["/bin/bash", "-c"]
args:
  - |
    trap 'exit 0' TERM INT
    while :; do sleep 5 & wait "$!"; done
{{- end }}
