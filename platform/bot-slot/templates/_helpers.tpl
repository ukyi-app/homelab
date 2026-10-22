{{/* 봇 파드를 고르는 라벨. 공유 차트의 selector 라벨(platform/charts/app의 app.selector)과 같은 키다. */}}
{{- define "botSlot.targetSelector" -}}
homelab.ukyi.app/app: {{ .Values.target.app }}
{{- end }}

{{/* sandbox 작업자 파드 라벨. platform/sandbox의 sandbox.workerLabels와 같아야 한다(차트가 달라 helper를 함께 못 쓴다). */}}
{{- define "botSlot.workerSelector" -}}
app: worker
{{- end }}

{{- define "botSlot.labels" -}}
app.kubernetes.io/part-of: bot-slot
app.kubernetes.io/managed-by: argocd
{{- end }}
