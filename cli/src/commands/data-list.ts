// 자리표시. T12-02가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";

export default placeholder(
  {
    path: ["data", "list"],
    summary: "주인 없는 보존 데이터",
    kind: "read",
    args: [],
    flags: [],
  },
  "T12-02",
);
