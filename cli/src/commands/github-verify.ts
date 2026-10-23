// 자리표시. T12-04가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";

export default placeholder(
  {
    path: ["github", "verify"],
    summary: "GitHub 보호 설정 대조(tools/tf-github.sh verify)",
    kind: "delegate", delegateMode: "read",
    args: [],
    flags: [],
  },
  "T12-04",
);
