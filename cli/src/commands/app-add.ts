// homelab app add: 최초 등록 PR(설계 C.7, D 5~6번). 손 절차는 T11 #854·#855·#858·#860과 E5의 probe 손 등록.
// 재실행 same(AC-1, 설계 C.7 "재실행 안전"):
// - 비밀번호는 키가 있으면 재사용한다(값은 읽지도 바꾸지도 않는다).
// - 플래그는 더하기만 한다. 이 명령이 다루지 않는 키(migration·resources·주석)는 비교하지 않고 그대로 둔다.
// - image.yaml은 없을 때만 만든다. 등록 뒤에는 배포 App 소유다(AGENTS.md). 그래서 그사이 배포가 끼어도 same이다.
import { defineCommand, type Observation, type ReadCtx, type Step, type WriteCtx } from "../core/command";
import { APP_NAME, INTERNAL_NAME, PUBLIC_HOST, RESERVED_INTERNAL, appNameProblem } from "../core/names";
import { prStep } from "../core/pr";
import { CliError, UsageError } from "../core/result";
import { type AddFlags, type CacheMode, type Image, appValues, dataValues, describeFile, imageText, latestVersion, parseImage, parseObj } from "./app-add-values";

const same = (detail: string, extra: Partial<Observation> = {}): Observation => ({ state: "same", action: "none", detail, ...extra });
const bad = (state: "missing" | "differs", detail: string, next: string): Observation => ({ state, action: "none", detail, next });
// 내부 이름에 붙는 클러스터 접두 중 가장 긴 것(VM "vm-"). Tailscale 기기 이름은 63자까지(설계 C.4.4).
const LONGEST_PREFIX = 3;

type ImageFound = { image: Image } | { problem: Observation };

// GitHub 조회 실패(403·429·5xx)를 "없음"으로 읽지 않는다(#884 리뷰 P2-5). 404는 allow404일 때만 null.
function gh(ctx: ReadCtx, path: string, what: string, allow404 = false): any {
  const r = ctx.gh.get(path);
  if (allow404 && r.status === 404) return null;
  if (r.status !== 200) throw new CliError(`${what}: HTTP ${r.status}`, "gh auth status로 로그인·권한을 확인한 뒤 다시 실행한다");
  return r.json;
}

function latestChart(ctx: ReadCtx, prefix: string): string {
  const r = ctx.gh.get(`repos/ukyi-app/homelab/git/matching-refs/tags/${prefix}`);
  const v = r.status === 200 ? latestVersion(r.json, prefix) : null;
  if (!v) throw new CliError(`차트 태그 ${prefix}*를 읽지 못했다(HTTP ${r.status})`, "gh auth status로 로그인을 확인한 뒤 다시 실행한다");
  return v;
}

// DSSE payload(in-toto)가 이 앱 저장소 main의 그 커밋에서 만든 SLSA provenance인지.
export function attestationMatches(json: unknown, app: string, digest: string, revision: string): boolean {
  const list = (json as { attestations?: unknown })?.attestations;
  if (!Array.isArray(list)) return false;
  return list.some((a) => {
    try {
      const payload = a?.bundle?.dsseEnvelope?.payload;
      if (typeof payload !== "string") return false;
      const st = JSON.parse(Buffer.from(payload, "base64").toString("utf8"));
      const def = st?.predicate?.buildDefinition;
      return (
        st?.predicateType === "https://slsa.dev/provenance/v1" &&
        Array.isArray(st.subject) &&
        st.subject.some((s: { digest?: { sha256?: string } }) => `sha256:${s?.digest?.sha256}` === digest) &&
        def?.externalParameters?.workflow?.repository === `https://github.com/ukyi-app/${app}` &&
        def?.externalParameters?.workflow?.ref === "refs/heads/main" &&
        Array.isArray(def?.resolvedDependencies) &&
        def.resolvedDependencies.some((d: { digest?: { gitCommit?: string } }) => d?.digest?.gitCommit === revision)
      );
    } catch {
      return false;
    }
  });
}

// 앱 저장소 main HEAD의 이미지(태그 sha-<HEAD>, app-build.yaml push job)와 그 출처 확인.
function findImage(ctx: ReadCtx, app: string): ImageFound {
  const next = `빌드가 끝난 뒤 다시: ${ctx.line}`;
  const ref = gh(ctx, `repos/ukyi-app/${app}/git/ref/heads/main`, "앱 저장소 main", true);
  const head = ref?.object?.sha;
  if (ref === null) return { problem: bad("missing", "main이 없다", `앱 저장소 ukyi-app/${app}에 main을 만든다(템플릿)`) };
  if (typeof head !== "string") throw new Error("앱 저장소 main SHA를 읽지 못했다");
  // 패키지가 아직 없으면(첫 빌드 전) 404다.
  const versions = gh(ctx, `orgs/ukyi-app/packages/container/${app}/versions?per_page=100`, "GHCR 패키지 버전", true) ?? [];
  if (!Array.isArray(versions)) throw new Error("GHCR 패키지 버전: 목록이 아니다");
  const hit = versions.find((v: any) => Array.isArray(v?.metadata?.container?.tags) && v.metadata.container.tags.includes(`sha-${head}`));
  if (!hit || typeof hit.name !== "string") {
    const runs = gh(ctx, `repos/ukyi-app/${app}/actions/runs?branch=main&head_sha=${head}&per_page=5`, "앱 저장소 빌드 기록");
    if (!Array.isArray(runs?.workflow_runs)) throw new Error("앱 저장소 빌드 기록: 모양이 다르다");
    const run = runs.workflow_runs[0];
    const how = !run ? "빌드 기록 없음" : run.status !== "completed" ? `빌드 ${run.status}` : `빌드 ${run.conclusion}`;
    return { problem: bad("missing", `HEAD ${head.slice(0, 7)}의 이미지가 없다(${how})`, run?.status === "completed" ? `앱 저장소 Actions에서 빌드 실패 원인을 고친다(gh run view -R ukyi-app/${app} ${run.id})` : next) };
  }
  const digest: string = hit.name;
  // attestation이 없으면 404다. 그 밖의 실패는 "맞지 않음"이 아니라 읽기 실패다.
  const att = gh(ctx, `repos/ukyi-app/${app}/attestations/${digest}`, "build provenance", true);
  if (att === null || !attestationMatches(att, app, digest, head)) {
    return { problem: bad("differs", `이미지 ${digest.slice(0, 19)}…의 build provenance가 이 저장소 main ${head.slice(0, 7)}와 맞지 않는다`, `앱 저장소 main의 빌드(app-build)가 attestation을 만들었는지 본다: gh attestation verify oci://ghcr.io/ukyi-app/${app}@${digest} -R ukyi-app/${app}`) };
  }
  return { image: { repository: `ghcr.io/ukyi-app/${app}`, digest, revision: head, hold: false } };
}

export function passwordStep(app: string, kind: "postgres" | "valkey"): Step {
  const folder = `/apps/${app}/${kind}`;
  return {
    id: `infisical-${kind}`,
    target: `Infisical homelab/prod ${folder}/PASSWORD`,
    async read(ctx) {
      // 바깥 폴더부터 본다. 없는 부모의 목록을 읽으면 CLI가 실패할 수 있다(core folderExists 주석).
      if (!ctx.infisical.folderExists(`/apps/${app}`) || !ctx.infisical.folderExists(folder)) return { state: "missing", action: "create", detail: "없음 → 생성(폴더 포함)" };
      return ctx.infisical.has(folder, "PASSWORD") ? same("있음 (그대로 사용)") : { state: "missing", action: "create", detail: "없음 → 생성" };
    },
    async apply(w: WriteCtx) {
      if (!w.infisical.folderExists(`/apps/${app}`) || !w.infisical.folderExists(folder)) w.infisical.createFolder(folder);
      // 사이에 누가 만들었으면 덮지 않는다(재사용 원칙).
      if (!w.infisical.has(folder, "PASSWORD")) w.infisical.setValue(folder, "PASSWORD", w.generatePassword());
    },
  };
}

export default defineCommand({
  path: ["app", "add"],
  summary: "최초 등록(앱 values·image.yaml, 필요하면 DB·캐시) PR",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [
    { name: "public", kind: "value", valueName: "host", pattern: PUBLIC_HOST, help: "공개 host(<이름>.ukyi.app)" },
    { name: "internal", kind: "value", valueName: "name", pattern: INTERNAL_NAME, help: "tailnet 안 이름" },
    { name: "postgres", kind: "bool", help: "PostgreSQL 연결" },
    { name: "cache", kind: "optional-value", values: ["persistent"], help: "Valkey 연결(=persistent면 영속)" },
  ],
  async run(ctx, input) {
    const app = input.args.app as string;
    const cache: CacheMode = input.flags.cache === "persistent" ? "persistent" : input.flags.cache === true ? "cache" : "none";
    const flags: AddFlags = { public: input.flags.public as string | undefined, internal: input.flags.internal as string | undefined, postgres: input.flags.postgres === true, cache };
    const nameProblem = appNameProblem(app, { cache: cache === "cache", persistent: cache === "persistent" });
    if (nameProblem) throw new UsageError(nameProblem);
    if (flags.internal && (RESERVED_INTERNAL.includes(flags.internal) || flags.internal.length + LONGEST_PREFIX > 63)) throw new UsageError("--internal: 예약된 이름이거나 클러스터 접두를 붙이면 63자를 넘는다");

    const paths = { values: `apps/${app}/values.yaml`, image: `apps/${app}/image.yaml`, data: `data/${app}/values.yaml` };
    const main = ctx.repo.mainSha();
    const onMain = { values: ctx.repo.readFile(paths.values, main), image: ctx.repo.readFile(paths.image, main), data: ctx.repo.readFile(paths.data, main) };
    const appChart = latestChart(ctx, "app-chart-v");
    const dataChart = latestChart(ctx, "data-chart-v");
    // values secrets: Infisical /apps/<app>의 키(하위 폴더 postgres·valkey 제외). secret set이 앞서 넣은 키다(설계 D 4~5번).
    const secrets = ctx.infisical.folderExists(`/apps/${app}`) ? ctx.infisical.listKeys(`/apps/${app}`) : [];
    const found: ImageFound | null = onMain.image === null ? findImage(ctx, app) : null;

    const steps: Step[] = [
      {
        id: "config",
        target: "등록 조건",
        async read() {
          const v = onMain.values === null ? {} : parseObj(onMain.values, paths.values);
          const d = onMain.data === null ? {} : parseObj(onMain.data, paths.data);
          if (cache === "cache" && d.valkey?.persistent === true) return bad("differs", "이미 영속 Valkey다(data values valkey.persistent)", "--cache 없이 다시 실행한다(영속 Valkey가 VALKEY_URL을 준다)");
          // 캐시와 영속 Valkey는 이름이 같아(<앱>-valkey) 한 revision에 둘을 두지 못한다. 전환은 PR 둘(cache add --persistent).
          if (cache === "persistent" && v.cache?.enabled === true) return bad("differs", "캐시 Valkey가 켜져 있다(같은 이름이라 함께 둘 수 없다)", `homelab cache add ${app} --persistent`);
          if (onMain.image !== null) parseImage(onMain.image, app);
          return same(onMain.values === null ? "새 앱" : "이미 등록됨(플래그만 더한다)");
        },
      },
      {
        id: "app-repo",
        target: `앱 저장소 ukyi-app/${app}`,
        async read(c) {
          const repo = c.gh.get(`repos/ukyi-app/${app}`);
          if (repo.status === 404) return bad("missing", "없음", `homelab app new ${app}`);
          if (repo.status !== 200) throw new Error(`앱 저장소 읽기: HTTP ${repo.status}`);
          if (repo.json?.visibility !== "public") return bad("differs", `${repo.json?.visibility ?? "알 수 없음"} (public만 받는다, D-29)`, `저장소를 public으로 바꾸거나 등록하지 않는다`);
          const rs = gh(c, `repos/ukyi-app/${app}/rulesets`, "앱 저장소 ruleset");
          if (!Array.isArray(rs)) throw new Error("앱 저장소 ruleset: 목록이 아니다");
          const active = rs.some((r: any) => r?.name === "app-main" && r?.enforcement === "active");
          return active ? same("public, app-main active (자동 배포 가능)") : same("public, app-main 없음", { warn: "app-main이 active가 아니라 배포 PR이 자동 병합되지 않는다(조건 9). homelab github apply로 건다" });
        },
      },
      {
        id: "image",
        target: "이미지",
        async read() {
          if (onMain.image !== null) return same("image.yaml 있음 (배포 App 소유, 그대로)");
          if (found === null) throw new Error("이미지 조회가 빠졌다");
          if ("problem" in found) return found.problem;
          const i = found.image;
          return same(`${i.digest.slice(0, 19)}… revision ${i.revision.slice(0, 7)} (main HEAD, provenance 확인)`);
        },
      },
      {
        id: "ghcr-anon",
        target: `GHCR ghcr.io/ukyi-app/${app} 익명 pull`,
        async read(c) {
          const code = c.ghcr.anonymousPullStatus(app);
          return code === 200 ? same("200 (public 패키지)") : bad("differs", `${code} (익명으로 받을 수 없다, D-29)`, `패키지 설정에서 Public으로 바꾼다(github.com/orgs/ukyi-app/packages/container/${app}/settings)`);
        },
      },
    ];
    if (flags.postgres) steps.push(passwordStep(app, "postgres"));
    if (cache !== "none") steps.push(passwordStep(app, "valkey"));

    const image = found && "image" in found ? found.image : null;
    const files = [paths.values, paths.image, ...(flags.postgres || cache === "persistent" ? [paths.data] : [])];
    steps.push(
      prStep({
        command: "app add",
        app,
        title: `app add: ${app}`,
        body: [`homelab app add가 만든 등록 PR이다(설계 C.7). 검토 후 사람이 병합한다(자동 병합 조건 밖).`, "", `- 앱 ${app}${flags.public ? `, 공개 ${flags.public}` : ""}${flags.internal ? `, 내부 ${flags.internal}` : ""}${flags.postgres ? ", PostgreSQL" : ""}${cache === "cache" ? ", 캐시 Valkey" : cache === "persistent" ? ", 영속 Valkey" : ""}`, "- 비밀번호는 Infisical에만 있다(이 PR에는 키 이름뿐)."].join("\n"),
        files,
        edit(cur) {
          const out: Record<string, string | null> = {
            [paths.values]: appValues(cur[paths.values], flags, { secrets, latestChart: appChart }),
            [paths.image]: cur[paths.image] ?? (image ? imageText(image) : null),
          };
          if (files.includes(paths.data)) out[paths.data] = dataValues(cur[paths.data], flags, dataChart);
          return out;
        },
        describe: describeFile,
      }),
    );

    const notes: string[] = [];
    if (flags.public) notes.push(`${flags.public}은 공개된다. 공개 여부는 PR 병합으로 확정된다`);
    if (flags.postgres) notes.push("데이터 Application이 늦으면 마이그레이션 Job이 한 번 실패하고 retry로 수렴한다(시나리오 2)");
    return ctx.engine({
      command: "app add",
      app,
      steps,
      notes,
    });
  },
});
