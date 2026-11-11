// exec.test.ts의 하위 프로세스. 쓰기 exec로 claude setup-token 로그인(PATH의 스텁)을 띄운 뒤 결과 문서 한 줄을 stdout에 낸다.
// 부모가 이 프로세스의 stdout에 결과 문서만 있는지 본다(`homelab bot account add --apply --json >파일`과 같은 꼴).
import { makeExec } from "../../../src/core/exec";
import { setupTokenLogin } from "../../../src/core/input";

const exec = makeExec("write", { env: { ...process.env }, live: () => true });
setupTokenLogin(exec, "대화·리뷰", () => {});
process.stdout.write(`${JSON.stringify({ schema: "homelab-cli/v1", status: "done" })}\n`);
