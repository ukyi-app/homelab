// 자리표시. T12-03가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";

export default placeholder(
  {
    path: ["db", "restore-check"],
    summary: "최신 백업 복원 시험",
    kind: "change",
    args: [],
    flags: [],
  },
  "T12-03",
);
