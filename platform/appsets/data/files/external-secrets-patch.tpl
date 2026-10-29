            {{- /* 복구 스위치(cluster.restore.externalSecrets: false). 모든 데이터의 ExternalSecret을 끈다. 데이터 차트 1.1.0부터라 그 전 버전은 schema로 렌더 실패한다. */}}
            {{- $_ := set $v "externalSecrets" (dict "enabled" false) }}
