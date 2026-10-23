// 자리표시. T12-02가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";
import { APP_NAME, SECRET_KEY } from "../core/names";

export default placeholder(
  {
    path: ["secret", "set"],
    summary: "앱 시크릿 등록(값은 stdin)",
    kind: "change",
    args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }, { name: "KEY", required: true, help: "키 이름", pattern: SECRET_KEY }],
    flags: [{ name: "replace", kind: "bool", help: "이미 있는 키를 바꾼다" }],
  },
  "T12-02",
);
