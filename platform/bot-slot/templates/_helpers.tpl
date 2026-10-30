{{/* 봇 파드를 고르는 라벨. 공유 차트의 selector 라벨(platform/charts/app의 app.selector)과 같은 키다. Service selector용. */}}
{{- define "botSlot.targetSelector" -}}
homelab.ukyi.app/app: {{ .Values.target.app }}
{{- end }}

{{/*
NetworkPolicy가 봇 파드를 고르는 selector(matchLabels·matchExpressions 블록). 공유 차트의 마이그레이션 Job 파드도 같은
app 라벨을 받으므로, 그 파드에만 붙는 homelab.ukyi.app/role(migration)이 없는 파드만 고른다. 빼지 않으면 Job이
봇 전용 허용(작업자·Grafana·Kubernetes API)을 물려받는다.
*/}}
{{- define "botSlot.targetPodSelector" -}}
matchLabels:
  {{- include "botSlot.targetSelector" . | nindent 2 }}
matchExpressions:
  - key: homelab.ukyi.app/role
    operator: DoesNotExist
{{- end }}

{{/* sandbox 작업자 파드 라벨. platform/sandbox의 sandbox.workerLabels와 같아야 한다(차트가 달라 helper를 함께 못 쓴다). */}}
{{- define "botSlot.workerSelector" -}}
app: worker
{{- end }}

{{- define "botSlot.labels" -}}
app.kubernetes.io/part-of: bot-slot
app.kubernetes.io/managed-by: argocd
{{- end }}
