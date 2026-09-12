import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { isIP } from "node:net";
import { parseDocument, stringify } from "yaml";
import { requireCondition } from "./input.ts";

// 인입 주소가 확정되면 실제 생산자에 적용할 설정을 만든다. 이 명령은 배포하지 않는다.
export function producerPlan(repository: string, output: string, address: string) {
  requireCondition(isIP(address) === 4 && /^(?:10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)/.test(address), "producer-private-address-required");
  const directory = resolve(output), endpoint = `http://${address}:21980/sources`;
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const alertmanager = parseDocument(readFileSync(join(repository, "platform/victoria-stack/prod/alertmanager-config/alertmanager.yml"), "utf8"));
  const routes = alertmanager.getIn(["route", "routes"]) as import("yaml").YAMLSeq;
  routes.items.unshift(alertmanager.createNode({ receiver: "aiops", continue: true }));
  const receivers = alertmanager.get("receivers") as import("yaml").YAMLSeq;
  receivers.add({ name: "aiops", webhook_configs: [{ url: `${endpoint}/alertmanager`, send_resolved: true, http_config: { authorization: { type: "Bearer", credentials_file: "/etc/alertmanager/aiops/token" } } }] });
  writeFileSync(join(directory, "alertmanager.yml"), alertmanager.toString(), { mode: 0o600 });
  const mount = { name: "aiops-auth", mountPath: "/etc/alertmanager/aiops", readOnly: true };
  writeFileSync(join(directory, "alertmanager-deployment.patch.yaml"), stringify({ apiVersion: "apps/v1", kind: "Deployment", metadata: { name: "alertmanager", namespace: "observability" }, spec: { template: { spec: { containers: [{ name: "alertmanager", volumeMounts: [mount] }], volumes: [{ name: "aiops-auth", secret: { secretName: "aiops-observation-auth" } }] } } } }), { mode: 0o600 });
  const data: Record<string, string> = {
    "service.webhook.aiops": stringify({ url: `${endpoint}/argocd`, headers: [{ name: "Authorization", value: "Bearer $aiops-token" }, { name: "Content-Type", value: "application/json" }] }),
  };
  for (const check of ["health", "sync"]) {
    const body = `{"check":"${check}","name":{{ .app.metadata.name | toJson }},"namespace":{{ .app.metadata.namespace | toJson }},"phase":{{ if .app.status.operationState }}{{ .app.status.operationState.phase | default "" | toJson }}{{ else }}""{{ end }},"health":{{ .app.status.health.status | default "" | toJson }},"sync":{{ .app.status.sync.status | default "" | toJson }},"observedAt":{{ .app.status.reconciledAt | toJson }},"revision":{{ if regexMatch "^[a-f0-9]{40}$" (.app.status.sync.revision | default "") }}{{ .app.status.sync.revision | toJson }}{{ else }}null{{ end }}}`;
    data[`template.aiops-${check}`] = stringify({ webhook: { aiops: { method: "POST", body } } });
    const conditions = check === "health" ? ["app.status.health.status == 'Healthy'", "app.status.health.status == 'Degraded'"] : ["app.status.operationState != nil and app.status.operationState.phase == 'Succeeded'", "app.status.operationState != nil and app.status.operationState.phase in ['Failed', 'Error']"];
    data[`trigger.aiops-${check}`] = stringify(conditions.map(when => ({ when, send: [`aiops-${check}`] })));
  }
  writeFileSync(join(directory, "argocd-notifications.merge.json"), JSON.stringify({ data }, null, 2) + "\n", { mode: 0o600 });
  writeFileSync(join(directory, "argocd-subscription.yaml"), stringify([{ recipients: ["aiops:"], triggers: ["aiops-health", "aiops-sync"] }]), { mode: 0o600 });
  writeFileSync(join(directory, "cnpg-endpoint.yaml"), stringify({ apiVersion: "v1", kind: "ConfigMap", metadata: { name: "aiops-endpoint", namespace: "database" }, data: { cnpg: `${endpoint}/cnpg` } }), { mode: 0o600 });
  // 기존 Egress 격리가 있는 notifications에만 허용을 더한다. 무격리 AM/CNPG에 새 격리를 만들지 않는다.
  writeFileSync(join(directory, "argocd-aiops-egress.yaml"), stringify({ apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: { name: "argocd-notifications-aiops-egress", namespace: "argocd" }, spec: { podSelector: { matchLabels: { "app.kubernetes.io/name": "argocd-notifications-controller" } }, policyTypes: ["Egress"], egress: [{ to: [{ ipBlock: { cidr: `${address}/32` } }], ports: [{ protocol: "TCP", port: 21980 }] }] } }), { mode: 0o600 });
  writeFileSync(join(directory, "host-ingress.nft"), `# 기존 방화벽에 추가할 전용 인입 제한. 적용 전 실제 Pod CIDR과 주소를 대조한다.\ntable inet homelab_aiops {\n  chain input {\n    type filter hook input priority -5; policy accept;\n    tcp dport 21980 ip saddr { 127.0.0.1, ${address}, 10.42.0.0/16 } accept\n    tcp dport 21980 drop\n  }\n}\n`, { mode: 0o600 });
  writeFileSync(join(directory, "collector-rbac.yaml"), stringify({ apiVersion: "v1", kind: "ServiceAccount", metadata: { name: "aiops-collector", namespace: "observability" } }) + "---\n" + stringify({ apiVersion: "rbac.authorization.k8s.io/v1", kind: "ClusterRole", metadata: { name: "aiops-collector" }, rules: [{ apiGroups: [""], resources: ["pods", "pods/log", "events", "nodes"], verbs: ["get", "list"] }, { apiGroups: ["argoproj.io"], resources: ["applications"], verbs: ["get", "list"] }, { apiGroups: ["postgresql.cnpg.io"], resources: ["clusters", "databases"], verbs: ["get", "list"] }] }) + "---\n" + stringify({ apiVersion: "rbac.authorization.k8s.io/v1", kind: "ClusterRoleBinding", metadata: { name: "aiops-collector" }, roleRef: { apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: "aiops-collector" }, subjects: [{ kind: "ServiceAccount", name: "aiops-collector", namespace: "observability" }] }), { mode: 0o600 });
  return { directory, activation: "pending-readiness", producers: ["alertmanager", "argocd", "cnpg"], required: ["namespace-specific-auth-secrets", "argocd-live-config-and-bootstrap-seed", "internal-firewall-and-networkpolicy", "producer-delivery-proof"] };
}
