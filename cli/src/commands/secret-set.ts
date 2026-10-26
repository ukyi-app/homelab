// homelab secret set: 앱 시크릿 하나를 Infisical /apps/<app>/<KEY>에 둔다(설계 C.7, D 4번). 값은 stdin(파이프) 또는
// tty(에코 없음)로만 받고 argv·출력·파일에 두지 않는다(rotate.md 3c 1: `secrets set KEY=VALUE`는 값이 명령행 인자라 쓰지 않는다).
// 등록 전에도 된다(설계 D는 app add보다 앞). 앱에 넣는 것은 values의 secrets 목록이고 app add 재실행이 더한다.
import { defineCommand, type Observation, type Step } from "../core/command";
import { APP_NAME, SECRET_KEY } from "../core/names";
import { parseYaml } from "../core/values";

const same = (detail: string): Observation => ({ state: "same", action: "none", detail });

export default defineCommand({
  path: ["secret", "set"],
  summary: "앱 시크릿 등록(값은 stdin)",
  kind: "change",
  args: [
    { name: "app", required: true, help: "앱 이름", pattern: APP_NAME },
    { name: "KEY", required: true, help: "키 이름", pattern: SECRET_KEY },
  ],
  flags: [{ name: "replace", kind: "bool", help: "이미 있는 키를 바꾼다" }],
  async run(ctx, input) {
    const app = input.args.app as string;
    const key = input.args.KEY as string;
    const replace = input.flags.replace === true;
    const folder = `/apps/${app}`;
    // --replace는 이 실행이 쓴 값의 해시와 같아야 same이다. 다시 실행하면 다시 바꾼다(명시적으로 요청한 일).
    let written: string | null = null;

    const step: Step = {
      id: "infisical-key",
      target: `Infisical homelab/prod ${folder}/${key}`,
      async read(c) {
        if (!c.infisical.folderExists(folder)) return { state: "missing", action: "create", detail: "없음 → 저장(폴더 포함, 값은 stdin)" };
        const hash = c.infisical.valueHash(folder, key);
        if (hash === null) return { state: "missing", action: "create", detail: "없음 → 저장(값은 stdin)" };
        if (!replace) return same("있음 (그대로. 바꾸려면 --replace)");
        if (written !== null && hash === written) return same("바꿨다");
        return { state: "differs", action: "update", detail: "있음 → 바꾼다(--replace, 값은 stdin)" };
      },
      async apply(w) {
        if (!w.infisical.folderExists(folder)) w.infisical.createFolder(folder);
        const value = w.readSecretInput(`${folder}/${key} 값: `);
        // 쓰기 전에 기억한다. 서버에는 반영됐는데 응답이 시간 초과면 엔진이 다시 읽어 이 해시로 반영을 확인한다(#884 리뷰 P2-3).
        written = value.sha256Prefix(12);
        w.infisical.setValue(folder, key, value);
      },
    };

    const notes: string[] = [];
    const values = ctx.repo.readFile(`apps/${app}/values.yaml`, ctx.repo.mainSha());
    const registered = values !== null;
    const v = (values === null ? null : parseYaml(values)) as { kind?: string; uses?: { postgres?: boolean; valkey?: boolean }; env?: Record<string, string> } | null;
    // 차트가 넣는 env(PORT·DATABASE_URL·VALKEY_URL)나 values env와 같은 이름이면 app add가 secrets에 넣는 순간 렌더가
    // 막힌다(#884 2라운드 P2-4). 쓰기 전에 멈춘다. 등록 전이면 차트가 넣을 수 있는 이름만 알린다.
    const taken = v ? [...(v.kind === "web" ? ["PORT"] : []), ...(v.uses?.postgres ? ["DATABASE_URL"] : []), ...(v.uses?.valkey ? ["VALKEY_URL"] : []), ...Object.keys(v.env ?? {})] : [];
    if (taken.includes(key)) {
      const blocked: Step = { id: "env-name", target: `env 이름 ${key}`, read: async () => ({ state: "differs", action: "none", detail: "차트·values env가 이미 쓰는 이름이다", next: `다른 키 이름을 쓰거나 apps/${app}/values.yaml의 env에서 ${key}를 뺀다` }) };
      return ctx.engine({ command: "secret set", app, steps: [blocked, step] });
    }
    if (!registered && ["PORT", "DATABASE_URL", "VALKEY_URL"].includes(key)) notes.push(`${key}는 차트가 넣을 수 있는 env 이름이다(web의 PORT, --postgres의 DATABASE_URL, Valkey의 VALKEY_URL). 그 기능을 켜면 등록이 막힌다`);
    if (registered) {
      const list = (parseYaml(values) as { secrets?: unknown } | null)?.secrets;
      if (!Array.isArray(list) || !list.includes(key)) notes.push(`apps/${app}/values.yaml secrets에 ${key}가 없어 앱에 들어가지 않는다. 더하기: homelab app add ${app}`);
    }
    return ctx.engine({
      command: "secret set",
      app,
      steps: [step],
      notes,
      // undefined를 돌려주면 엔진의 기본 다음 행동(pending이면 --apply)을 쓴다(engine.ts finish).
      next: (status) => (status === "done" && registered ? `homelab secret sync ${app}` : undefined) as string | null,
    });
  },
});
