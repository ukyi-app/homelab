{{- define "app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.homelab/kind: {{ .Values.kind }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* http를 리슨하며 Service/HTTPRoute를 받는 워크로드 */}}
{{- define "app.isServed" -}}
{{- if or (eq .Values.kind "api") (eq .Values.kind "ssr") (eq .Values.kind "spa") -}}true{{- end -}}
{{- end -}}

{{/* 검증: kind별 필수 항목 */}}
{{- define "app.validate" -}}
{{- if and (include "app.isServed" .) (not .Values.route.host) -}}
{{- fail (printf "route.host is required for kind=%s" .Values.kind) -}}
{{- end -}}
{{- if and (eq .Values.kind "spa") .Values.db.enabled -}}
{{- fail "kind=spa must not set db.enabled (static assets have no DB)" -}}
{{- end -}}
{{- end -}}
