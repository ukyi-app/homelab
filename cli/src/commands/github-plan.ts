// 자리표시. T12-04가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";

export default placeholder(
  {
    path: ["github", "plan"],
    summary: "GitHub 보호 설정 plan(tools/tf-github.sh plan)",
    kind: "delegate", delegateMode: "read",
    args: [],
    flags: [{ name: "allow-destroy", kind: "bool", help: "delete가 있어도 진행" }],
  },
  "T12-04",
);
