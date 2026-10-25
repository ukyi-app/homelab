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
{{- /* 복원 모드는 running: true를 함께 적을 때만. running 없이 켜 두면 서버가 그대로 돌다가 나중에 재시작될 때
       appendonly no로 떠 AOF를 무시하고 더 오래된 RDB를 읽는다(마지막 RDB 뒤 쓰기를 잃는다). */ -}}
{{- if and $v.restoreMode (not (and (hasKey $v "running") $v.running)) -}}
{{- fail "valkey.restoreMode는 valkey.running: true를 함께 적을 때만 쓴다(복원 3단계, docs/runbooks-public/restore.md 1절)" -}}
{{- end -}}
{{- if $v.persistent -}}
{{- /* 공식 valkey 차트는 릴리스 이름에 valkey가 들어 있으면 접미사 없이 릴리스 이름만 쓴다(앱 차트와 같은 함정). */ -}}
{{- if contains "valkey" .Release.Name -}}
{{- fail (printf "영속 Valkey를 쓰는 앱 이름에 valkey를 넣지 않는다: %s" .Release.Name) -}}
{{- end -}}
{{- /* CronJob 이름은 52자까지다(Job 이름에 11자 접미사가 붙는다). <앱>-valkey-backup이라 앱 이름은 38자까지.
       이름을 줄이지 않는 이유: ValkeyBackupStale 경보가 valkey-backup으로 찾는다. */ -}}
{{- if gt (len .Release.Name) 38 -}}
{{- fail (printf "영속 Valkey를 쓰는 앱 이름은 38자까지다(CronJob %s-valkey-backup이 52자를 넘는다): %s" .Release.Name .Release.Name) -}}
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
폐기는 purge: true로 이 주석을 지우는 PR이 먼저다(purge PR 1). 그 PR이 병합·동기화돼 살아 있는 리소스에서 주석이
빠진 것을 본 뒤에만 data/<앱> 삭제 PR(purge PR 2)을 낸다. 같은 PR에 넣으면 주석이 남은 채 삭제가 시작돼 리소스가 남는다.
*/}}
{{- define "data.protect" -}}
{{- if not .Values.purge }}
argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end }}
{{- end }}

{{/*
CNPG reclaim(Database databaseReclaimPolicy, DatabaseRole databaseRoleReclaimPolicy). 기본 retain이라 CR이 지워져도
DB·역할이 남는다[S30][S31]. purge: true일 때만 delete로 바꿔 PR 2의 CR 삭제가 DROP까지 가게 한다.
*/}}
{{- define "data.reclaim" -}}
{{- ternary "delete" "retain" (.Values.purge | default false) }}
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
