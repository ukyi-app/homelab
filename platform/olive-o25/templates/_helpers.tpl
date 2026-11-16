{{/* 시험 ns 이름. tools/olive-o25/의 스크립트가 같은 이름을 쓴다(바꾸면 함께 바꾼다). */}}
{{- define "o25.namespace" -}}
olive-o25-test
{{- end }}

{{- define "o25.labels" -}}
app.kubernetes.io/part-of: olive-o25
{{- end }}

{{/*
시험 이미지. O02와 같은 netshoot digest다(platform/olive-o02/templates/_helpers.tpl). 노드에 이미 받아져 있고
bash, python3, curl, util-linux(setsid)가 있다. Alpine(musl)이라 Claude Code는 musl 배포본만 돈다(values.yaml claude).
*/}}
{{- define "o25.image" -}}
docker.io/nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70
{{- end }}

{{/* 모든 컨테이너 공통: 권한 상승 금지, 읽기 전용 root, capability drop ALL. uid·gid는 컨테이너마다 적는다. */}}
{{- define "o25.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}
