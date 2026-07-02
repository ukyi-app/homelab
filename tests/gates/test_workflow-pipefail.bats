#!/usr/bin/env bats
# 변이 파이프라인 fail-closed 가드 — GHA run 기본 셸은 `bash -e {0}`(pipefail 없음).
# `bun 도구 | tee` 파이프의 좌변 실패가 tee exit 0에 삼켜지면 부분 변이 산출물이
# PR·auto-merge로 샐 수 있다(M1). 명시 shell: bash = `bash --noprofile --norc -eo pipefail {0}`.
# ① 변이 계열 6종은 defaults.run.shell=bash 선언 강제(신규 스텝 자동 커버),
# ② 전 워크플로: `| tee` run 스텝은 defaults/스텝 shell(bash) 또는 in-step pipefail 필수.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과 함정. yq 비사용(CI/로컬 버전차 함정) — bun+yaml 파서.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "mutation-family workflows declare defaults.run.shell bash (structural pipefail)" {
  run bun -e '
    const y = require("yaml"), fs = require("fs");
    const fleet = ["_create-app", "_create-database", "_create-cache", "_update-secrets", "_teardown-app", "audit"];
    const bad = [];
    for (const w of fleet) {
      const p = process.argv[1] + "/.github/workflows/" + w + ".yaml";
      const doc = y.parse(fs.readFileSync(p, "utf8"));
      const sh = doc?.defaults?.run?.shell ?? "";
      if (!/^bash\b/.test(sh)) bad.push(w + ".yaml: defaults.run.shell != bash");
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$ROOT"
  [ "$status" -eq 0 ]
}

@test "every workflow run step piping into tee is pipefail-covered" {
  # tee 클래스만 검사 — 일반 파이프 탐지는 jq/yq 필터 문자열 속 |와 구분 불가(오탐원)라 비대상.
  run bun -e '
    const y = require("yaml"), fs = require("fs");
    const dir = process.argv[1] + "/.github/workflows";
    const bad = [];
    for (const f of fs.readdirSync(dir)) {
      if (!/\.ya?ml$/.test(f)) continue;
      const doc = y.parse(fs.readFileSync(dir + "/" + f, "utf8"));
      const wfBash = /^bash\b/.test(doc?.defaults?.run?.shell ?? "");
      for (const [jn, job] of Object.entries(doc?.jobs ?? {})) {
        const jobBash = /^bash\b/.test(job?.defaults?.run?.shell ?? "");
        (job?.steps ?? []).forEach((st, i) => {
          if (typeof st?.run !== "string" || !/\|\s*tee\b/.test(st.run)) return;
          const stepBash = /^bash\b/.test(st?.shell ?? "");
          const inStep = /set\s+-\w*o\s+pipefail/.test(st.run);
          if (!(wfBash || jobBash || stepBash || inStep))
            bad.push(f + " jobs." + jn + ".steps[" + i + "]: tee 파이프에 pipefail 부재");
        });
      }
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$ROOT"
  [ "$status" -eq 0 ]
}
