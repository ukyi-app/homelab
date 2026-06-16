#!/usr/bin/env node
// GHCR 폴링 bump 플래너 — update-image의 권위 경로 (앱 레포 자격/입력 0).
//
// 신뢰 경계: `source-repo` 바인딩(homelab 소유) + GitHub API(앱 레포 main 커밋, reader App
// 토큰) + GHCR manifest 실존만 신뢰한다. 앱 레포가 보낸 어떤 payload도 받지 않는다.
//
// 후진 배포 차단: GHCR 버전 목록의 시간 순서는 빌드 완료 역전으로 git 순서와 어긋날 수 있다 —
// 따라서 **앱 레포 main 커밋 목록(최신순)이 권위**다. 배포된 source SHA(values image.tag)가
// main의 조상임을 compare로 증명하고, main을 최신→과거로 걸으며 "이미지가 실존하는 첫 커밋"을
// 후보로 고른 뒤 후보가 배포 SHA의 descendant임을 다시 증명한다(non-fast-forward 거부).
//
// 배포 승인 보존: .bindings.json의 autoDeploy가 true일 때만 "bump"(자동 PR+auto-merge),
// false거나 **누락이면 fail-closed**로 "propose-pr"(사람 머지 = 승인)만 낸다.
//
// 이 스크립트는 플래너(읽기 전용)다 — 실제 bump/PR은 bump-poll.yaml이 plan JSON을 소비해 수행.
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { parse } from "yaml";

const USAGE = `poll-ghcr — GHCR 폴링 bump 플래너(읽기 전용, update-image 권위 경로)
사용법: node tools/poll-ghcr.mjs [--dry-run] [--root <dir>] [--owner <org>] [--fixtures <dir>]
  --dry-run         plan JSON만 출력(부작용 0)
  --root <dir>      레포 루트(기본 .)
  --owner <org>     GHCR org(기본 ukyi-app)
  --fixtures <dir>  테스트 픽스처 소스(라이브 gh/docker 대체)
  --help, -h        이 도움말`;

const args = { root: ".", owner: "ukyi-app" };
const argv = process.argv.slice(2);
if (argv.includes("--help") || argv.includes("-h")) { console.log(USAGE); process.exit(0); }
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--dry-run") args.dryRun = true;
  else if (a === "--root") args.root = argv[++i];
  else if (a === "--fixtures") args.fixtures = argv[++i];
  else if (a === "--owner") args.owner = argv[++i];
  else {
    console.error(`알 수 없는 인자: ${a}`);
    process.exit(2);
  }
}

const short = (sha) => sha.slice(0, 7);

// 데이터 소스 추상화 — 테스트는 fixtures 디렉토리, 라이브는 gh api + docker manifest inspect.
// (GHCR versions API 대신 "main 커밋 → manifest 실존" 순서로 묻는다 — 위 후진 배포 차단 참고.)
function makeQuery(app) {
  if (args.fixtures) {
    const fx = (name) => {
      const p = path.join(args.fixtures, `${app}.${name}.json`);
      return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
    };
    return {
      commits: (src) => fx("commits") ?? [],
      compare: (src, base, head) => fx(`compare-${short(base)}-${head === "main" ? "main" : short(head)}`),
      manifest: (repo, tag) => fx(`manifest-${tag.slice(0, 11)}`), // sha- + 7자
    };
  }
  const gh = (p) => JSON.parse(execFileSync("gh", ["api", p], { encoding: "utf8" }));
  return {
    commits: (src) => gh(`repos/${src}/commits?sha=main&per_page=30`),
    compare: (src, base, head) => gh(`repos/${src}/compare/${base}...${head}`),
    manifest: (repo, tag) => {
      try {
        const out = execFileSync(
          "docker", ["buildx", "imagetools", "inspect", `${repo}:${tag}`, "--format", "{{json .Manifest}}"],
          { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
        );
        return { digest: JSON.parse(out).digest };
      } catch {
        return null; // 미존재 — 빌드 안 된 커밋
      }
    },
  };
}

function planApp(dir, app) {
  const read = (f) => readFileSync(path.join(dir, f), "utf8");
  const result = { app, action: "noop", reason: "", current: null, candidate: null };

  const src = read("source-repo").trim();
  result.src = src;
  if (!new RegExp(`^${args.owner}/[A-Za-z0-9._-]+$`).test(src)) {
    return { ...result, action: "refuse", reason: `source-repo가 ${args.owner} org 밖: ${src}` };
  }

  const values = parse(read("values.yaml"));
  const repo = values?.image?.repo ?? "";
  const tag = String(values?.image?.tag ?? "");
  const digest = values?.image?.digest ?? null;
  result.current = { tag, digest };
  if (!/^sha-[0-9a-f]{7,40}$/.test(tag)) {
    return { ...result, action: "refuse", reason: `배포 tag가 sha-* 형식이 아니라 조상 증명 불가: ${tag}` };
  }
  const deployed = tag.slice(4);

  // 승인 정책: autoDeploy === true만 자동, 그 외(false/누락/파싱 불가)는 전부 fail-closed
  let autoDeploy = false;
  const bindingsPath = path.join(dir, ".bindings.json");
  if (existsSync(bindingsPath)) {
    try {
      autoDeploy = JSON.parse(readFileSync(bindingsPath, "utf8")).autoDeploy === true;
    } catch {
      autoDeploy = false;
    }
  }

  const q = makeQuery(app);

  // (a) 배포 SHA가 main의 조상인가 — 아니면 수동 rollback/이력 조작 상황: 자동 폴링 거부
  const baseCmp = q.compare(src, deployed, "main");
  if (!baseCmp || !["ahead", "identical"].includes(baseCmp.status)) {
    return { ...result, action: "refuse", reason: `배포 SHA(${short(deployed)})가 main 조상이 아님(status=${baseCmp?.status ?? "?"}) — 명시적 rollback 작업으로만` };
  }
  if (baseCmp.status === "identical") return { ...result, reason: "배포 SHA == main tip" };

  // (b) main 최신→과거로 걸으며 이미지 실존하는 첫 커밋 = 후보 (배포 SHA 도달 시 중단)
  let candidate = null;
  for (const c of q.commits(src)) {
    if (c.sha.startsWith(deployed) || deployed.startsWith(short(c.sha))) break; // 배포 지점 도달
    const m = q.manifest(repo, `sha-${c.sha}`);
    if (m?.digest) {
      candidate = { gitsha: c.sha, tag: `sha-${c.sha}`, digest: m.digest };
      break;
    }
  }
  if (!candidate) return { ...result, reason: "배포 이후 빌드된 main 커밋 없음" };

  // (c) 후보가 배포 SHA의 descendant임을 재증명 (merge 커밋 목록의 비선형성 방어)
  const candCmp = q.compare(src, deployed, candidate.gitsha);
  if (!candCmp || candCmp.status !== "ahead") {
    return { ...result, action: "refuse", reason: `후보(${short(candidate.gitsha)})가 배포 SHA의 descendant가 아님(status=${candCmp?.status ?? "?"})` };
  }
  if (candidate.digest === digest) return { ...result, reason: "동일 digest — 멱등 no-op" };

  return { ...result, action: autoDeploy ? "bump" : "propose-pr", candidate, reason: autoDeploy ? "" : "autoDeploy 아님(fail-closed) — 승인 PR만" };
}

// apps/*/deploy/prod 중 source-repo 바인딩이 있는 앱만 순회
const appsRoot = path.join(args.root, "apps");
const plans = [];
for (const name of existsSync(appsRoot) ? readdirSync(appsRoot) : []) {
  const dir = path.join(appsRoot, name, "deploy", "prod");
  if (!existsSync(path.join(dir, "source-repo"))) continue;
  try {
    plans.push(planApp(dir, name));
  } catch (e) {
    plans.push({ app: name, action: "refuse", reason: `플랜 실패: ${e.message}` });
  }
}
console.log(JSON.stringify(plans, null, 2));
