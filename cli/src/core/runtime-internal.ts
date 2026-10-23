// 쓰기 문맥 → 그 apply의 쓰기 exec. core(pr.ts 등)가 쓰기 문맥에 없는 저수준 쓰기를 할 때만 쓴다.
// WeakMap이라 문맥 객체에 보이는 필드·심볼이 없다. 명령은 이 모듈을 import할 수 없다(정적 시험).
import type { WriteCtx } from "./command";
import type { Exec } from "./exec";

const writes = new WeakMap<WriteCtx, Exec>();

export function registerWriteExec(w: WriteCtx, exec: Exec): void {
  writes.set(w, exec);
}

export function writeExecOf(w: WriteCtx): Exec {
  const exec = writes.get(w);
  if (!exec) throw new Error("쓰기 문맥이 아니다(엔진이 Step.apply에 준 문맥만 쓴다)");
  return exec;
}
