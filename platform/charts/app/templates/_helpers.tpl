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

{{/* 이미지 참조 SSOT: digest가 있으면 repo@digest(불변, 권위), 없으면 repo:tag.
     Deployment와 migration Job이 반드시 이 helper를 함께 써서 동일 이미지를 강제한다 —
     한쪽만 digest를 쓰면 migration과 워크로드가 다른 이미지를 실행할 수 있다. */}}
{{- define "app.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repo .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/* http를 리슨하며 Service/HTTPRoute를 받는 워크로드 — worker만 비서빙 */}}
{{- define "app.isServed" -}}
{{- if ne .Values.kind "worker" -}}true{{- end -}}
{{- end -}}

{{/* 검증: kind별 필수 항목 */}}
{{- define "app.validate" -}}
{{- if and (include "app.isServed" .) (not .Values.route.host) -}}
{{- fail (printf "route.host is required for kind=%s" .Values.kind) -}}
{{- end -}}
{{- end -}}
