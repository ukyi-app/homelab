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
- PR은 GitHub API로 `cli/<명령>-<app>` 브랜치에 만든다(로컬 체크아웃 없음). 파일 내용은 그때의 main 스냅샷에서 다시 계산하고, 열린 PR은 머리 커밋의 `Homelab-CLI:` 트레일러와 PR 전체 변경 집합까지 본다. 갱신은 force 없이 부모 [main 스냅샷, 확인한 머리]의 fast-forward라, 확인 뒤 사람 push가 끼면 GitHub가 거부하고 CLI는 덮지 않고 멈춘다. 병합은 사람이 한다.
- 시크릿 입력(예: `secret set`의 stdin)은 16자 이상만 받는다. 생성 비밀번호는 영숫자 40자.

## 명령 더하기

등록 표 `src/registry.ts`에 C.7의 모든 명령이 이미 있다. 구현하는 사람은 자기 명령 파일 `src/commands/<이름>.ts`(와 같은 접두의 도우미 `src/commands/<이름>-*.ts`)만 바꾸고 공통부(`src/core/`, `src/registry.ts`, `test/harness.ts`, `test/stub.ts`)는 고치지 않는다. 어댑터가 모자라면 공통부 담당에게 알려 공통부에 더한다.

**구조(안전의 근거):** 명령은 외부 명령을 직접 실행할 수 없다. 받는 것은 타입 있는 어댑터뿐이고 어댑터마다 argv 모양이 고정이다.

- **import:** 명령 파일은 `../core/command`(정의·문맥 타입), `../core/names`, `../core/result`, `../core/pr`, `../core/command-info`와 자기 접두 도우미만 import한다. `Bun`·`process`·`fetch`·`require`·동적 import·`console` 같은 전역도 쓰지 않는다. 정적 시험이 막는다.
- **읽기 문맥 `ctx`(run과 `Step.read`):** `ctx.k8s`(get·list·secretHash·secretExists·logs·canI·rolloutStatus·currentContext), `ctx.infisical`(has·listKeys·getValue·valueHash·projectStatus), `ctx.gh.get`(repos/ukyi-app/…·orgs/ukyi-app/…·user만), `ctx.repo`(mainSha·readFile), `ctx.ghcr.anonymousPullStatus`, `ctx.tools`(doctor용), `ctx.github`(github 위임 명령만). 쓰기 함수는 없다.
- **쓰기 문맥 `w`(`Step.apply(w, seen)`만):** 위 읽기에 더해 `w.k8s`(forceSync·rolloutRestart·createRestoreObject·deleteRestoreObjects), `w.infisical`(setValue·removeKey), `w.generatePassword()`, `w.readSecretInput(prompt)`. 엔진이 apply 한 번마다 새로 만들고 끝나면 폐기한다. 붙잡아 두었다가 쓰면 모든 호출이 막힌다. 엔진은 한 번에 하나만 돈다(중첩·병렬 거부).
- **PR:** `prStep({ command, app, title, body, files, edit })`. `edit(현재 내용)`은 같은 키로 원하는 내용(지우려면 null)을 돌려준다. 읽을 때와 apply 때 모두 그 시점의 main 스냅샷에서 다시 부른다.
- **Secret 값:** kubectl은 `secretHash`·`secretExists`(값은 밖으로 안 나온다), Infisical 값은 `getValue`가 불투명한 Secret으로 준다(열 수 없고 `setValue`로 넘기기만 한다). 범용 kubectl 조회에는 Secret 종류가 없다.
- **github 위임:** `ctx.github.run("plan" | "verify" | "apply", { allowDestroy })`. core가 main을 임시 폴더로 fresh clone하고 그 안의 `tools/tf-github.sh`를 부르며 종료 코드를 그대로 돌려준다. 직접 stdio도 이 경로만 쓴다.
- **바꾸는 일은 `ctx.engine({ command, app, steps })`의 `Step.apply()` 안에서만.** `read()`는 이미 된 일에 `same`을 낸다. `apply()`에 재시도 루프를 두지 않는다(타임아웃은 엔진이 재조회).
- **출력:** Result의 `target`·`detail`·`notes`·`next`로만 말한다. 실패에는 `error.next`(다음 행동)가 있다. `exitCode`는 `github *`만.
- **시험:** `test/commands/<이름>.test.ts`에 `expectPlanReadOnly(...)`를 부르는 plan 시험(정적 시험이 확인), 다 된 상태에서 apply → 모든 `state: same`, 중간 쓰기 실패 → exit 1과 뒤 단계 `not-run` → 재실행으로 이어짐, 사람용·`--json` 출력에 가짜 시크릿 없음. 장치는 `test/harness.ts`(`runCli`, `testCtx`, `applyWith`, 규칙 도우미)이고 모양은 `test/core/pr.test.ts`·`engine.test.ts`·`adapters.test.ts`·`github-delegate.test.ts`를 본다. 스텁 응답 `responses`는 호출 순서대로 쓰이고, apply는 단계마다 전체 읽기·직전 읽기·(실행)·재조회 순으로 읽는다.
