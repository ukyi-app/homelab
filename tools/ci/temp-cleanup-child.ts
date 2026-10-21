// ci 단계 "temp cleanup"이 부르는 자식 프로세스. tempDir로 폴더 둘을 만들고 인수대로 끝난다.
// 부모가 TMPDIR을 빈 폴더로 주고, 끝난 뒤 그 폴더가 비었는지 본다(lib.ts의 종료 정리).
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { tempDir } from "./lib";

const a = tempDir("cleanup-a");
tempDir("cleanup-b");
writeFileSync(join(a, "f"), "x");
console.log("made 2");

const mode = process.argv[2];
if (mode === "exit") process.exit(3);
if (mode === "throw") throw new Error("시험 예외");
if (mode === "reject") await Promise.reject(new Error("시험 reject"));
if (mode === "sigterm") {
  process.kill(process.pid, "SIGTERM");
  await Bun.sleep(5000);
  console.log("신호 뒤에도 살아 있다");
}
