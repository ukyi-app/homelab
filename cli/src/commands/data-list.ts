// homelab data list: 주인 없는 보존 데이터(설계 C.5.5의 판정 기준, L12). 줄마다 same이고(보고 대상이지 실패가 아니다)
// 읽기 실패만 exit 1이다. Infisical의 /apps/<app> 폴더는 세지 않는다(폴더 목록을 앱마다 읽어야 해서, 아래 notes).
import { defineCommand, type Observation, type ReadCtx, type Step } from "../core/command";

const same = (detail: string): Observation => ({ state: "same", action: "none", detail });
const listed = (names: string[]) => (names.length === 0 ? "없음" : `${names.length}개: ${names.join(", ")}`);

function dirs(ctx: ReadCtx, main: string, dir: "apps" | "data"): string[] {
  const r = ctx.gh.get(`repos/ukyi-app/homelab/contents/${dir}?ref=${main}`);
  if (r.status === 404) return [];
  if (r.status !== 200 || !Array.isArray(r.json)) throw new Error(`${dir}/ 목록: HTTP ${r.status}`);
  return r.json.filter((e: { type?: string }) => e?.type === "dir").map((e: { name: string }) => e.name).sort();
}

const nameOf = (o: any) => `${o?.metadata?.namespace ? `${o.metadata.namespace}/` : ""}${o?.metadata?.name}`;

export default defineCommand({
  path: ["data", "list"],
  summary: "주인 없는 보존 데이터",
  kind: "read",
  args: [],
  flags: [],
  async run(ctx) {
    const main = ctx.repo.mainSha();
    const steps: Step[] = [
      {
        id: "orphan-data",
        target: "data/<app>은 있고 apps/<app>은 없음",
        async read(c) {
          const apps = dirs(c, main, "apps");
          return same(listed(dirs(c, main, "data").filter((d) => !apps.includes(d))));
        },
      },
      {
        id: "orphan-database",
        target: "Database CR(database ns) 중 data/<app> 없음",
        async read(c) {
          const data = dirs(c, main, "data");
          return same(listed(c.k8s.list("database", "database").map((d: any) => String(d?.metadata?.name)).filter((n) => !data.includes(n)).sort()));
        },
      },
      {
        id: "released-pv",
        target: "PV Released",
        async read(c) {
          return same(listed(c.k8s.list("pv", null).filter((p: any) => p?.status?.phase === "Released").map((p: any) => `${p.metadata?.name}(${p.spec?.claimRef?.namespace}/${p.spec?.claimRef?.name})`)));
        },
      },
      {
        id: "unmounted-pvc",
        target: "PVC 중 마운트하는 파드 없음",
        async read(c) {
          const used = new Set(c.k8s.list("pod", null).flatMap((p: any) => (p?.spec?.volumes ?? []).filter((v: any) => v?.persistentVolumeClaim?.claimName).map((v: any) => `${p.metadata?.namespace}/${v.persistentVolumeClaim.claimName}`)));
          return same(listed(c.k8s.list("pvc", null).map(nameOf).filter((n) => !used.has(n)).sort()));
        },
      },
      {
        id: "restore-objects",
        target: "멈춘 복원 객체(라벨 homelab.ukyi.app/restore)",
        async read(c) {
          const kinds = ["cluster", "job", "pod", "pvc"] as const;
          return same(listed(kinds.flatMap((k) => c.k8s.list(k, null, "homelab.ukyi.app/restore").map((o: any) => `${k} ${nameOf(o)}`))));
        },
      },
    ];
    return ctx.engine({
      command: "data list",
      title: "homelab data list",
      steps,
      notes: ["Infisical /apps/<app> 키는 세지 않았다. 앱을 지운 뒤 남은 키는 data purge가 마지막에 지운다"],
    });
  },
});
