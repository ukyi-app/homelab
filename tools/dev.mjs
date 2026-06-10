#!/usr/bin/env node
import { execSync, spawn } from "node:child_process";

console.log("starting local dev Postgres (OrbStack docker)…");
execSync("docker compose -f tools/dev-postgres/compose.yaml up -d --wait", { stdio: "inherit" });
console.log("dev Postgres ready on localhost:5432 (db=app_dev user=dev).");

// run TS workspace apps in parallel; polyglot apps run their own native dev loop.
const p = spawn("pnpm", ["-r", "--parallel", "--if-present", "dev"], { stdio: "inherit" });
process.on("SIGINT", () => { p.kill("SIGINT"); });
