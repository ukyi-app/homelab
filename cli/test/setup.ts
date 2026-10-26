// bun test preload(루트 bunfig.toml). 시험마다 시크릿 추적 목록을 비워 시험 사이 전역 상태가 새지 않게 한다.
// 함정: 추적 목록이 프로세스 전역이라 실행 순서(--randomize, CI의 파일 순서)에 따라 앞 시험의 값이 뒤 시험을 깼다.
// 끝에는 이 실행의 시험 장치 뿌리와 core tempDir 폴더를 지운다(bun 1.4.3 실측: preload의 afterAll은 모든 파일 뒤 한 번,
// 같은 프로세스에서 돈다). 함정: core는 process.on("exit")로 지우는데 bun test에서는 그 훅이 돌지 않아, 같은 프로세스에서
// GitHub 어댑터를 부른 시험의 homelab-cli-github-*·plan-*가 성공해도 남았다(#887 리뷰 P2). --bail은 cli/test/run.ts가 맡는다.
import { afterAll, beforeEach } from "bun:test";
import { resetBackupGuardForTests } from "../src/core/infisical-backup";
import { resetTrackedForTests } from "../src/core/secret";
import { removeTempDirs } from "../src/core/temp";
import { removeTestRoot } from "./harness";

beforeEach(() => {
  resetTrackedForTests();
  resetBackupGuardForTests();
});

afterAll(() => {
  removeTestRoot();
  removeTempDirs();
});
