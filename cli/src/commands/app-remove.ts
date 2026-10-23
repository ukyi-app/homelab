// 자리표시. T12-02가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";
import { APP_NAME } from "../core/names";

export default placeholder(
  {
    path: ["app", "remove"],
    summary: "앱 삭제(데이터 보존) PR",
    kind: "change",
    args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
    flags: [],
  },
  "T12-02",
);
