// homelab secret sync: 앱 자체 키(<app>-app)를 즉시 동기화하고 앱을 다시 띄운다(설계 C.7, rotate.md 0절 + 3c 4단계).
// 범위는 <app>-app뿐이다. <app>-db·<app>-valkey-*·pg-role-<app>은 순서가 있는 회전(db rotate·cache rotate)의 몫이다:
// valkey-auth만 바꾸고 서버를 다시 띄우지 않으면 앱이 새 VALKEY_URL로 인증에 실패한다.
// same 판정: 동기화는 키마다 Kubernetes Secret 해시 = Infisical 값 해시, 재시작은 파드 템플릿의 참조 Secret 표식이 지금
// resourceVersion과 같고 rollout이 끝났는지(core restartForSecrets). 값이 그대로면 다시 실행해도 재시작하지 않는다.
import { defineCommand, type Observation, type Step } from "../core/command";
import { APP_NAME } from "../core/names";
import { parseYaml } from "../core/values";

const same = (detail: string, extra: Partial<Observation> = {}): Observation => ({ state: "same", action: "none", detail, ...extra });

export default defineCommand({
  path: ["secret", "sync"],
  summary: "즉시 동기화 + 재시작",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [],
  async run(ctx, input) {
    const app = input.args.app as string;
    const ns = `app-${app}`;
    const es = `${app}-app`;
    const folder = `/apps/${app}`;
    const text = ctx.repo.readFile(`apps/${app}/values.yaml`, ctx.repo.mainSha());
    const listed = text === null ? undefined : (parseYaml(text) as { secrets?: unknown } | null)?.secrets;
    const keys = Array.isArray(listed) ? listed.filter((k): k is string => typeof k === "string") : [];

    const steps: Step[] = [
      {
        id: "registered",
        target: `apps/${app}/values.yaml secrets`,
        async read() {
          if (text === null) return { state: "missing", action: "none", detail: "등록 전", next: `homelab app add ${app}` };
          return keys.length ? same(keys.join(", ")) : { state: "missing", action: "none", detail: "secrets 없음(동기화할 앱 키가 없다)", next: `homelab secret set ${app} <KEY> 뒤 homelab app add ${app}` };
        },
      },
      {
        id: "infisical-keys",
        target: `Infisical homelab/prod ${folder}`,
        async read(c) {
          const have = c.infisical.folderExists(folder) ? c.infisical.listKeys(folder) : [];
          const lost = keys.filter((k) => !have.includes(k));
          return lost.length === 0 ? same(`키 ${keys.length}개 있음`) : { state: "missing", action: "none", detail: `없음: ${lost.join(", ")}`, next: `homelab secret set ${app} ${lost[0]}` };
        },
      },
      {
        id: "sync",
        target: `ExternalSecret ${ns}/${es}`,
        async read(c) {
          // values의 secrets는 main에 있는데 ExternalSecret이 없으면 Argo CD가 아직 반영하지 않은 것이다(T12-05 F3). 실패가 아니라
          // 대기로 멈추고 다시 치면 잇는다. secrets가 없거나 등록 전이면 앞 확인 단계가 먼저 실패한다.
          if (c.k8s.get("externalsecret", ns, es) === null) return same("없음", { hold: "Argo CD가 values의 secrets를 반영해 ExternalSecret을 만들기를 기다림" });
          const stale = keys.filter((k) => c.k8s.secretHash(ns, es, k) !== c.infisical.valueHash(folder, k));
          return stale.length === 0 ? same("Secret이 Infisical과 같음") : { state: "differs", action: "update", detail: `다른 키 ${stale.length}개 → force-sync` };
        },
        async apply(w) {
          // 갱신될 때까지 기다린다. 넘으면 엔진이 재조회한다(재시도하지 않는다).
          w.k8s.forceSync(ns, es, { waitSec: 60 });
        },
      },
      {
        id: "restart",
        target: `Deployment ${ns}/${app}`,
        async read(c) {
          // 앞 단계가 ExternalSecret을 기다리는 동안은 새 앱이면 Deployment도 아직 없다. 그 읽기 실패로 전체 읽기를 막지 않는다.
          if (c.k8s.get("externalsecret", ns, es) === null) return { state: "differs", action: "update", detail: "ExternalSecret이 생긴 뒤 확인" };
          const p = c.k8s.podSecretsCurrent(ns, app);
          if (p.current && p.rolledOut) return same("파드가 지금 Secret으로 떠 있음");
          return { state: "differs", action: "update", detail: p.current ? "rollout 진행 중" : "파드가 옛 Secret → 재시작" };
        },
        async apply(w) {
          w.k8s.restartForSecrets(ns, app);
          if (!w.k8s.rolloutStatus(ns, app, 180)) throw new Error(`rollout이 180초 안에 끝나지 않았다. 확인: kubectl -n ${ns} rollout status deploy/${app}`);
        },
      },
    ];
    return ctx.engine({ command: "secret sync", app, steps });
  },
});
