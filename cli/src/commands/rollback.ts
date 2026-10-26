// homelab rollback: 이미지 롤백·해제 PR(설계 C.4.9). image.yaml을 git 기록의 이전 값 + hold: true로 되돌리고,
// --release는 hold: false만 바꾼다. 자동 병합 조건 1 밖이라 사람이 병합한다. Argo CD의 rollback 기능은 쓰지 않는다
// (selfHeal이 Git 상태로 되돌린다). hold: true면 새 빌드는 배포 PR을 만들지 않는다(app-build deploy-pr).
// 함정: 열린 deploy/<app> PR은 롤백보다 먼저 병합되면 롤백을 덮는다. 롤백이 먼저 병합되면 hold가 달라져 조건 4로 막힌다.
import { defineCommand, type Observation, type ReadCtx, type Step } from "../core/command";
import { APP_NAME, GIT_SHA, IMAGE_DIGEST, fullMatch } from "../core/names";
import { prStep } from "../core/pr";
import { CliError, UsageError } from "../core/result";

type Image = { repository: string; digest: string; revision: string; hold: boolean };
const same = (detail: string, extra: Partial<Observation> = {}): Observation => ({ state: "same", action: "none", detail, ...extra });
// image.yaml 기록을 몇 커밋까지 거슬러 볼지. 커밋마다 파일을 한 번 읽는다.
const HISTORY = 30;

// app-build의 read_image와 같은 엄격한 4줄(주석·빈 줄만 더 허용).
export function parseImage(text: string, app: string): Image {
  const lines = text.split("\n").filter((l) => !/^\s*(#.*)?$/.test(l));
  const field = (k: string) => {
    const hits = lines.filter((l) => l.startsWith(`${k}: `));
    return hits.length === 1 ? hits[0].slice(k.length + 2) : undefined;
  };
  const [repository, digest, revision, hold] = ["repository", "digest", "revision", "hold"].map(field);
  if (lines.length !== 4 || repository !== `ghcr.io/ukyi-app/${app}` || !digest || !fullMatch(IMAGE_DIGEST, digest) || !revision || !fullMatch(GIT_SHA, revision) || (hold !== "true" && hold !== "false")) {
    throw new Error(`apps/${app}/image.yaml 형식이 아니다(4줄: repository·digest·revision·hold)`);
  }
  return { repository, digest, revision, hold: hold === "true" };
}

export const imageText = (i: Image) => `repository: ${i.repository}\ndigest: ${i.digest}\nrevision: ${i.revision}\nhold: ${i.hold}\n`;

// 기록에서 --to(revision 7자 이상 접두 또는 digest)에 맞는 서로 다른 이미지들.
export function matches(history: Image[], to: string): Image[] {
  const hit = history.filter((i) => (to.startsWith("sha256:") ? i.digest === to : i.revision.startsWith(to)));
  return [...new Map(hit.map((i) => [`${i.digest} ${i.revision}`, i])).values()];
}

function history(ctx: ReadCtx, app: string, path: string): Image[] {
  const r = ctx.gh.get(`repos/ukyi-app/homelab/commits?path=${path}&sha=main&per_page=${HISTORY}`);
  if (r.status !== 200 || !Array.isArray(r.json)) throw new CliError(`${path} 기록을 읽지 못했다(HTTP ${r.status})`, "gh auth status로 로그인을 확인한 뒤 다시 실행한다");
  const out: Image[] = [];
  for (const c of r.json) {
    if (typeof c?.sha !== "string" || !fullMatch(GIT_SHA, c.sha)) continue;
    const text = ctx.repo.readFile(path, c.sha);
    if (text === null) continue;
    try {
      out.push(parseImage(text, app));
    } catch {
      // 옛 형식 커밋은 건너뛴다(되돌릴 대상이 아니다).
    }
  }
  return out;
}

export default defineCommand({
  path: ["rollback"],
  summary: "이미지 롤백·해제 PR",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [
    { name: "to", kind: "value", valueName: "rev|digest", pattern: /[0-9a-f]{7,40}|sha256:[0-9a-f]{64}/, help: "되돌릴 revision(7자 이상) 또는 digest" },
    { name: "release", kind: "bool", help: "롤백 고정을 푼다" },
  ],
  async run(ctx, input) {
    const app = input.args.app as string;
    const to = input.flags.to as string | undefined;
    const release = input.flags.release === true;
    if ((to === undefined) === !release) throw new UsageError("--to <rev|digest>와 --release 중 하나만 준다");
    const path = `apps/${app}/image.yaml`;
    const text = ctx.repo.readFile(path, ctx.repo.mainSha());
    const current = text === null ? null : parseImage(text, app);

    let target: Image | null = null;
    let problem: Observation | null = null;
    if (current !== null && to !== undefined) {
      const hit = matches(history(ctx, app, path), to);
      if (hit.length === 0) problem = { state: "missing", action: "none", detail: `최근 ${HISTORY}개 기록에 ${to}가 없다`, next: `기록 확인: gh api 'repos/ukyi-app/homelab/commits?path=${path}' --jq '.[].sha'` };
      else if (hit.length > 1) problem = { state: "differs", action: "none", detail: `${to}에 맞는 이미지가 ${hit.length}개다`, next: "더 긴 revision이나 digest로 다시 실행한다" };
      else {
        target = { ...hit[0], hold: true };
        // 지워진 패키지 버전으로 되돌리면 파드가 이미지를 받지 못한다.
        const v = ctx.gh.get(`orgs/ukyi-app/packages/container/${app}/versions?per_page=100`);
        // 조회 실패(403·5xx)를 "지워졌다"로 읽지 않는다(#884 리뷰 P2-5). 패키지 자체가 없으면 404다.
        if (v.status !== 200 && v.status !== 404) throw new CliError(`GHCR 패키지 버전: HTTP ${v.status}`, "gh auth status로 로그인·권한(read:packages)을 확인한 뒤 다시 실행한다");
        if (v.status === 200 && !Array.isArray(v.json)) throw new Error("GHCR 패키지 버전: 목록이 아니다");
        if (v.status === 404 || !v.json.some((x: { name?: string }) => x?.name === target!.digest)) problem = { state: "missing", action: "none", detail: `GHCR에 ${target.digest.slice(0, 19)}…가 없다(지워졌거나 최근 100개 밖)`, next: "다른 revision을 고른다" };
      }
    }

    const steps: Step[] = [
      {
        id: "image",
        target: path,
        async read() {
          if (current === null) return { state: "missing", action: "none", detail: "없음(등록 전)", next: `homelab app add ${app}` };
          if (problem) return problem;
          return same(`지금 ${current.digest.slice(0, 19)}… revision ${current.revision.slice(0, 7)} hold ${current.hold}`);
        },
      },
      {
        id: "deploy-pr",
        target: `배포 PR deploy/${app}`,
        async read(c) {
          const r = c.gh.get(`repos/ukyi-app/homelab/pulls?head=${encodeURIComponent(`ukyi-app:deploy/${app}`)}&state=open`);
          if (r.status !== 200 || !Array.isArray(r.json)) throw new Error(`열린 배포 PR 찾기: HTTP ${r.status}`);
          const open = r.json[0];
          if (release || !open) return same(open ? `PR #${open.number} 열림` : "열린 배포 PR 없음");
          return same(`PR #${open.number} 열림`, { warn: `배포 PR #${open.number}이 롤백보다 먼저 자동 병합될 수 있다. 닫는다: gh pr close ${open.number} -R ukyi-app/homelab` });
        },
      },
      prStep({
        command: "rollback",
        app,
        title: release ? `rollback: ${app} 고정 해제(hold: false)` : `rollback: ${app} → ${target?.revision.slice(0, 7)}`,
        body: release
          ? `homelab rollback --release가 만든 PR이다(설계 C.4.9). hold를 풀어 다음 빌드부터 정상 배포 흐름으로 돌아간다.`
          : `homelab rollback이 만든 PR이다(설계 C.4.9). image.yaml을 이전 이미지로 되돌리고 hold: true로 새 배포 PR을 멈춘다. 데이터는 바뀌지 않는다. 풀기: homelab rollback ${app} --release`,
        files: [path],
        // --release는 PR을 계산하는 그때의 main 이미지에서 hold만 푼다(#884 리뷰 P2-2). 시작 때 읽은 이미지를 쓰면
        // 그사이 병합된 배포·롤백의 digest·revision을 되돌린다. --to는 사람이 고른 이미지라 고정한다.
        edit: (cur) => {
          if (cur[path] === null) return { [path]: null };
          if (release) return { [path]: imageText({ ...parseImage(cur[path], app), hold: false }) };
          return { [path]: target === null ? cur[path] : imageText({ ...target, repository: `ghcr.io/ukyi-app/${app}` }) };
        },
        describe: (_p, before, after) => {
          const b = before ? parseImage(before, app) : null;
          const a = after ? parseImage(after, app) : null;
          return `${b?.revision.slice(0, 7)} hold ${b?.hold} → ${a?.revision.slice(0, 7)} hold ${a?.hold}`;
        },
      }),
    ];
    return ctx.engine({ command: "rollback", app, steps });
  },
});
