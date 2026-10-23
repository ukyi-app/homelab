// 자리표시. T12-02가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";
import { APP_NAME } from "../core/names";

export default placeholder(
  {
    path: ["status"],
    summary: "빌드·배포 PR·Argo CD·DB·시크릿 준비 상태와 다음 행동",
    kind: "read",
    args: [{ name: "app", required: false, help: "앱 이름", pattern: APP_NAME }],
    flags: [{ name: "platform", kind: "bool", help: "플랫폼 구성 요소 상태" }],
  },
  "T12-02",
);
