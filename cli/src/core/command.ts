// 명령 정의의 모양. 명령 파일 하나가 defineCommand 하나를 default로 내보내고 registry.ts가 정적 import한다.
// (bun build --compile 실행 파일은 실행 때 파일을 찾지 못하므로 정적 import만 쓴다.)
import type { ArgSpec, FlagSpec, Input } from "./args";
import type { Exec } from "./exec";
import type { Mode, Result, State, Action, Status } from "./result";

// change: 기본 plan, --apply로 실행. read: 상태를 안 바꾼다(--apply는 64). delegate: github 래퍼, 종료 코드 위임.
export type Kind = "change" | "read" | "delegate";

export type Observation = {
  state: State;
  action: Action;
  // 사람용 설명("없음 → 생성"). 값은 넣지 않는다(출력 계층이 다시 막는다).
  detail: string;
  // same이어도 바깥을 기다리면(예 "PR #12 병합 대기") apply 결과가 waiting(3)이 된다.
  wait?: string;
  // 이 단계가 막혔을 때 사람이 할 일.
  next?: string;
};

export type Step = {
  id: string;
  target: string;
  // 읽기만 한다. 쓰기 부명령을 부르면 exec가 막는다(plan·read 모드).
  read(ctx: Ctx): Promise<Observation>;
  // 없으면 확인 단계: same이 아니면 명령이 실패한다(apply에서는 아무것도 쓰기 전에).
  apply?(ctx: Ctx, seen: Observation): Promise<void>;
};

export type Plan = {
  command: string;
  app?: string;
  steps: Step[];
  notes?: string[];
  title?: string;
  // 없으면 엔진의 기본 다음 행동(pending이면 같은 명령에 --apply).
  next?: (status: Status) => string | null;
};

export type Ctx = {
  mode: Mode;
  json: boolean;
  // 사람이 친 명령줄(--json 뺌). 다음 행동 문구에 쓴다.
  line: string;
  exec: Exec;
  env: Record<string, string | undefined>;
  isTTY: boolean;
  engine(plan: Plan): Promise<Result>;
  // 진행 줄. stderr로 간다(stdout은 결과 하나만).
  progress(line: string): void;
  // tty에서 한 줄 묻는다. 값은 화면에 보인다(시크릿용이 아니다).
  ask(question: string): string | null;
};

export type CommandSpec = {
  path: string[];
  summary: string;
  kind: Kind;
  // delegate만: 래퍼가 상태를 바꾸는지(github apply). exec의 쓰기 차단이 이 값을 본다.
  delegateMode?: "read" | "apply";
  args: ArgSpec[];
  flags: FlagSpec[];
  // 자리표시(아직 구현 전) 명령이면 담당 티켓. 구현하면 지운다.
  placeholder?: string;
  run(ctx: Ctx, input: Input): Promise<Result>;
};

export function defineCommand(spec: CommandSpec): CommandSpec {
  return spec;
}

// 자리표시. 담당 티켓이 이 파일을 통째로 바꾼다.
export function placeholder(spec: Omit<CommandSpec, "run" | "placeholder">, ticket: string): CommandSpec {
  return {
    ...spec,
    placeholder: ticket,
    async run(ctx) {
      const command = spec.path.join(" ");
      return {
        command,
        mode: ctx.mode,
        status: "failed",
        steps: [],
        notes: [],
        next: null,
        error: { message: `homelab ${command}은 아직 구현 전이다(${ticket})`, next: "homelab doctor" },
      };
    },
  };
}
