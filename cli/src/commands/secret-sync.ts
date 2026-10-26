// homelab secret sync: 앱 자체 키(<app>-app)를 즉시 동기화하고 앱을 다시 띄운다(설계 C.7, rotate.md 0절 + 3c 4단계).
// 범위는 <app>-app뿐이다. <app>-db·<app>-valkey-*·pg-role-<app>은 순서가 있는 회전(db rotate·cache rotate)의 몫이다:
// valkey-auth만 바꾸고 서버를 다시 띄우지 않으면 앱이 새 VALKEY_URL로 인증에 실패한다.
// same 판정: 동기화는 키마다 Kubernetes Secret 해시 = Infisical 값 해시, 재시작은 파드 템플릿의 참조 Secret 표식이 지금
// resourceVersion과 같고 rollout이 끝났는지(core restartForSecrets). 값이 그대로면 다시 실행해도 재시작하지 않는다.
import { defineCommand, type Observation, type ReadCtx, type Step } from "../core/command";
import { APP_NAME } from "../core/names";
import { parseYaml } from "../core/values";

const same = (detail: string, extra: Partial<Observation> = {}): Observation => ({ state: "same", action: "none", detail, ...extra });

// JSON 값의 구조 비교(키 순서 무시). Argo CD는 source를 reflect.DeepEqual로 비교한다. valuesObject는 API 서버가 키를
// 정렬해 저장하므로 바이트 비교와 구조 비교가 같은 답을 낸다.
function sameJson(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((x, i) => sameJson(x, b[i]));
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return false;
  const ka = Object.keys(a).sort();
  const kb = Object.keys(b).sort();
  return ka.length === kb.length && ka.every((k, i) => k === kb[i] && sameJson((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]));
}

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
    // Argo CD가 받은 values(ApplicationSet이 main에서 읽어 넣은 helm.valuesObject)에 main의 secrets가 다 있는지.
    const covers = (source: any) => {
      const got = source?.helm?.valuesObject?.secrets;
      return Array.isArray(got) && keys.every((k) => got.includes(k));
    };
    const stuck = (detail: string): Observation => ({
      state: "missing",
      action: "none",
      detail,
      next: `kubectl -n argocd get application ${app} -o yaml로 원인(status.conditions·operationState)을 보고, 고친 뒤 명시 sync한다(Argo CD가 다시 시도하지 않는다). 그 뒤 같은 명령을 다시 실행한다`,
    });
    // 앱 Application을 만들거나 values를 넣는 것은 부모 ApplicationSet apps다. 생성 오류는 자식이 아니라 부모 status에만 남고
    // (ErrorOccurred, status "True"), 원인이 남아 있는 동안 몇 번을 다시 쳐도 자식은 그대로다(v3.5.5 applicationset_controller.go).
    // Application condition과 달리 status가 있어 "False"는 오류가 아니다.
    const appsetOr = (c: ReadCtx, missing: string, wait: Observation): Observation => {
      const set = c.k8s.get("applicationset", "argocd", "apps");
      if (set === null) return { state: "missing", action: "none", detail: `${missing}, ApplicationSet apps 없음`, next: "kubectl -n argocd get application appset-apps -o yaml로 ApplicationSet apps를 만드는 root 쪽 Application을 본다. 고친 뒤 같은 명령을 다시 실행한다" };
      const err = (Array.isArray(set.status?.conditions) ? set.status.conditions : []).find((x: any) => x?.type === "ErrorOccurred" && x?.status === "True");
      if (!err) return wait;
      return {
        state: "missing",
        action: "none",
        detail: `${missing}, ApplicationSet apps ErrorOccurred(${typeof err.reason === "string" ? err.reason : "이유 없음"})`,
        next: `kubectl -n argocd get applicationset apps -o yaml로 status.conditions를 보고 원인(보통 apps/${app}/ 파일)을 고친다. ApplicationSet이 60초 안에 다시 만들므로 명시 sync는 필요 없다. 그 뒤 같은 명령을 다시 실행한다`,
      };
    };
    // what(ExternalSecret 또는 Deployment)이 아직 없을 때: Argo CD가 반영 중이면 대기(3), 끝났는데 없으면 실패(1).
    const judge = (c: ReadCtx, what: string): Observation => {
      const a = c.k8s.get("application", "argocd", app);
      if (a === null) return appsetOr(c, `${what} 없음`, same("앱 Application 없음", { hold: "ApplicationSet이 앱 Application을 만들기를 기다림" }));
      if (!covers(a.spec?.source)) return appsetOr(c, `${what} 없음`, same("values의 secrets 반영 전", { hold: "ApplicationSet이 values의 secrets를 앱 Application에 넣기를 기다림" }));
      const st = a.status ?? {};
      // conditions·sync·operationState는 컨트롤러가 한 번의 조정에서 함께 쓴다. comparedTo.source가 지금 spec.source와 다르면
      // 새 source(차트 버전·values)를 아직 조정하지 않은 것이라, 남은 SyncError·Failed는 옛 source의 것이다(Argo CD도 이 차이를
      // "spec 바뀜"으로 본다, v3.5.5 state.go specEqualsCompareTo). 비교가 실패해도 comparedTo는 새 source로 쓰이므로(같은 파일
      // CompareAppState, 저장소 오류 유예 동안만 예외) 깨진 새 차트도 유예 뒤에는 아래 ComparisonError로 실패한다.
      if (!sameJson(a.spec?.source, st.sync?.comparedTo?.source)) return same("새 source 비교 전", { hold: "Argo CD가 새 source를 비교하기를 기다림" });
      const err = (Array.isArray(st.conditions) ? st.conditions : []).find((x: any) => typeof x?.type === "string" && x.type.endsWith("Error"));
      if (err) return stuck(`${what} 없음, 앱 Application ${err.type}`);
      const op = st.operationState;
      if (op?.phase === "Running") return same(`동기화 진행 중(재시도 ${op.retryCount ?? 0}회)`, { hold: "Argo CD 동기화가 끝나기를 기다림" });
      // 자동 동기화는 마지막 동기화가 지금 revision·source(전체)로 한 것이면 다시 하지 않는다(v3.5.5 alreadyAttemptedSync).
      // 차트 버전이나 다른 값만 바뀌어도 새 시도다. secrets 키가 같다는 것으로는 가를 수 없다(#913 r2 P2-1).
      // 결과가 없는 끝난 동기화도 시도한 것으로 본다(같은 함수). sync.revision을 모르면 source만 본다. 모르는 값을 "다름"으로
      // 읽으면 재시도 소진(r1 P2-1)이 대기로 되돌아간다.
      const sameRev = (r: unknown) => typeof st.sync?.revision !== "string" || r === st.sync.revision;
      const attempted = op ? (op.syncResult ? sameRev(op.syncResult.revision) && sameJson(a.spec?.source, op.syncResult.source) : ["Succeeded", "Failed", "Error"].includes(op.phase)) : false;
      if (attempted && (op.phase === "Failed" || op.phase === "Error")) return stuck(`${what} 없음, 동기화 ${op.phase}(재시도 ${op.retryCount ?? 0}회 뒤 멈춤)`);
      if (st.sync?.status === "Synced") return stuck(`${what} 없음, 앱 Application은 Synced`);
      return same("동기화 전", { hold: "Argo CD가 지금 source로 동기화를 시작하기를 기다림" });
    };

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
        // ExternalSecret(wave 0)이나 Deployment(wave 2)가 없을 때 Argo CD가 아직 반영 중이면 대기(3), 끝났는데 멈췄으면
        // 실패(T12-05 F3, #913 r1 P2-1·r2). 첫 배포는 그 사이(ExternalSecret만 있음)를 지난다. values는 ApplicationSet이 main을
        // 60초마다 읽어 Application의 helm.valuesObject로 넣는다(applicationset.yaml). 재시도(limit 10)가 도는 동안
        // operationState.phase는 Running이고, 소진되거나 재시도 없이 끝나면 Failed·Error로 남아 다시 하지 않는다(명시 sync가
        // 필요, _helpers.tpl homelab.retry). 쓰기가 없는 확인 단계에 두어 hold는 실행 전 읽기에서만 난다. 아래 sync의 실행 뒤
        // 재조회는 hold로 넘어가지 않는다(r1 P2-2).
        id: "argo",
        target: `Argo CD ${app}`,
        async read(c) {
          if (c.k8s.get("externalsecret", ns, es) === null) return judge(c, "ExternalSecret");
          if (c.k8s.get("deployment", ns, app) === null) return judge(c, "Deployment");
          return same("ExternalSecret·Deployment 있음");
        },
      },
      {
        id: "sync",
        target: `ExternalSecret ${ns}/${es}`,
        async read(c) {
          // 앞 확인 단계가 없음을 대기·실패로 가른다. 여기서 없음은 그 뒤 사라진 것이다. 실행 뒤 재조회에서 없으면 엔진이
          // 결과 미상 실패로 끝낸다("반영 확인"은 아래 Secret 일치로만 난다).
          if (c.k8s.get("externalsecret", ns, es) === null) return { state: "missing", action: "none", detail: "없음" };
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
          // 앞 단계가 ExternalSecret·Deployment를 기다리는 동안 그 읽기 실패로 전체 읽기를 막지 않는다(대기·실패는 앞 단계가 가른다).
          if (c.k8s.get("externalsecret", ns, es) === null) return { state: "differs", action: "update", detail: "ExternalSecret이 생긴 뒤 확인" };
          let p: ReturnType<ReadCtx["k8s"]["podSecretsCurrent"]>;
          try {
            p = c.k8s.podSecretsCurrent(ns, app);
          } catch (e) {
            // Deployment가 없어서 난 실패만 바꾼다. 다른 읽기 실패(시간 초과 등)는 그대로 올린다.
            if (c.k8s.get("deployment", ns, app) === null) return { state: "differs", action: "update", detail: "Deployment가 생긴 뒤 확인" };
            throw e;
          }
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
