// cli 시험 실행 감싸개: `bun cli/test/run.ts [bun test 인자...]`. 이 실행 전용 TMPDIR을 만들어 bun test를 돌리고,
// 어떻게 끝나든 그 폴더째 지운다. 필수 검사 `ci`의 cli 단계와 `bun run test:cli`가 이것을 부른다.
// 함정(bun 1.4.3 실측): `bun test --bail`은 첫 실패 뒤 preload의 afterAll·exit 훅 없이 끝나 장치 뿌리와
// core 임시 폴더(homelab-cli-github-* 등)가 남는다(#887 리뷰 P2). 그래서 정리를 시험 프로세스 밖, 이 부모에 둔다.
// 남의 폴더는 보지 않는다. 지우는 것은 여기서 만든 폴더 하나다.
import { mkdtempSync } from "node:fs";
import { constants, tmpdir } from "node:os";
import { join } from "node:path";
import { removeTree } from "./remove-tree";

const own = mkdtempSync(join(tmpdir(), "homelab-cli-test-tmp-"));
const child = Bun.spawn([process.execPath, "test", ...process.argv.slice(2)], {
  env: { ...process.env, TMPDIR: own },
  stdio: ["inherit", "inherit", "inherit"],
});
// 신호를 받으면 자식에게 넘기고 자식이 끝나길 기다린 뒤 지운다(처리기를 달면 기본 종료가 사라진다).
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(sig, () => child.kill(sig));
try {
  await child.exited;
} finally {
  removeTree(own);
}
const sig = child.signalCode ? constants.signals[child.signalCode as keyof typeof constants.signals] : undefined;
process.exit(sig ? 128 + sig : (child.exitCode ?? 1));
