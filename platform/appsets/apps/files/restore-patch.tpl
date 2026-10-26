            {{- /* 복구 동안 이 클러스터에서만 멈출 앱(cluster.restore.suspendedApps). templates/applicationset.yaml이 넣는다. */}}
            {{- $v := omit . "path" "values" "tailnetPrefix" }}
            {{- if has .values.app (list __SUSPENDED_APPS__) }}
            {{- $_ := set $v "suspended" true }}
            {{- end }}
            {{- $v | toYaml | nindent 8 }}
