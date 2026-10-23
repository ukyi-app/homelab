// 자리표시. T12-02가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";
import { APP_NAME } from "../core/names";

export default placeholder(
  {
    path: ["logs"],
    summary: "로그",
    kind: "read",
    args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
    flags: [{ name: "since", kind: "value", valueName: "기간", pattern: /[1-9][0-9]*[smhd]/, help: "예 30m, 2h, 7d" }],
  },
  "T12-02",
);
