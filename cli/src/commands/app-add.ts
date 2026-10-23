// 자리표시. T12-02가 이 파일을 통째로 바꾼다(cli/README.md "명령 더하기").
import { placeholder } from "../core/command";
import { APP_NAME, PUBLIC_HOST, INTERNAL_NAME } from "../core/names";

export default placeholder(
  {
    path: ["app", "add"],
    summary: "최초 등록(앱 values·image.yaml, 필요하면 DB·캐시) PR",
    kind: "change",
    args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
    flags: [{ name: "public", kind: "value", valueName: "host", pattern: PUBLIC_HOST, help: "공개 host(<이름>.ukyi.app)" }, { name: "internal", kind: "value", valueName: "name", pattern: INTERNAL_NAME, help: "tailnet 안 이름" }, { name: "postgres", kind: "bool", help: "PostgreSQL 연결" }, { name: "cache", kind: "optional-value", values: ["persistent"], help: "Valkey 연결(=persistent면 영속)" }],
  },
  "T12-02",
);
