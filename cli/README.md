# homelab CLI

설계 C.7의 `homelab` 명령. `gh`·`git`·`infisical`·`kubectl`을 부르는 얇은 도구이고 자체 상태 저장소가 없다. 사람의 `gh` 로그인, `infisical login`, kubeconfig를 쓰고 자격을 저장하지 않는다.

## 설치·버전·되돌리기

검토한 main에서 빌드한다.

```bash
mise install
bun cli/build.ts --install        # ~/.local/bin/homelab, 이전 파일은 ~/.local/bin/homelab.prev
homelab --version                 # homelab 0.1.0 (<git SHA 12자>)
homelab doctor                    # 도구·로그인·kubectl context
```

- 커밋 안 된 변경이 있으면 설치를 거부한다(`--allow-dirty`로만). 버전 끝의 `-dirty`가 그 표시다.
- 되돌리기: `mv ~/.local/bin/homelab.prev ~/.local/bin/homelab`. 이전 파일은 하나만 남는다.
- `bun link`는 쓰지 않는다(설계 B.8 E7). 바이너리는 커밋하지 않는다(`cli/dist/`는 무시).
- 개발 실행: `bun run cli -- doctor`. 시험: `bun test cli/`(필수 검사 `bun run ci`의 `cli` 단계가 같은 것을 돈다).
- Infisical을 쓰는 명령은 `HOMELAB_INFISICAL_PROJECT_ID`(homelab 프로젝트 ID)를 읽는다. 없으면 tty에서 한 번 묻는다. 값은 저장소에 두지 않는다.

## 동작 규칙

- 바꾸는 명령은 기본이 plan(아무것도 바꾸지 않음)이고 `--apply`로 실행한다. 읽기 명령에 `--apply`를 주면 사용법 오류다.
- 종료 코드: 0 완료·변경 없음·plan, 1 실패(원인과 다음 행동), 3 대기(apply 뒤 PR 병합·동기화), 64 사용법 오류. `github` 하위 명령은 `tools/tf-github.sh` 코드 그대로(0 같음, 2 차이, 1 guard·실패).
- 중복·모르는 플래그는 거부한다. 값에 줄바꿈·제어 문자가 있으면 거부하고 값 전체를 형식과 맞춘다.
- 재실행 안전: 단계마다 실행 직전에 현재 상태를 읽고 된 단계는 건너뛴다. 타임아웃은 재시도하지 않고 다시 읽는다.
- `--json`은 `schema: homelab-cli/v1` 문서 하나를 stdout에 낸다. 진행 줄은 stderr.
- PR은 GitHub API로 `cli/<명령>-<app>` 브랜치에 만든다(로컬 체크아웃 없음). 커밋 부모는 최신 main이고 브랜치는 force로 옮긴다. 브랜치 머리 커밋에 `Homelab-CLI:` 트레일러가 없으면(사람 커밋) 멈춘다. 병합은 사람이 한다.

## 명령 더하기

등록 표 `src/registry.ts`에 C.7의 모든 명령이 이미 있다. 구현하는 사람은 자기 명령 파일 `src/commands/<이름>.ts`만 통째로 바꾸고 공통부(`src/core/`, `src/registry.ts`, `test/harness.ts`, `test/stub.ts`)는 고치지 않는다. 공통부가 모자라면(새 읽기 꼴, 어댑터 함수, 스텁 기능) 공통부 담당에게 알려 따로 바꾼다.

- **모양:** `defineCommand({ path, summary, kind, args, flags, run })`. `kind`는 `change`(plan/`--apply`), `read`, `delegate`(`github *`만).
- **바꾸는 일은 `ctx.engine({ command, app, steps })`의 `Step.apply()` 안에서만.** `read()`와 단계 목록을 만드는 코드는 읽기만 한다. `read()`는 이미 된 일에 `same`을 낸다. `apply()`에 재시도 루프를 두지 않는다.
- **외부 호출은 `ctx.exec` 또는 `src/core/` 어댑터로만.** `fetch`·`Bun.spawn`·`Bun.$`·`child_process`·`console`·`process.stdout`·파일 쓰기는 정적 시험이 막는다. plan·read 모드의 쓰기 호출은 exec가 실행하지 않는다(`src/core/writes.ts`의 읽기 허용 목록 밖은 모두 쓰기).
- **시크릿:** 값은 `Secret`으로만 들고 stdin으로만 넘긴다(argv·파일·출력·PR 내용 금지). 같은지는 `sha256Prefix()`. 비밀번호는 `generatePassword()`를 `apply()` 안에서만. Infisical 쓰기는 `infisical.setValue()`만.
- **출력:** Result의 `target`·`detail`·`notes`·`next`로만 말한다. 실패에는 `error.next`(다음 행동)가 있다. `exitCode`는 `github *`만.
- **시험:** `test/commands/<이름>.test.ts`에 `expectPlanReadOnly(...)`를 부르는 plan 시험(정적 시험이 확인), 다 된 상태에서 apply → 모든 `state: same`, 중간 쓰기 실패 → exit 1과 뒤 단계 `not-run` → 재실행으로 이어짐, 사람용·`--json` 출력에 가짜 시크릿 없음. 장치는 `test/harness.ts`(`runCli`·`testCtx`·규칙 도우미)이고 모양은 `test/core/pr.test.ts`·`test/core/engine.test.ts`를 본다. 스텁 응답 `responses`는 호출 순서대로 쓰이고, apply는 단계마다 전체 읽기·직전 읽기·(실행)·재조회 순으로 읽는다.
