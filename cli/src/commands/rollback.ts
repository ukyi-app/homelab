// 자리표시. T12-02가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";
import { APP_NAME } from "../core/names";

export default placeholder(
  {
    path: ["rollback"],
    summary: "이미지 롤백·해제 PR",
    kind: "change",
    args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
    flags: [{ name: "to", kind: "value", valueName: "rev|digest", help: "되돌릴 revision 또는 digest" }, { name: "release", kind: "bool", help: "롤백 고정을 푼다" }],
  },
  "T12-02",
);
