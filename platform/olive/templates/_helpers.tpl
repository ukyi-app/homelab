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
# 파드와 SA 양쪽에 값이 있으면 파드 값이 우선한다. 파드에서 명시해 끄고, 이 줄이 빠진 파드도 안전하도록 SA 기본값도 끈다(templates/serviceaccounts.yaml).
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

{{/*
파드에 붙일 인증서 Secret 이름. 받는 값: root, tls(supervisor.tls 또는 executors.<id>.tls). 빈 결과면 볼륨을 붙이지 않는다.
함정: pki.enabled면 이 이름은 cert-manager가 쓰는 출력이다. 값으로 열면 감독의 서명 키·계정 Secret을 덮어쓸 수 있어 이름을 고정한다.
*/}}
{{- define "olive.tlsSecretName" -}}
{{- if .root.Values.pki.enabled -}}
olive-tls
{{- else -}}
{{ .tls.secretName }}
{{- end -}}
{{- end }}

{{/* 묶음이 비면 신뢰 경로를 아예 주지 않는다. 파드가 시스템 CA로 대신 검증하지 않고 기동을 거부하게 하는 자리다. */}}
{{- define "olive.trustEnabled" -}}
{{- if and .Values.pki.enabled .Values.pki.trustBundlePem -}}true{{- end -}}
{{- end }}

{{/*
인증서가 증명하는 신원(URI SAN 하나). 받는 값: 대상 한 줄. 네임스페이스와 대상 id까지만 담는다.
인스턴스·저장소 ID는 파드보다 오래 사는 인증서에 넣을 수 없어 서명 봉투가 증명한다.
*/}}
{{- define "olive.pki.uri" -}}
{{- if eq .kind "supervisor" -}}
spiffe://olive.internal/ns/{{ .namespace }}/supervisor
{{- else -}}
spiffe://olive.internal/ns/{{ .namespace }}/executor/{{ .id }}
{{- end -}}
{{- end }}

{{/* 감독 인증서의 DNS SAN. 받는 값: 대상 한 줄. */}}
{{- define "olive.pki.dnsName" -}}
supervisor.{{ .namespace }}.svc
{{- end }}

{{/* 대상의 확장 키 용도. 받는 값: 대상 한 줄. 실행기 인증서로 감독 행세를 하지 못하게 서버 용도는 감독에게만 준다. */}}
{{- define "olive.pki.usage" -}}
{{- if eq .kind "supervisor" -}}server auth{{- else -}}client auth{{- end -}}
{{- end }}

{{/* 세대의 ClusterIssuer 이름. 받는 값: 세대 번호. */}}
{{- define "olive.pki.issuerName" -}}
olive-internal-g{{ int . }}
{{- end }}

{{- define "olive.pki.labels" -}}
app.kubernetes.io/name: olive
app.kubernetes.io/component: pki
app.kubernetes.io/part-of: olive
{{- end }}

{{/*
수명·이름 규칙. 어기면 렌더를 멈춘다.
leaf 수명 < ca.renewBeforeHours: 발급 기관 인증서가 제때 갱신되는 동안, 갱신 직전에 나간 leaf도 옛 발급 기관 인증서보다 먼저 끝나게 하는 여유다.
함정: 선언값만 본다. 갱신이 오래 실패해 실제 발급 기관의 남은 기간이 leaf 수명보다 짧아져도 렌더는 통과하고, cert-manager도 그런 leaf를 막지 않는다.
실제 남은 기간은 docs/runbooks-public/rotate.md 3i의 A로 따로 본다.
tls.mountPath가 신뢰 볼륨 경로(/run/olive/trust)와 겹치면 멈춘다. 같은 경로면 PodTemplate이 유효하지 않고, 포개면 한쪽 파일이 가려진다.
*/}}
{{- define "olive.pki.validate" -}}
{{- $ca := .Values.pki.ca -}}
{{- $leaf := .Values.pki.leaf -}}
{{- if .Values.supervisor.tls.secretName -}}
{{- fail "supervisor.tls.secretName must be empty when pki.enabled is true (cert-manager writes the fixed Secret olive-tls)" -}}
{{- end -}}
{{- range $id, $executor := .Values.executors -}}
{{- if $executor.tls.secretName -}}
{{- fail (printf "executors.%s.tls.secretName must be empty when pki.enabled is true (cert-manager writes the fixed Secret olive-tls)" $id) -}}
{{- end -}}
{{- end -}}
{{- if ge (int $ca.renewBeforeHours) (int $ca.durationHours) -}}
{{- fail "pki.ca.renewBeforeHours must be shorter than pki.ca.durationHours" -}}
{{- end -}}
{{- if ge (int $leaf.renewBeforeHours) (int $leaf.durationHours) -}}
{{- fail "pki.leaf.renewBeforeHours must be shorter than pki.leaf.durationHours" -}}
{{- end -}}
{{- if ge (int $leaf.durationHours) (int $ca.renewBeforeHours) -}}
{{- fail "pki.leaf.durationHours must be shorter than pki.ca.renewBeforeHours (keeps a margin before the signing CA certificate expires while CA renewal works)" -}}
{{- end -}}
{{- $tlsPaths := list .Values.supervisor.tls.mountPath -}}
{{- range .Values.executors -}}
{{- $tlsPaths = append $tlsPaths .tls.mountPath -}}
{{- end -}}
{{- range $path := $tlsPaths -}}
{{- $clean := clean $path -}}
{{- if or (eq $clean "/run/olive/trust") (hasPrefix "/run/olive/trust/" $clean) (hasPrefix (printf "%s/" $clean) "/run/olive/trust") -}}
{{- fail (printf "tls.mountPath %s overlaps the trust volume /run/olive/trust" $path) -}}
{{- end -}}
{{- end -}}
{{- $active := false -}}
{{- range $ca.generations -}}
{{- if eq (int .) (int $ca.activeGeneration) -}}{{- $active = true -}}{{- end -}}
{{- end -}}
{{- if not $active -}}
{{- fail "pki.ca.activeGeneration must be listed in pki.ca.generations" -}}
{{- end -}}
{{- end }}
