            {{- /* 복구 스위치(cluster.restore.externalSecrets: false). 모든 앱의 ExternalSecret을 끈다. 앱 차트 1.2.0부터라 그 전 버전 앱은 schema로 렌더 실패한다. */}}
            {{- $_ := set $v "externalSecrets" (dict "enabled" false) }}
