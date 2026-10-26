            {{- /* 복구 동안 이 클러스터에서만 영속 Valkey를 멈출 앱(cluster.restore.valkey). templates/applicationset.yaml이 넣는다. */}}
            {{- /* data values의 running·restoreMode는 버리고 모드 값으로 다시 쓴다. get은 키가 없으면 빈 문자열이다. */}}
            {{- $v := omit . "path" "values" "backup" }}
            {{- $mode := get (dict __VALKEY_RESTORE__) .values.app }}
            {{- if $mode }}
            {{- $vk := omit (get $v "valkey" | default dict) "running" "restoreMode" }}
            {{- $_ := set $vk "running" (eq $mode "restoreMode") }}
            {{- if eq $mode "restoreMode" }}
            {{- $_ := set $vk "restoreMode" true }}
            {{- end }}
            {{- $_ := set $v "valkey" $vk }}
            {{- end }}
            {{- $v | toYaml | nindent 8 }}
