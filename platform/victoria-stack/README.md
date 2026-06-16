# victoria-stack

**역할** — 관측성 스택: vmsingle/vmagent/VictoriaLogs/Vector/Grafana/vmalert/Alertmanager/node-exporter/kube-state-metrics. Telegram 알림 + R2/CNPG/cert/CI staleness 룰. `observability` 네임스페이스.

**싱크 Application · sync-wave** — `platform/argocd/root/apps/victoria-stack.yaml`의 **수동 Application**(appset에서 `platform/victoria-stack/*` 제외). **sync-wave +2**(stateful 이후). StatefulSet `volumeClaimTemplates`는 atomic 리스트라 `ignoreDifferences`(+`RespectIgnoreDifferences=true`)로 제외, `CreateNamespace=false`(NS는 자체 manifest).

**라이브 디버그** — `observability` 스킬(메트릭/로그/알림 흐름, telegram 검증, PVC 포화, vmalert 룰). 런북 `docs/runbooks/observability-verify.md`. 컴포넌트 노트는 [NOTES.md](prod/NOTES.md).

**함정 SSOT** — AGENTS.md "라이브에서 검증된 함정": vector는 root 실행 필수(k3s `/var/log/pods` root:root 0640), VictoriaLogs는 distroless(라이브 질의는 vmagent 등에서 service DNS), vmalert는 `configCheckInterval` 없으면 룰 reload 안 함, 모든 PV가 hostPath라 `kubelet_volume_stats` 부재(PVC 포화는 `node_filesystem`+`cnpg_collector_pg_wal`로), busybox 1.36 nc `-q` 없음(deadmanswitch relay), Alertmanager telegram 검증은 `alertmanager_notifications_total{integration="telegram"}`로.
