#!/usr/bin/env node
import { execSync, spawn } from "node:child_process";

console.log("starting local dev Postgres (OrbStack docker)…");
execSync("docker compose -f tools/dev-postgres/compose.yaml up -d --wait", { stdio: "inherit" });
console.log("dev Postgres ready on localhost:5432 (db=app_dev user=dev).");

// TS 워크스페이스 앱들을 병렬 실행; 폴리글랏 앱은 자기 네이티브 dev 루프를 돈다.
const p = spawn("pnpm", ["-r", "--parallel", "--if-present", "dev"], { stdio: "inherit" });
process.on("SIGINT", () => { p.kill("SIGINT"); });
