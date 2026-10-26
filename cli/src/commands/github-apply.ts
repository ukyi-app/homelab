// homelab github apply: tools/tf-github.sh apply를 main의 새 clone에서 돌리고 종료 코드를 그대로 낸다(설계 C.3.9·C.7, 결정 D2).
// 래퍼가 묻는 값(HOMELAB_ADMIN_PROJECT_ID, R2_ENDPOINT, TF_STATE_BACKUP_DIR)과 마지막 yes는 사람이 직접 답한다(CLI가 대신 답하지 않는다).
// 래퍼 apply는 끝에 verify를 다시 돈다. 그래서 0은 "적용 뒤 선언과 같음"이고 2는 적용 뒤에도 차이가 남은 것이다.
import { defineCommand } from "../core/command";
import type { Result } from "../core/result";

export default defineCommand({
  path: ["github", "apply"],
  summary: "GitHub 보호 설정 apply(tools/tf-github.sh apply)",
  kind: "delegate",
  delegateMode: "apply",
  args: [],
  flags: [{ name: "allow-destroy", kind: "bool", help: "delete가 있어도 진행" }],
  async run(ctx, input) {
    const code = ctx.github!.run("apply", { allowDestroy: input.flags["allow-destroy"] === true });
    const r: Result = { command: "github apply", mode: ctx.mode, status: "done", steps: [], notes: [], next: null, exitCode: code };
    if (code === 0) return { ...r, title: "homelab github apply: exit 0 (적용 뒤 선언과 같음, 또는 변경 없음)" };
    // 128 이상은 래퍼가 신호로 끝난 것이다(셸의 $?와 같은 128+번호, core가 보존한다). guard 실패로 안내하지 않는다.
    if (code >= 128) {
      const again = "apply 도중 멈췄을 수 있다. homelab github plan으로 state를 보고, 래퍼가 남긴 state 백업과 런북 github.md 3절을 따른다";
      return { ...r, status: "failed", title: `homelab github apply: exit ${code} (신호로 중단)`, next: again, error: { message: `래퍼 apply가 신호로 끝났다(exit ${code})`, next: again } };
    }
    const next =
      code === 2
        ? "적용 뒤 verify에 차이가 남았다. homelab github plan으로 보고, 미뤄진 guard·콘솔 변경을 확인한다"
        : "래퍼 메시지를 본다. apply 실패면 래퍼가 남긴 state 백업과 재import 안내를 따른다(docs/runbooks-public/github.md 3절)";
    return { ...r, status: "failed", title: `homelab github apply: exit ${code}`, next, error: { message: `래퍼 apply가 exit ${code}로 끝났다`, next } };
  },
});
