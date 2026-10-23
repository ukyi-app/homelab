{{/*
앱 이름은 릴리스 이름이다. ApplicationSet data가 Application 이름은 <앱>-data로, helm.releaseName은 data/<앱>
디렉터리 이름으로 둔다. destination ns는 app-<앱>이다(영속 Valkey가 앱 ns에 있다). PostgreSQL 리소스는 ns database에 명시한다.
53자 상한은 앱 차트와 같다(같은 앱 이름을 쓴다).
*/}}
{{- define "data.name" -}}
{{- $name := .Release.Name -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]{0,51}[a-z0-9])?$" $name) -}}
{{- fail (printf "앱 이름 %q는 DNS 라벨이고 53자 이하여야 한다(Helm 릴리스 이름 상한)" $name) -}}
{{- end -}}
{{- if ne .Release.Namespace (printf "app-%s" $name) -}}
{{- fail (printf "ns는 app-%s여야 한다: %s" $name .Release.Namespace) -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{- define "data.persistentValkey" -}}
{{- $v := .Values.valkey -}}
{{- if and (hasKey $v "running") (not $v.persistent) -}}
{{- fail "valkey.running은 valkey.persistent: true와 함께 쓴다" -}}
{{- end -}}
{{- if and $v.restoreMode (not $v.persistent) -}}
{{- fail "valkey.restoreMode는 valkey.persistent: true와 함께 쓴다" -}}
{{- end -}}
{{- if $v.persistent -}}
{{- /* 공식 valkey 차트는 릴리스 이름에 valkey가 들어 있으면 접미사 없이 릴리스 이름만 쓴다(앱 차트와 같은 함정). */ -}}
{{- if contains "valkey" .Release.Name -}}
{{- fail (printf "영속 Valkey를 쓰는 앱 이름에 valkey를 넣지 않는다: %s" .Release.Name) -}}
{{- end -}}
true
{{- end -}}
{{- end }}

{{/*
라벨. homelab.ukyi.app/app은 앱 차트의 selector 라벨이라 여기 파드에 붙이지 않는다. 붙이면 앱 Service가 Valkey·백업
파드로도 트래픽을 보낸다. 앱을 찾는 라벨은 homelab.ukyi.app/data로 따로 둔다.
*/}}
{{- define "data.labels" -}}
homelab.ukyi.app/data: {{ include "data.name" . }}
app.kubernetes.io/managed-by: argocd
homelab.ukyi.app/chart: app-data-{{ .Chart.Version }}
{{- end }}

{{/*
Argo CD가 지우지 않는 데이터 리소스(설계 C.5.5). revert·data/<앱> 삭제·ApplicationSet 삭제 모두에서 남는다.
폐기는 이 주석을 지우는 PR이 먼저다(purge PR 1).
*/}}
{{- define "data.protect" -}}
argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end }}

{{- define "data.externalSecretSpec" -}}
refreshInterval: 1h
secretStoreRef:
  kind: ClusterSecretStore
  name: infisical-apps
{{- end }}

{{- define "data.podSecurity" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
fsGroup: 65532
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "data.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}
