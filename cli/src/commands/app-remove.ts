// homelab app remove: apps/<app>/ 삭제 PR(설계 C.5.5, G 시나리오 9, 손 절차 T11 #867). 앱 워크로드만 사라지고
// 데이터(data/<app>, DB·역할, 영속 Valkey PVC, Infisical 키)는 다른 Application이라 남는다. 폐기는 data purge로만.
// 모르는 파일이 있는 디렉터리는 지우지 않는다(이 명령이 만든 두 파일만 다룬다).
// 봇이면 bot-slot target을 먼저 되돌려야 한다. 남기면 다음 콜드스타트에서 bot-slot이 끝없이 기다린다(설계 C.8).
import { defineCommand, type Observation, type Step } from "../core/command";
import { APP_NAME } from "../core/names";
import { prStep } from "../core/pr";
import { parseYaml } from "../core/values";

const same = (detail: string): Observation => ({ state: "same", action: "none", detail });
const KNOWN = ["image.yaml", "values.yaml"];
const BOT_SLOT = "platform/bot-slot/values.yaml";
const botTarget = (text: string | null) => (text === null ? undefined : (parseYaml(text) as { target?: { app?: string } } | null)?.target?.app);

export default defineCommand({
  path: ["app", "remove"],
  summary: "앱 삭제(데이터 보존) PR",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [],
  async run(ctx, input) {
    const app = input.args.app as string;
    const main = ctx.repo.mainSha();
    const files = KNOWN.map((f) => `apps/${app}/${f}`);

    const steps: Step[] = [
      {
        id: "files",
        target: `apps/${app}/`,
        async read(c) {
          // 시작 때 스냅샷이 아니라 읽는 그때의 main을 본다(apply 직전 재조회가 그사이 더해진 파일을 잡게).
          const r = c.gh.get(`repos/ukyi-app/homelab/contents/apps/${app}?ref=${c.repo.mainSha()}`);
          if (r.status === 404) return same("없음(이미 지웠다)");
          if (r.status !== 200 || !Array.isArray(r.json)) throw new Error(`apps/${app} 목록: HTTP ${r.status}`);
          const extra = r.json.map((e: { name?: string }) => String(e?.name)).filter((n: string) => !KNOWN.includes(n));
          return extra.length === 0 ? same("values.yaml·image.yaml") : { state: "differs", action: "none", detail: `모르는 파일 ${extra.length}개(${extra.join(", ")})`, next: "그 파일을 따로 정리한 뒤 다시 실행한다" };
        },
      },
      {
        id: "bot-slot",
        target: "platform/bot-slot/values.yaml target",
        async read(c) {
          if (botTarget(c.repo.readFile(BOT_SLOT, c.repo.mainSha())) !== app) return same("이 앱이 아니다");
          return { state: "differs", action: "none", detail: "bot-slot target이 이 앱이다", next: "먼저 platform/bot-slot/values.yaml의 target을 시험 값으로 되돌리고 probe: true를 켜는 PR을 병합한다(설계 C.8 콜드스타트)" };
        },
      },
      prStep({
        command: "app remove",
        app,
        title: `app remove: ${app}`,
        body: `homelab app remove가 만든 PR이다(설계 C.5.5). apps/${app}/를 지워 Application ${app}과 워크로드를 없앤다. 데이터(data/${app}, DB·영속 Valkey·Infisical 키)는 남는다. 목록: homelab data list, 폐기: homelab data purge ${app} --confirm ${app}`,
        // bot-slot은 PR 계산 때의 main에서도 본다(읽기만, 바뀌지 않아 tree에 안 들어간다). 확인 단계 뒤 그사이 target이 이 앱으로
        // 바뀌었으면 삭제 PR을 만들지 않는다(#890 1라운드 P2-3).
        files: [...files, BOT_SLOT],
        edit: (cur) => {
          if (botTarget(cur[BOT_SLOT]) === app) throw new Error(`그사이 main의 bot-slot target이 ${app}이 됐다. 먼저 target을 시험 값으로 되돌리고 probe: true를 켜는 PR을 병합한다(설계 C.8)`);
          return { ...Object.fromEntries(files.map((f) => [f, null])), [BOT_SLOT]: cur[BOT_SLOT] };
        },
        describe: (path) => (path === BOT_SLOT ? "그대로" : "삭제"),
      }),
    ];
    const notes: string[] = [];
    if (ctx.repo.readFile(`data/${app}/values.yaml`, main) !== null) notes.push(`데이터는 남는다(data/${app}). 목록: homelab data list, 폐기: homelab data purge ${app} --confirm ${app}`);
    return ctx.engine({ command: "app remove", app, steps, notes });
  },
});
