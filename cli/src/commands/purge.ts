// 자리표시. T12-03가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";
import { APP_NAME } from "../core/names";

export default placeholder(
  {
    path: ["data", "purge"],
    summary: "데이터 폐기(C.5.5). --apply와 --confirm <app> 둘 다 있어야 실행",
    kind: "change",
    args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
    flags: [{ name: "confirm", kind: "value", valueName: "app", pattern: APP_NAME, help: "지울 앱 이름을 한 번 더" }],
  },
  "T12-03",
);
