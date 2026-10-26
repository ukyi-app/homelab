// homelab github verify: tools/tf-github.sh verify를 main의 새 clone에서 돌리고 종료 코드를 그대로 낸다(설계 C.3.9·C.7, 결정 D2).
// AC-5: 이 명령의 종료 코드 = 래퍼 verify의 종료 코드. CLI가 코드를 해석해 바꾸지 않는다(사람용 머리와 status만 정한다).
import { defineCommand } from "../core/command";
import type { Result } from "../core/result";

const GUARD_NEXT = "메시지의 guard 번호를 설계 C.3.9에서 찾아 고친다(docs/runbooks-public/github.md)";

export default defineCommand({
  path: ["github", "verify"],
  summary: "GitHub 보호 설정 대조(tools/tf-github.sh verify)",
  kind: "delegate",
  delegateMode: "read",
  args: [],
  flags: [],
  async run(ctx) {
    const code = ctx.github!.run("verify");
    const r: Result = { command: "github verify", mode: ctx.mode, status: "same", steps: [], notes: [], next: null, exitCode: code };
    if (code === 0) return { ...r, title: "homelab github verify: exit 0 (선언과 같음)" };
    if (code === 2) return { ...r, status: "pending", title: "homelab github verify: exit 2 (선언과 다름)", next: "homelab github plan" };
    // 128 이상은 래퍼가 신호로 끝난 것이다(셸의 $?와 같은 128+번호, core가 보존한다). guard 실패로 안내하지 않는다.
    if (code >= 128) {
      const again = `중단된 이유를 확인한 뒤 다시: homelab github verify`;
      return { ...r, status: "failed", title: `homelab github verify: exit ${code} (신호로 중단)`, next: again, error: { message: `래퍼 verify가 신호로 끝났다(exit ${code})`, next: again } };
    }
    const next = `${GUARD_NEXT}. 고친 뒤 다시: homelab github verify`;
    return { ...r, status: "failed", title: `homelab github verify: exit ${code} (guard 실패·오류)`, next, error: { message: `래퍼 verify가 exit ${code}로 끝났다`, next } };
  },
});
