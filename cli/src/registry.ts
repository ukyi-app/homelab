// 명령 등록 표. C.7의 모든 명령을 01이 미리 적었다. 02~04는 이 파일을 고치지 않고 자기 명령 파일만 바꾼다.
// 정적 import만 쓴다(bun build --compile 실행 파일은 실행 때 파일을 찾지 못한다).
import type { CommandSpec } from "./core/command";
import doctor from "./commands/doctor";
import appNew from "./commands/app-new";
import appAdd from "./commands/app-add";
import appRemove from "./commands/app-remove";
import dbAdd from "./commands/db-add";
import cacheAdd from "./commands/cache-add";
import secretSet from "./commands/secret-set";
import secretSync from "./commands/secret-sync";
import status from "./commands/status";
import logs from "./commands/logs";
import rollback from "./commands/rollback";
import rotateDb from "./commands/rotate-db";
import rotateCache from "./commands/rotate-cache";
import restoreDb from "./commands/restore-db";
import restoreCheck from "./commands/restore-check";
import restoreCache from "./commands/restore-cache";
import dataList from "./commands/data-list";
import purge from "./commands/purge";
import githubPlan from "./commands/github-plan";
import githubApply from "./commands/github-apply";
import githubVerify from "./commands/github-verify";

export const REGISTRY: CommandSpec[] = [
  doctor,
  appNew,
  appAdd,
  appRemove,
  dbAdd,
  cacheAdd,
  secretSet,
  secretSync,
  status,
  logs,
  rollback,
  rotateDb,
  rotateCache,
  restoreDb,
  restoreCheck,
  restoreCache,
  dataList,
  purge,
  githubPlan,
  githubApply,
  githubVerify,
];
