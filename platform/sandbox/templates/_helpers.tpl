{{/*
작업자 전용 store의 provider 블록. platform/external-secrets/templates/_helpers.tpl의 stores.provider와 같은 모양이다.
차트가 달라 helper를 함께 쓰지 못한다. 그쪽(hostAPI, 부트스트랩 Secret, expandSecretReferences)을 바꾸면 여기도 바꾼다.
받는 값: projectSlug, environmentSlug, secretsPath.
*/}}
{{- define "sandbox.storeProvider" -}}
infisical:
  hostAPI: https://app.infisical.com
  auth:
    universalAuthCredentials:
      # 다른 두 store와 같은 부트스트랩 Secret(identity eso-homelab)이다. 그래서 secretsPath는 경계가 아니다(설계 C.6.3).
      # 작업자가 다른 경로를 못 고르는 것은 ExternalSecret이 Git으로만 생기고 sandbox에 생성 권한이 없어서다(설계 C.8).
      clientId:
        name: infisical-universal-auth
        namespace: external-secrets
        key: clientId
      clientSecret:
        name: infisical-universal-auth
        namespace: external-secrets
        key: clientSecret
  secretsScope:
    projectSlug: {{ .projectSlug | quote }}
    environmentSlug: {{ .environmentSlug | quote }}
    secretsPath: {{ .secretsPath | quote }}
    expandSecretReferences: false
{{- end }}

{{/* 작업자 파드 라벨. bot-slot(PR 3)의 sandbox ingress 정책이 이 라벨로 작업자를 고른다. */}}
{{- define "sandbox.workerLabels" -}}
app: worker
{{- end }}

{{- define "sandbox.proxyLabels" -}}
app: egress-proxy
{{- end }}

{{/*
작업자 자격 Secret 이름(ExternalSecret 대상, 작업자 볼륨). 프로필 id를 넣는다. 프로필을 바꾸면 새 이름이 생겨, ESO가 아직
옛 값을 들고 있는 같은 이름 Secret을 새 실행기가 읽는 일이 없다.
*/}}
{{- define "sandbox.workerCredentialSecret" -}}
worker-credential-{{ .Values.worker.profile.id }}
{{- end }}
