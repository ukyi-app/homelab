// 명령 결과와 종료 코드(PLAN D2, lead 결정 2026-10-23).
// plan에 차이가 있어도 0이다(plan 자체는 성공). 3은 apply 뒤 바깥 대기(PR 병합·동기화)에만 쓴다.

export type State = "missing" | "differs" | "same";
export type Action = "create" | "update" | "delete" | "none";
export type StepResult = "planned" | "skipped" | "applied" | "waiting" | "failed" | "not-run";
export type Status = "same" | "pending" | "done" | "waiting" | "failed" | "usage";
export type Mode = "plan" | "apply" | "read";

export type StepReport = {
  id: string;
  state: State;
  action: Action;
  target: string;
  detail: string;
  result: StepResult;
};

export type Result = {
  command: string;
  app?: string;
  mode: Mode;
  status: Status;
  steps: StepReport[];
  notes: string[];
  next: string | null;
  // failed·usage에서 필수. next는 사람이 바로 할 일.
  error?: { message: string; next: string };
  // 사람용 출력의 머리. 없으면 모드에 맞는 기본 머리.
  title?: string;
  // github 하위 명령(kind delegate)만 쓴다. 래퍼 코드 그대로(0 같음, 2 차이, 1 guard·실패).
  exitCode?: number;
};

export const EXIT: Record<Status, number> = { same: 0, pending: 0, done: 0, waiting: 3, failed: 1, usage: 64 };

// 사용법 오류. main이 64로 바꾼다.
export class UsageError extends Error {}

// 원인과 다음 행동을 함께 가진 실패. main이 failed 결과로 바꾼다.
export class CliError extends Error {
  constructor(
    message: string,
    readonly next: string,
  ) {
    super(message);
  }
}

export function failed(command: string, mode: Mode, message: string, next: string, app?: string): Result {
  return { command, app, mode, status: "failed", steps: [], notes: [], next, error: { message, next } };
}
