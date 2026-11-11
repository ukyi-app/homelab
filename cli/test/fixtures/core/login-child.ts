// exec.test.ts의 하위 프로세스. 가짜 터미널로 claude setup-token 로그인(PATH의 스텁)을 띄워 화면을 거른 뒤 결과 문서 한 줄을 stdout에 낸다.
// 부모가 이 프로세스의 stdout에 결과 문서만 있고 stderr 화면에 토큰이 없는지 본다(`homelab bot account add --apply --json >파일`과 같은 꼴).
import { makeTerminalLogin } from "../../../src/core/exec";
import { setupTokenLogin } from "../../../src/core/input";
import { writeStderr, writeStdout } from "../../../src/core/output";

const login = makeTerminalLogin({ env: { ...process.env }, live: () => true });
const token = await setupTokenLogin(login, "대화용·작업용", () => {}, writeStderr);
writeStdout(`${JSON.stringify({ schema: "homelab-cli/v1", status: "done", got: token !== null })}\n`);
