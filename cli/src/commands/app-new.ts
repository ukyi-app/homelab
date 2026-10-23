// 자리표시. T12-04가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";
import { APP_NAME } from "../core/names";

export default placeholder(
  {
    path: ["app", "new"],
    summary: "템플릿으로 public 앱 저장소 만들기(plan만, 실제 생성은 T13)",
    kind: "change",
    args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
    flags: [],
  },
  "T12-04",
);
