// bun test preload(루트 bunfig.toml). 시험마다 시크릿 추적 목록을 비워 시험 사이 전역 상태가 새지 않게 한다.
// 함정: 추적 목록이 프로세스 전역이라 실행 순서(--randomize, CI의 파일 순서)에 따라 앞 시험의 값이 뒤 시험을 깼다.
import { beforeEach } from "bun:test";
import { resetBackupGuardForTests } from "../src/core/infisical-backup";
import { resetTrackedForTests } from "../src/core/secret";

beforeEach(() => {
  resetTrackedForTests();
  resetBackupGuardForTests();
});
