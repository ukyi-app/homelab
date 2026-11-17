{{/*
이 차트가 만드는 실행 대상(targets.yaml에서 declaredBy가 platform/olive인 줄). 결과는 {"items": [...]} YAML이고 부르는 쪽이
fromYaml로 받는다. 모양이 틀리면 여기서 렌더를 멈춘다. CLI·CI가 같은 파일을 읽으므로 차트만 몰래 다른 모양을 받지 않게 한다.
*/}}
{{- define "olive.targets" -}}
{{- $doc := .Files.Get "targets.yaml" | fromYaml -}}
{{- if or (not $doc) (hasKey $doc "Error") -}}
{{- fail "platform/olive/targets.yaml is missing or not valid YAML" -}}
{{- end -}}
{{- $items := list -}}
{{- $namespaces := dict -}}
{{- $supervisors := 0 -}}
{{- range $t := $doc.targets -}}
{{- range $k := list "id" "kind" "namespace" "deployment" -}}
{{- if not (get $t $k) -}}{{- fail (printf "targets.yaml: every target needs %s" $k) -}}{{- end -}}
{{- end -}}
{{- if or (not (hasKey $t "stop")) (not (hasKey $t "start")) (not (kindIs "bool" $t.stop)) (not (kindIs "bool" $t.start)) -}}
{{- fail (printf "targets.yaml: target %s needs bool stop and start" $t.id) -}}
{{- end -}}
{{- if and $t.start (not $t.stop) -}}
{{- fail (printf "targets.yaml: target %s is startable but not a stop target" $t.id) -}}
{{- end -}}
{{- if eq (toString $t.declaredBy) "platform/olive" -}}
{{- if hasKey $namespaces $t.namespace -}}
{{- fail (printf "targets.yaml: namespace %s appears twice in platform/olive targets" $t.namespace) -}}
{{- end -}}
{{- $_ := set $namespaces $t.namespace true -}}
{{- if eq $t.kind "supervisor" -}}
{{- $supervisors = add1 $supervisors -}}
{{- else if eq $t.kind "executor" -}}
{{- if not (hasKey $.Values.executors $t.id) -}}
{{- fail (printf "values.yaml executors.%s is missing for targets.yaml executor %s" $t.id $t.id) -}}
{{- end -}}
{{- else -}}
{{- fail (printf "targets.yaml: platform/olive declares only supervisor and executor, not %s (%s)" $t.kind $t.id) -}}
{{- end -}}
{{- $items = append $items $t -}}
{{- end -}}
{{- end -}}
{{- if ne $supervisors 1 -}}
{{- fail "targets.yaml: platform/olive needs exactly one supervisor target" -}}
{{- end -}}
{{- toYaml (dict "items" $items) -}}
{{- end }}

{{/* 감독 대상 한 줄. */}}
{{- define "olive.supervisorTarget" -}}
{{- range (include "olive.targets" . | fromYaml).items -}}
{{- if eq .kind "supervisor" }}{{ toYaml . }}{{ end -}}
{{- end -}}
{{- end }}

{{/* 대상의 resources(감독은 supervisor, 실행기는 executors.<id>). 받는 값: root, target. 파드와 ResourceQuota가 같은 값을 쓴다. */}}
{{- define "olive.resources" -}}
{{- if eq .target.kind "supervisor" -}}
{{ toYaml .root.Values.supervisor.resources }}
{{- else -}}
{{ toYaml (index .root.Values.executors .target.id).resources }}
{{- end -}}
{{- end }}

{{/*
이미지 참조. digest가 비면 렌더를 멈춘다. root에서 켠 채 digest 없이 병합되면 파드가 태그 없는 이름을 당기거나
ImagePullBackOff로 Degraded가 되므로 렌더에서 막는다(모양은 values.schema.json이 본다).
*/}}
{{- define "olive.image" -}}
{{- $digest := required "image.digest is required (sha256:<64 hex> from the ukyi-app/olive main build; keep components.olive off until then)" .Values.image.digest -}}
{{ .Values.image.repository }}@{{ $digest }}
{{- end }}

{{/* 선택자 라벨. 대상마다 네임스페이스가 따로라 kind로 충분하다. */}}
{{- define "olive.selectorLabels" -}}
app.kubernetes.io/name: olive
app.kubernetes.io/component: {{ .kind }}
{{- end }}

{{- define "olive.labels" -}}
{{ include "olive.selectorLabels" . }}
app.kubernetes.io/part-of: olive
homelab.ukyi.app/olive-target: {{ .id }}
{{- end }}

{{/*
감독·실행기 파드 공통의 보안 문맥(D-54 이미지 계약, PSA restricted). 받는 값: target(대상 한 줄).
SA 토큰을 붙이지 않고, 이 차트는 어떤 Role·RoleBinding도 만들지 않는다(D-37: 감독에게 Kubernetes 쓰기 권한이 없다).
hc 소켓·호스트 경로를 붙이지 않는다(작업자 파드에 hc가 없다, D-37).
*/}}
{{- define "olive.podSecurity" -}}
serviceAccountName: {{ .kind }}
# SA에서도 끄지만(templates/serviceaccounts.yaml) 파드에서 한 번 더 끈다. 둘 중 하나만 켜져도 토큰이 붙는다.
automountServiceAccountToken: false
# 같은 ns Service의 env를 넣지 않는다. 실행기가 붙을 주소는 아래 env로만 준다.
enableServiceLinks: false
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  # Secret 볼륨(0440)을 그룹으로 읽게 한다. local-path PVC에는 적용되지 않는다(폴더가 0777로 만들어진다).
  fsGroup: 65532
  seccompProfile:
    type: RuntimeDefault
{{- end }}

{{- define "olive.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
{{- end }}
