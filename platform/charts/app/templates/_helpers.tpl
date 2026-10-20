{{/*
앱 이름은 릴리스 이름이다. ApplicationSet apps가 Application 이름을 apps/<앱> 디렉터리 이름으로 두고,
Argo CD는 releaseName이 없으면 Application 이름을 릴리스 이름으로 쓴다. ns는 app-<앱>이다.
이름 검사는 schema가 못 하는 것(릴리스 이름, ns, repository와의 대조)만 여기서 한다.
*/}}
{{- define "app.name" -}}
{{- $name := .Release.Name -}}
{{- /* 53자: Helm 릴리스 이름 상한이다(Argo CD도 helm template에 앱 이름을 릴리스로 넘긴다). 그 안에서
       ns app-<이름>, Job <이름>-migrate 같은 파생 이름도 63자를 넘지 않는다. */ -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]{0,51}[a-z0-9])?$" $name) -}}
{{- fail (printf "앱 이름 %q는 DNS 라벨이고 53자 이하여야 한다(Helm 릴리스 이름 상한)" $name) -}}
{{- end -}}
{{- if ne .Release.Namespace (printf "app-%s" $name) -}}
{{- fail (printf "ns는 app-%s여야 한다: %s" $name .Release.Namespace) -}}
{{- end -}}
{{- /* 다른 앱의 이미지를 가리키지 못하게 한다. 자동 병합 조건 5의 source 라벨도 앱 이름 기준이다(설계 C.4.7). */ -}}
{{- if ne .Values.repository (printf "ghcr.io/ukyi-app/%s" $name) -}}
{{- fail (printf "repository는 ghcr.io/ukyi-app/%s여야 한다: %s" $name .Values.repository) -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{/*
selector 라벨. 고정 라벨 하나만 쓴다. selector는 바꿀 수 없어 값이 바뀌면 sync가 영구 실패한다(설계 B.8 E2).
*/}}
{{- define "app.selector" -}}
homelab.ukyi.app/app: {{ include "app.name" . }}
{{- end }}

{{- define "app.labels" -}}
{{ include "app.selector" . }}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/managed-by: argocd
homelab.ukyi.app/chart: app-{{ .Chart.Version }}
{{- end }}

{{- define "app.image" -}}
{{ .Values.repository }}@{{ .Values.digest }}
{{- end }}

{{/*
파드 보안 기본값(설계 C.4.5 보안 행). 앱 ns는 PSA restricted다.
uid는 숫자로 준다. 이미지 USER가 이름(예: node)이면 runAsNonRoot가 "non-numeric user"로 파드를 거부한다.
템플릿 Dockerfile은 65532(distroless nonroot)로 짓는다.
*/}}
{{- define "app.podSecurity" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
fsGroup: 65532
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "app.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{- define "app.resources" -}}
requests:
  cpu: {{ .Values.resources.cpu | quote }}
  memory: {{ .Values.resources.memory | quote }}
limits:
  memory: {{ .Values.resources.memory | quote }}
{{- end }}

{{/*
컨테이너 env. 시크릿은 키마다 secretKeyRef로 넣는다. optional이 없어(기본 false) Secret에 키가 없으면
새 파드가 CreateContainerConfigError로 시작하지 않는다. envFrom은 빠진 키를 알리지 않아 쓰지 않는다(설계 C.4.5).
*/}}
{{- define "app.env" -}}
{{- $name := include "app.name" . -}}
{{- /* env 이름이 겹치면 컨테이너가 어느 값을 쓸지 분명하지 않다(예: env.PORT가 서비스·probe 포트와 다름). 렌더를 막는다. */ -}}
{{- $seen := dict -}}
{{- $names := list -}}
{{- if eq .Values.kind "web" }}{{- $names = append $names "PORT" -}}{{- end -}}
{{- if .Values.uses.postgres }}{{- $names = append $names "DATABASE_URL" -}}{{- end -}}
{{- if .Values.uses.valkey }}{{- $names = append $names "VALKEY_URL" -}}{{- end -}}
{{- $names = concat $names (keys .Values.env) .Values.secrets -}}
{{- range $names -}}
{{- if hasKey $seen . -}}
{{- fail (printf "env 이름 %s가 두 번 나온다(PORT·DATABASE_URL·VALKEY_URL은 차트가 넣고, env와 secrets는 서로 겹치지 않는다)" .) -}}
{{- end -}}
{{- $_ := set $seen . true -}}
{{- end -}}
{{- if eq .Values.kind "web" }}
- name: PORT
  value: {{ .Values.port | quote }}
{{- end }}
{{- range $k := keys .Values.env | sortAlpha }}
- name: {{ $k }}
  value: {{ index $.Values.env $k | quote }}
{{- end }}
{{- range .Values.secrets }}
- name: {{ . }}
  valueFrom:
    secretKeyRef:
      name: {{ $name }}-app
      key: {{ . }}
{{- end }}
{{- if .Values.uses.postgres }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ $name }}-db
      key: DATABASE_URL
{{- end }}
{{- if .Values.uses.valkey }}
- name: VALKEY_URL
  valueFrom:
    secretKeyRef:
      name: {{ $name }}-valkey-url
      key: VALKEY_URL
{{- end }}
{{- end }}

{{- define "app.probe" -}}
{{- $p := .probe -}}
{{- if $p.path }}
httpGet:
  path: {{ $p.path }}
  port: http
{{- else }}
exec:
  command: {{ toJson $p.command }}
{{- end }}
periodSeconds: {{ $p.periodSeconds | default 10 }}
failureThreshold: {{ $p.failureThreshold | default 3 }}
{{- end }}

{{/*
ExternalSecret 공통(edge-probe와 같은 모양). template이 없으면 ExternalSecret의 라벨·주석(Argo CD tracking-id 포함)이
Secret에 복사돼 Argo CD가 그 Secret을 자기 리소스로 착각한다(설계 B.8 E3).
remoteRef.key는 store secretsPath(/apps)에 이어 붙는 상대 경로다. /로 시작하면 secretsPath를 무시한다(U06).
*/}}
{{- define "app.externalSecretSpec" -}}
refreshInterval: 1h
secretStoreRef:
  kind: ClusterSecretStore
  name: infisical-apps
{{- end }}
