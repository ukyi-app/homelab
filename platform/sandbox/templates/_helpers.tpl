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

{{/* 작업자 파드 라벨. bot-slot의 sandbox ingress 정책이 이 라벨로 작업자를 고른다. */}}
{{- define "sandbox.workerLabels" -}}
app: worker
{{- end }}

{{/*
작업 레인 작업자 파드 라벨. Service worker의 selector(app: worker)에 섞이지 않게 값을 나눈다. 같은 값을 쓰면 대화·리뷰 요청이
작업 파드로도 간다. platform/bot-slot의 botSlot.taskWorkerSelector와 같아야 한다.
*/}}
{{- define "sandbox.taskWorkerLabels" -}}
app: worker-task
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

{{/* 작업 레인 자격 Secret 이름. 대화·리뷰 Secret과 나눠 한 레인의 토큰만 교체·철회한다. */}}
{{- define "sandbox.taskCredentialSecret" -}}
worker-task-credential-{{ .Values.worker.profile.id }}
{{- end }}

{{/*
init 방화벽. 작업자 파드 둘이 같은 규칙을 쓴다. 이미지는 netshoot v0.16(Docker Hub 멀티 아키텍처 index)이다. iptables(nft)가 있고,
tools/ci/policy.ts가 이 이미지·명령을 고정본과 맞춘다. 봇 이미지에는 iptables가 없다.
*/}}
{{- define "sandbox.egressFirewall" -}}
# 파드 netns 출력 차단(U13). 새로 여는 연결은 프록시 ClusterIP:포트 하나만 남긴다. 허용 셋 중 하나라도 빠지면:
# -o lo가 없으면 파드 안 127.0.0.1 통신이 끊기고, ESTABLISHED,RELATED가 없으면 봇 요청의 응답 패킷이 막혀 작업 전달이 끊긴다.
# 목적지는 DNAT 전 주소(ClusterIP)다. kube-proxy의 DNAT는 노드 쪽에서 일어나 파드 netns의 OUTPUT은 ClusterIP를 본다.
# NET_ADMIN은 이 컨테이너에만 있다. 본 컨테이너는 규칙을 못 바꾸고, 규칙은 파드 netns에 남아 본 컨테이너 재시작에도 유지된다.
# 규칙을 못 걸면 여기서 실패해 파드가 뜨지 않는다(열린 채로 뜨지 않는다).
- name: egress-firewall
  image: docker.io/nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70
  command: ["/bin/sh", "-euc"]
  args:
    - |
      for t in iptables ip6tables; do
        "$t" -P OUTPUT DROP
        "$t" -F OUTPUT
        "$t" -A OUTPUT -o lo -j ACCEPT
        "$t" -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      done
      iptables -A OUTPUT -d "$PROXY_IP/32" -p tcp --dport "$PROXY_PORT" -m conntrack --ctstate NEW -j ACCEPT
      # REJECT: DNS·직접 연결 시도가 시간 초과까지 매달리지 않고 바로 실패한다. 정책 DROP은 그 뒤의 그물이다.
      iptables -A OUTPUT -j REJECT
      ip6tables -A OUTPUT -j REJECT
      iptables -S OUTPUT
      ip6tables -S OUTPUT
  env:
    - name: PROXY_IP
      value: {{ .Values.proxy.clusterIP | quote }}
    - name: PROXY_PORT
      value: {{ .Values.proxy.port | quote }}
  securityContext:
    # netfilter 규칙은 root + NET_ADMIN이 필요하다. ns가 privileged인 이유가 이 컨테이너 하나다(platform/namespaces).
    runAsUser: 0
    runAsNonRoot: false
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
      add: ["NET_ADMIN"]
  volumeMounts:
    # iptables의 잠금 파일(/run/xtables.lock) 자리.
    - name: firewall-run
      mountPath: /run
  resources:
    requests:
      cpu: 5m
      memory: 16Mi
    limits:
      memory: 64Mi
{{- end }}
