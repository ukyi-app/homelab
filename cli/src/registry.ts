// 명령 등록 표. C.7의 모든 명령을 적는다.
// 정적 import만 쓴다(bun build --compile 실행 파일은 실행 때 파일을 찾지 못한다).
// 분류(SECTIONS)가 맨 위 도움말(homelab -h)의 묶음과 순서다. 새 명령은 import 한 줄과 알맞은 분류에 한 줄을 더한다.
// 분류에 빠진 명령은 시험(help.test.ts)이 잡는다.
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
import bot from "./commands/bot";
import botAccountAdd from "./commands/bot-account-add";
import botAccountUse from "./commands/bot-account-use";
import botAccountList from "./commands/bot-account-list";

export type Section = { title: string; commands: CommandSpec[] };

// 묶는 기준은 사람이 무엇을 하려는가다(경로 첫 단어가 아니다): db·cache 명령도 붙이기는 데이터, 비밀번호 바꾸기는
// 시크릿, 되돌리기는 복원으로 간다. 복원은 장애 때 바로 찾게 따로 둔다.
export const SECTIONS: Section[] = [
  { title: "점검·살펴보기", commands: [doctor, status, logs] },
  { title: "앱", commands: [appNew, appAdd, appRemove, rollback] },
  { title: "데이터", commands: [dbAdd, cacheAdd, dataList, purge] },
  { title: "시크릿·비밀번호", commands: [secretSet, secretSync, rotateDb, rotateCache] },
  { title: "복원", commands: [restoreDb, restoreCheck, restoreCache] },
  { title: "GitHub 설정", commands: [githubPlan, githubVerify, githubApply] },
  { title: "봇", commands: [bot, botAccountAdd, botAccountUse, botAccountList] },
];

export const REGISTRY: CommandSpec[] = SECTIONS.flatMap((s) => s.commands);
