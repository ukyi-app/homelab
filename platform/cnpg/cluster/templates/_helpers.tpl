{{/*
같은 Application 안의 순서(sync-wave). 앞 wave가 Healthy가 돼야 다음으로 넘어간다.
-2 ExternalSecret·NetworkPolicy → -1 ObjectStore → 0 Cluster → 1 ScheduledBackup.
자격 Secret이 CR보다 늦으면 barman이 자격을 못 읽고, ObjectStore가 Cluster보다 늦으면 plugin이
"barman object configuration not found"로 무한 requeue해 Cluster가 Healthy가 되지 않는다. 그러면 Argo CD가
Cluster wave에서 기다려 ObjectStore를 영영 적용하지 않는다(옛 첫 bootstrap 교착 두 건, 설계 B.8 E6).
PVC는 operator가 만들므로 WaitForFirstConsumer PVC가 wave를 막는 함정(sandbox worker-pvc.yaml)은 없다.
*/}}

{{- define "cnpg.pluginName" -}}
barman-cloud.cloudnative-pg.io
{{- end }}

{{/*
R2 자격 Secret(templates/externalsecret.yaml). 복구 원본이 다른 자격을 쓰면(VM 시험) recoverySource.credentialsSecret.
*/}}
{{- define "cnpg.credentialsSecret" -}}
r2-backup
{{- end }}

{{/*
ObjectStore configuration. bucket·secret만 다르고 나머지는 운영 ObjectStore와 복구 원본 ObjectStore가 같다.
endpointURL을 적지 않는다. R2 S3 endpoint에 Cloudflare 계정 ID가 들어가는데 이 저장소는 계정 ID를 Git에 두지 않는다.
대신 sidecar env AWS_ENDPOINT_URL_S3(아래 cnpg.sidecarEnv)를 Secret에서 넣는다. endpointURL이 비면 plugin이
--endpoint-url을 넘기지 않고(barman-cloud v0.6.0 command.go), boto3가 이 env를 읽는다(sidecar의 botocore 1.43, 실측).
*/}}
{{- define "cnpg.objectStoreConfiguration" -}}
destinationPath: {{ printf "s3://%s/pg/" .bucket | quote }}
s3Credentials:
  accessKeyId:
    name: {{ .secret }}
    key: ACCESS_KEY_ID
  secretAccessKey:
    name: {{ .secret }}
    key: SECRET_ACCESS_KEY
wal:
  compression: gzip
  maxParallel: 2
data:
  compression: gzip
  jobs: 2
{{- end }}

{{/*
plugin sidecar env. plugin은 Cluster가 참조하는 모든 ObjectStore의 env를 이름 기준으로 합친다(먼저 온 값이 이긴다,
plugin v0.15.1 lifecycle.go). 그래서 운영 ObjectStore와 복구 원본 ObjectStore에 같은 env를 둔다.
- region은 AWS_DEFAULT_REGION만 읽힌다. AWS_REGION은 botocore가 무시해 us-east-1이 된다(sidecar 이미지 실측).
- checksum 두 줄: boto3 1.36부터 기본 checksum 헤더를 R2가 받지 않는 경우가 있어 필요할 때만 보낸다(CNPG 문서 S35).
*/}}
{{- define "cnpg.sidecarEnv" -}}
- name: AWS_ENDPOINT_URL_S3
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: ENDPOINT_URL
- name: AWS_DEFAULT_REGION
  value: auto
- name: AWS_REQUEST_CHECKSUM_CALCULATION
  value: when_required
- name: AWS_RESPONSE_CHECKSUM_VALIDATION
  value: when_required
{{- end }}
