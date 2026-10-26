// homelab github plan: tools/tf-github.sh plan을 main의 새 clone에서 돌리고 종료 코드를 그대로 낸다(설계 C.3.9·C.7, 결정 D2).
// 래퍼 plan은 -lock=false라 R2에 잠금을 쓰지 않는다(AC-P13). delete가 있으면 래퍼가 --allow-destroy 없이 멈춘다.
import { defineCommand } from "../core/command";
import type { Result } from "../core/result";

const GUARD_NEXT = "메시지의 guard 번호를 설계 C.3.9에서 찾아 고친다(docs/runbooks-public/github.md). delete로 멈췄으면 그 삭제가 맞는지 본다";

export default defineCommand({
  path: ["github", "plan"],
  summary: "GitHub 보호 설정 plan(tools/tf-github.sh plan)",
  kind: "delegate",
  delegateMode: "read",
  args: [],
  flags: [{ name: "allow-destroy", kind: "bool", help: "delete가 있어도 진행" }],
  async run(ctx, input) {
    const allowDestroy = input.flags["allow-destroy"] === true;
    const code = ctx.github!.run("plan", { allowDestroy });
    const r: Result = { command: "github plan", mode: ctx.mode, status: "same", steps: [], notes: [], next: null, exitCode: code };
    if (code === 0) return { ...r, title: "homelab github plan: exit 0 (변경 없음)" };
    // 래퍼 apply는 plan을 다시 만들어 보여 주고 yes를 받는다. 이 plan 출력과 같은지 사람이 본다.
    if (code === 2) return { ...r, status: "pending", title: "homelab github plan: exit 2 (변경 있음)", next: allowDestroy ? "homelab github apply --allow-destroy" : "homelab github apply" };
    // 128 이상은 래퍼가 신호로 끝난 것이다(셸의 $?와 같은 128+번호, core가 보존한다). guard 실패로 안내하지 않는다.
    if (code >= 128) {
      const again = `중단된 이유를 확인한 뒤 다시: homelab github plan`;
      return { ...r, status: "failed", title: `homelab github plan: exit ${code} (신호로 중단)`, next: again, error: { message: `래퍼 plan가 신호로 끝났다(exit ${code})`, next: again } };
    }
    const next = `${GUARD_NEXT}. 고친 뒤 다시: homelab github plan${allowDestroy ? " --allow-destroy" : ""}`;
    return { ...r, status: "failed", title: `homelab github plan: exit ${code} (guard 실패·오류)`, next, error: { message: `래퍼 plan이 exit ${code}로 끝났다`, next } };
  },
});
