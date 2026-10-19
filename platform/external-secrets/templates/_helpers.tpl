{{/*
두 store가 함께 쓰는 provider 블록. 받는 값: projectSlug, environmentSlug, secretsPath.
*/}}
{{- define "stores.provider" -}}
infisical:
  # provider 문서대로 /api 없이 적는다. SDK가 /api를 붙인다(이미 붙어 있으면 그대로). CRD 기본값은 /api가 붙은 값이라
  # 생략하면 문서와 다른 값이 들어간다.
  hostAPI: https://app.infisical.com
  auth:
    universalAuthCredentials:
      # 부트스트랩 Secret. 평상시 사람이 클러스터 밖에서 넣는 유일한 자격이다(설계 C.6.4, bootstrap 2번).
      # Git에는 이름만 둔다. client secret은 사용 횟수 무제한(0)이어야 한다. ESO는 동기화마다 새로 로그인하고
      # 끝나면 토큰을 폐기하므로, 1로 두면 두 번째 동기화부터 실패한다(설계 B.8 E3, 추측).
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
    # 기본값 true면 값 안의 ${...}를 같은 프로젝트의 다른 시크릿으로 펼친다. 비밀번호 같은 값이 그 문자열을
    # 우연히 담으면 조용히 다른 값으로 바뀌고, 다른 경로의 값이 섞여 들어올 수 있다. 값은 적힌 그대로 쓴다.
    expandSecretReferences: false
    # recursive는 적지 않는다(기본 false). find·recursive에는 열린 버그(#6876, #6230)가 있어 쓰지 않는다(설계 C.6.1).
{{- end }}
