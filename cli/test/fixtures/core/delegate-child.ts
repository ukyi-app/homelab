// exec.test.ts의 하위 프로세스. github 위임 쓰기 exec로 래퍼 스텁을 stdout-to-stderr로 부른다.
// 부모가 준 stdin이 래퍼까지 가는지, stdout에는 이 프로세스가 쓴 한 줄만 남는지 본다.
import { makeExec } from "../../../src/core/exec";

const exec = makeExec("write", { env: process.env, delegate: true, live: () => true });
const r = exec(["tf-github.sh", "apply"], { stdio: "stdout-to-stderr" });
process.stdout.write(JSON.stringify({ code: r.code }) + "\n");
