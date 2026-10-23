// 자리표시. T12-03가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";
import { APP_NAME } from "../core/names";

export default placeholder(
  {
    path: ["db", "restore"],
    summary: "앱 하나의 PostgreSQL 복원(C.5.7)",
    kind: "change",
    args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
    flags: [{ name: "to", kind: "value", valueName: "시각", help: "복원 시각" }],
  },
  "T12-03",
);
