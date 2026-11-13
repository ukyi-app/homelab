# homelab CLI

설계 C.7의 `homelab` 명령. `gh`·`git`·`infisical`·`kubectl`을 부르는 얇은 도구이고 자체 상태 저장소가 없다. 사람의 `gh` 로그인, `infisical login`, kubeconfig를 쓰고 자격을 저장하지 않는다.

## 설치·버전·되돌리기

검토한 main에서 빌드한다.

```bash
mise install
bun install --frozen-lockfile --ignore-scripts   # npm 패키지(@clack/prompts 등)를 bun.lock 해시대로
bun cli/build.ts --install        # ~/.local/bin/homelab, 이전 파일은 ~/.local/bin/homelab.prev
homelab --version                 # homelab 0.1.0 (<git SHA 12자>)
homelab doctor                    # 도구·로그인·kubectl context
```

- 커밋 안 된 변경이 있으면 설치를 거부한다(`--allow-dirty`로만). 버전 끝의 `-dirty`가 그 표시다.
- `bun cli/build.ts`는 npm 패키지를 받지 않는다(네트워크 없이 빌드한다). `node_modules`에 실행 의존성이 없거나 `package.json`과 버전이 다르면 빌드 전에 멈추고 위 `bun install` 줄을 안내한다. `bun.lock`이 바뀐 main을 받은 뒤에도 그 줄을 다시 돌린다.
- 되돌리기: `mv ~/.local/bin/homelab.prev ~/.local/bin/homelab`. 이전 파일은 하나만 남는다.
- `bun link`는 쓰지 않는다(설계 B.8 E7). 바이너리는 커밋하지 않는다(`cli/dist/`는 무시).
- 옛 `bun link`(`~/.bun/bin/homelab`)가 PATH 앞에 남아 있으면 새 바이너리를 가린다. `homelab doctor`가 "PATH의 homelab" 주의로 알린다. 지우거나(`rm ~/.bun/bin/homelab`) PATH 순서를 고친다.
- `homelab doctor`는 저장소 안에서 돌린다. 저장소 밖에서는 mise가 `.tool-versions`를 못 찾아 `infisical`·`kubectl` 버전을 고르지 못할 수 있고, 그러면 로그인돼 있어도 "로그인 안 됨"으로 보인다.
- 개발 실행: `bun run cli -- doctor`(실행 전에 `bun cli/build.ts --check-deps`로 같은 확인을 한다). 시험: `bun run test:cli`(= `bun cli/test/run.ts cli/`, 필수 검사 `bun run ci`의 `cli` 단계가 같은 것을 돈다). 파일을 골라 돌릴 때는 `bun cli/test/run.ts --bail cli/test/core/static.test.ts`처럼 bun test 인자를 그대로 넘긴다. 감싸개가 전용 TMPDIR로 돌리고 끝나면 지운다. `bun test`를 바로 부르면 `--bail` 실패나 신호 종료 때 `/tmp`에 임시 폴더가 남는다.
- 타입 검사: `bun run ci --only "cli typecheck"`(strict `tsc`, `cli/tsconfig.json`). 이 단계와 `cli` 시험·`deploy-merge merge` 단계를 고르면 `bun run ci`가 그보다 먼저 `npm deps` 단계(`bun install --frozen-lockfile --ignore-scripts`)를 한 번 돌려 `typescript`·`@types/bun`과 실행 의존성 `@clack/prompts`(정확한 버전, `bun cli/build.ts`가 실행 파일에 묶어 설치 뒤에는 받지 않는다)를 받는다. 버전을 바꾸면 `bun install`로 `bun.lock`을 같은 커밋에서 갱신한다. `@types/bun`은 `.tool-versions`의 bun과 같은 버전이다.
- Infisical을 쓰는 명령은 `HOMELAB_INFISICAL_PROJECT_ID`(homelab 프로젝트 ID)를 읽는다. 없으면 tty에서 한 실행에 한 번만 묻는다(답이 틀려도 다시 묻지 않는다). CLI는 값을 저장하지 않으므로 매번 묻지 않게 하려면 셸 설정에 `export HOMELAB_INFISICAL_PROJECT_ID=<ID>`를 둔다. 값은 저장소에 두지 않는다.
- `infisical`이 로그인 만료·인증 거부로 실패하면 다음 행동이 `infisical login`이다. 정해진 문구(`[infisical login]`, `status-code=401`, `Unauthorized`)에 맞았는지만 보고 오류 원문은 계속 버린다.
- `infisical`을 부를 때마다 `~/.infisical/secrets-backup/`을 0500으로 잠그고(남은 파일은 지운다) 호출 뒤 파일이 0개인지 본다. 권한이 듣지 않는 파일시스템(또는 root)이면 실행하지 않고 멈춘다. 잠긴 폴더를 다시 열지 않고(남은 파일은 폴더째 바꾼다), `.`·`..`가 든 HOME은 거부한다. CLI 0.44.2가 조회 값을 그 폴더에 남기기 때문이다(`tools/tf-github.sh`와 같은 방식).

## 동작 규칙

- 명령 목록은 `homelab -h`(= `homelab --help`, `homelab help`)다. 분류별로 이름과 한 줄 설명만 보인다. 묶음(`homelab app -h`, `homelab bot account -h`)은 그 아래 명령을, 명령(`homelab <명령> -h`, `homelab help <명령>`)은 설명·사용법·인자·플래그·예·관련 명령을 보인다. `homelab bot -h`는 동작 목록(대상 포함)과 `bot account` 하위 명령도 보인다. 도움말을 청하면 0이다. 인자 없는 `homelab`, 묶음만(`homelab app`), 필수 인자가 있는 명령의 이름만(`homelab bot`, `homelab app add`) 치면 같은 도움말을 stdout에 보이고 64(사용법 오류)로 끝난다. 명령을 빠뜨린 스크립트가 성공으로 끝나지 않게 지금 코드를 유지했다. 이때 `--json`이면 도움말 대신 지금의 사용법 결과 문서(`status: usage`)다.
- 도움말은 결과가 터미널로 갈 때만 색·굵기를 넣고 터미널 폭(100칸까지)에 맞춰 접는다. 파이프·파일은 80칸 글자만, `NO_COLOR`(값이 있으면)·`TERM=dumb`면 색이 없다. `-h --json`은 도움말을 `schema: homelab-cli-help/v1` 문서로 낸다(분류·명령·인자·플래그·동작·예. 결과 문서 `homelab-cli/v1`과 다른 schema다).
- 모르는 명령이면 가까운 등록 이름 하나를 `혹시: homelab …`로 권한다(친 말은 되찍지 않는다). 사람용 사용법 오류는 짧은 사용법과 `자세히: homelab <명령> -h`를 보인다. `--json` 사용법 오류 문서의 `next`는 지금처럼 전체 사용법 한 줄이다.
- 바꾸는 명령은 기본이 plan(아무것도 바꾸지 않음)이고 `--apply`로 실행한다. 읽기 명령에 `--apply`를 주면 사용법 오류다.
- `homelab bot`(봇 관리 기능)은 봇 게시 서버 파드 안의 관리 진입점을 `kubectl exec`로 부른다. exec는 쓰기로 판정하므로 **상태 보기(`homelab bot status`)도 plan에서는 대상 파드와 argv만 보이고 `--apply`에서만 실행한다.** 읽기로 허용하는 exec 종류는 두지 않는다(설계 C.7 표). 파드는 ns `app-homelab-bot`에서 라벨로 찾고 Running·Ready인 Deployment 파드가 정확히 하나가 아니면 실행 전에 멈춘다. 결과는 봇이 낸 결과 이름과 상태 값 한 줄(notes)이다.
- `homelab bot account add|use|list`(봇 모델 계정, 봇 C22·C23)도 같은 규칙으로 `--apply`에서만 봇 진입점을 실행한다. `add`·`use`의 `--by`는 `subscription`(기본, 구독 장기 토큰)과 `api`(API 크레딧, Claude Console API 키)다.
  - 자격 자리는 둘이다: **대화용**(대화와 PR 리뷰)과 **작업용**(코드 변경 작성). 기본은 값 하나를 두 자리에 함께 쓴다(로그인 한 번). `--separate-tokens`면 자리마다 따로 받고, 두 값이 같으면 거부한다. 따로 받으면 한쪽만 교체·철회할 수 있고 샌 값으로 어느 자리인지 가를 수 있다.
  - `add <이름> [--replace] [--separate-tokens]`: Claude 구독 장기 토큰을 Infisical `/bot-accounts/<이름>`의 `CLAUDE_CODE_OAUTH_TOKEN`(대화용)·`CLAUDE_CODE_OAUTH_TOKEN_TASK`(작업용)에 두고 봇 DB에 이름·방식·발급일을 적는다. tty면 `claude setup-token`을 가짜 터미널로 띄운다(이 기기에 Claude Code CLI가 있어야 한다). owner는 브라우저 로그인만 하고, CLI가 화면에서 토큰을 받아 가린다(화면에는 `[토큰을 받아 화면에서 가렸다]`). 로그인 안내(URL·코드 입력 안내)는 그대로 보인다. 가짜 터미널은 실제 터미널 폭이다. 거르기는 escape·커서 이동을 걷어 낸 글자 흐름에서 안내 문구 `Your OAuth token`이나 토큰 머리 `sk-ant-`를 찾고, 그 자리부터 claude가 끝날 때까지 화면을 붙든 뒤 토큰을 읽는다(같은 화면을 여러 번 다시 그려도 한 번 받고 모두 가린다. 열 폭에서 접힌 토큰은 앞 줄이 열 끝까지 찼을 때만 이어 읽는다. 줄 끝 공백은 지나 본다). 토큰 뒤에 공백·빈 줄만 지나 `Store this token`이 와야 받고, 어느 토큰에도 들지 않은 토큰 글자뿐인 줄이 있으면 잘린 값일 수 있어 받지 않는다. 값을 확신하지 못하면 가린 채 받지 않고 가려진 입력을 띄운다. 그때는 다른 터미널에서 `claude setup-token`을 실행해 나온 토큰을 붙여 넣고(그 터미널 스크롤은 지운다), 가린 토큰은 Claude 설정에서 철회한다. 화면에 토큰 꼴이 아예 없으면 가리지 않으므로 보이는 토큰을 붙여 넣고 스크롤을 지운다. 토큰을 받은 뒤에는 저장(Infisical)·봇 DB 기록을 한 줄씩 보인다(터미널 요약일 때 움직이는 줄. 파이프·`--json`·`--verbose`는 지금의 진행 줄). 파이프면 stdin 한 줄(`--separate-tokens`면 대화용·작업용 두 줄)이다. stdout에는 결과 문서만 남는다(`--json >파일`에 토큰이 섞이지 않는다). stderr가 터미널이 아니면(`2>파일`, `2>&1 | …`) 꼴이 다를 때 토큰이 그쪽에 남으므로 로그인을 띄우지 않고 아무것도 쓰지 않은 채 실패한다. 그때는 stderr를 터미널에 두거나 토큰을 stdin으로 넘긴다.
  - `add <이름> --by api [--replace] [--separate-tokens]`: Console API 키를 가려진 입력(파이프면 stdin 한 줄, `--separate-tokens`면 두 줄)으로 받아 `/bot-accounts/<이름>`의 `ANTHROPIC_API_KEY`·`ANTHROPIC_API_KEY_TASK`에 두고 봇 DB에 이름·방식을 적는다. `claude`를 띄우지 않는다. 기본·`--separate-tokens`는 구독과 같다.
  - 터미널에서(`--json`·`--verbose`가 아니고 결과가 터미널로 갈 때) `add`·`use`·`list`의 결과는 요약 몇 줄이다: 무엇이 바뀌었나, 지금 상태, 다음에 할 일. 실패하면 실패한 단계 이름과 원인, 다음 행동이 보인다. 진행 줄은 지금 무엇을 기다리는지 한 줄씩이고, stderr가 터미널이면 움직이는 표시로 그 줄만 다시 그린다(쓰기·기다림이 동기 호출이라 Worker 스레드가 그린다. clack `spinner`는 stdin을 raw로 두어 Ctrl-C에 `process.exit(0)`으로 끝나므로 쓰지 않는다. 커서를 숨기지 않아 Ctrl-C 뒤에도 프롬프트가 새 줄에서 시작한다). 단계 표 전체와 실행한 `kubectl` 줄은 `--verbose`에서 보인다. 파일·파이프와 `--json` 출력은 단계 표·JSON 그대로다. 입력·요약 화면은 `@clack/prompts`로 그린다(core의 입력·출력 계층만 쓴다).
  - `use <이름> [--by api]`: 먼저 두 작업자 ExternalSecret(`sandbox`)이 그 방식의 자격(API면 방식 표시 `CLAUDE_AUTH_METHOD`도)을 작업자 파일 이름으로 옮기는지 `spec.data`로 보고, 아니면(`dataFrom`·template 데이터처럼 판정할 수 없는 모양 포함) plan에서도 그 사실로 실패하고 아무것도 쓰지 않는다. 그다음 계정 폴더의 그 방식 두 값을 작업자 키(`/apps/homelab-bot/worker`)로 옮기고 → 방식 표시를 그 방식으로 → 두 ExternalSecret 즉시 동기화 → Secret 해시·방식 표시 확인 → 작업자 두 파드의 자격 파일 지문·방식 표시 확인 → 그 뒤에만 다른 방식의 두 키를 `unset`으로 쓰고 그 키를 옮기는 Secret이면 다시 동기화해 비워졌는지 확인(작업자 키에 자격이 하나만 남는다) → 봇 DB의 지금 계정·방식 바꾸기와 모델 멈춤 작업(결제 멈춤 포함) 해제 순서다. 반영 확인과 옛 자격 비우기 사이에는 두 방식 자격이 함께 보이지만 작업자는 방식 표시의 자격만 쓰므로 허용하고, 자격이 없는 순간은 만들지 않는다. 앞 단계가 실패하면 해제하지 않는다. 같은 계정·방식으로 다시 실행하면 된 단계는 건너뛰고 해제만 다시 한다. 대화용·작업용이 같은 값이어도(로그인 한 번 등록) 해시·지문 확인은 같다. `--by api`는 sandbox ExternalSecret이 대화용·작업용 API 키·방식 표시를 옮기는 배포 뒤에만 된다(rotate.md 3e "API 크레딧 방식"). 방식 표시·`unset`은 비밀이 아닌 고정 값이라 core `setMarker`가 쓴다(시크릿 입력의 16자 하한 밖).
  - `list`: 이름·방식·지금 계정·토큰 만료일·마지막 사용률과 풀리는 시각·모델 멈춤 작업 수. 값과 크레딧 잔액은 보이지 않는다.
- 종료 코드: 0 완료·변경 없음·plan, 1 실패(원인과 다음 행동), 3 대기(apply 뒤 PR 병합·동기화), 64 사용법 오류. `github` 하위 명령은 `tools/tf-github.sh` 코드 그대로(0 같음, 2 차이, 1 guard·실패).
- 중복·모르는 플래그는 거부한다. 값에 줄바꿈·제어 문자가 있으면 거부하고 값 전체를 형식과 맞춘다.
- 재실행 안전: 단계마다 실행 직전에 현재 상태를 읽고 된 단계는 건너뛴다. 타임아웃은 재시도하지 않고 다시 읽는다.
- `--json`은 `schema: homelab-cli/v1` 문서 하나를 stdout에 낸다. 진행 줄은 stderr.
- PR은 GitHub API로 `cli/<명령>-<app>` 브랜치에 만든다(로컬 체크아웃 없음). 파일 내용은 그때의 main 스냅샷에서 다시 계산하고, 열린 PR은 머리 커밋의 `Homelab-CLI:` 트레일러와 PR 전체 변경 집합까지 본다. 갱신은 force 없이 부모 [main 스냅샷, 확인한 머리]의 fast-forward라, 확인 뒤 사람 push가 끼면 GitHub가 거부하고 CLI는 덮지 않고 멈춘다. 병합은 사람이 한다.
- 시크릿 입력(예: `secret set`의 stdin)은 16자 이상만 받는다. 생성 비밀번호는 영숫자 40자.
- `app add`는 `apps/<app>/values.yaml`이 있으면 다루는 키(`chartVersion`·`public`·`internal`·`secrets`·`uses`·`cache`)만 바꾸고 사람이 더한 키·주석은 둔다. `app remove` 뒤 재등록은 그 파일을 기본값(`chartVersion`·`kind`·`port`·`resources`)과 플래그·Infisical `/apps/<app>`의 키로 새로 써서, 사람이 더한 키(`migration`·`env`, 고친 `resources` 등)가 사라진다. 필요하면 `app remove` PR에서 지운 내용을 보고 **재등록 PR(CLI가 만든 PR)에 되살린 커밋을 더한 뒤** 검토·병합한다. main 병합이 곧 배포라, 재등록 PR을 먼저 병합하면 빠진 설정으로 먼저 배포된다. 이미 병합했으면 따로 PR로 되살리되, `migration`만 되살린 PR은 자동 sync를 일으키지 않아 Job이 다음 배포 때 돈다(설계 C.5.4, T13 시나리오 9).

## 명령 더하기

등록 표 `src/registry.ts`에 C.7의 모든 명령이 있다. 구현하는 사람은 자기 명령 파일 `src/commands/<이름>.ts`(와 같은 접두의 도우미 `src/commands/<이름>-*.ts`)만 바꾸고 공통부(`src/core/`, `test/harness.ts`, `test/stub.ts`)는 고치지 않는다. 등록 표는 새 명령을 더할 때만 두 줄을 더한다(아래 도움말 자료). 어댑터가 모자라면 공통부 담당에게 알려 공통부에 더한다.

**도움말 자료(새 명령을 더할 때):** 새 명령은 `src/registry.ts`에 import 한 줄과 `SECTIONS`의 알맞은 분류에 한 줄을 더한다(분류는 사람이 하려는 일 기준이다. 맞는 분류가 없을 때만 새로 만든다). 나머지는 명령 파일의 `defineCommand` 안에 둔다.

- `summary`: 목록에 보이는 한 줄. 명사형으로 짧게(22자 안팎, 플래그·내부 번호 없이). 예 `봇이 쓸 계정 바꾸기`.
- `help.about`: 무엇을 하는지 한두 문장, 합니다체. `help.examples`: `homelab <명령> …` 꼴 argv 한두 개(합성 값, 셸 문법 없이). `help.related`: 함께 쓰는 명령 경로. `help.doc`: 자세한 절차 문서 경로와 절. 첫 인자가 동작인 명령은 `help.actions`.
- 플래그·인자 설명은 `FlagSpec.help`·`ArgSpec.help` 하나뿐이다(파서와 같은 자리). 명사형 한 줄.
- 내부 번호(설계 절, 티켓 번호)·스크립트 이름은 쓰지 않는다. 시험(`test/core/help.test.ts`)이 분류 누락, 자료 누락, 예가 실제 파서에서 64가 나는 것, 도움말 플래그와 파서의 차이, 80칸 넘는 줄, 내부 번호를 잡는다.

**구조(안전의 근거):** 명령은 외부 명령을 직접 실행할 수 없다. 받는 것은 타입 있는 어댑터뿐이고 어댑터마다 argv 모양이 고정이다.

- **위협 모델:** 이 경계는 실수로 새는 것을 막는다. 같은 프로세스에서 일부러 전역을 바꾸는 코드는 막지 않는다(명령 코드는 리뷰받은 저장소 코드, 설계 C.7). 그래도 명령 파일은 내장 전역(`JSON`·`Object`·프로토타입 등)을 바꾸지 않는다(정적 시험). core는 시작할 때 잡아 둔 함수(`src/core/intrinsics.ts`)를 쓴다.
- **import:** 명령 파일은 `../core/command`(정의·문맥 타입), `../core/names`, `../core/result`, `../core/pr`, `../core/command-info`와 자기 접두 도우미만 import한다. `Bun`·`process`·`fetch`·`require`·동적 import·`console` 같은 전역도 쓰지 않는다. 정적 시험이 막는다.
- **읽기 문맥 `ctx`(run과 `Step.read`):** `ctx.k8s`(get·list·secretHash·secretExists·logs·canI·rolloutStatus·currentContext), `ctx.infisical`(has·listKeys·getValue·valueHash·projectStatus), `ctx.gh.get`(repos/ukyi-app/…·orgs/ukyi-app/…·user만), `ctx.repo`(mainSha·readFile), `ctx.ghcr.anonymousPullStatus`, `ctx.tools`(doctor용), `ctx.github`(github 위임 명령만). 쓰기 함수는 없다.
- **쓰기 문맥 `w`(`Step.apply(w, seen)`만):** 위 읽기에 더해 `w.k8s`(forceSync·rolloutRestart·createRestoreObject·deleteRestoreObjects), `w.infisical`(setValue·removeKey), `w.generatePassword()`, `w.readSecretInput(prompt)`. 엔진이 apply 한 번마다 새로 만들고 끝나면 폐기한다. 붙잡아 두었다가 쓰면 모든 호출이 막힌다. 엔진은 한 번에 하나만 돈다(중첩·병렬 거부).
- **T12 어댑터 묶음(02·03·04 요청):** 읽기에 `ctx.k8s`의 `secretEmbeds`·`waitSecret`·`waitFor`·`waitCondition`·`podSecretsCurrent`·`restoreRecord`·Job 로그, `ctx.infisical.folderExists`, `ctx.web.publicStatus`. 쓰기에 `w.k8s`의 `restartForSecrets`·복원 기록 셋·`deleteRestoreObject`·`createJobFromCronJob`·`setPvReclaimDelete`·`forceSync({ waitSec })`, `w.infisical.createFolder`, `w.pg.passwordCheck`, `w.valkey`(정해진 다섯 명령·`waitAof`·`authCheck`), `w.http.appStatus`(port-forward 헬스 셋), `w.confirm`. `wrapper: "plan-json"` 명령(app new)만 `ctx.github.planChanges`·`w.github.apply`·`w.appRepo`. 파드 안 셸·SQL 텍스트는 core 상수다(명령은 이름과 Secret만 넘긴다).
- **DB 복원(`w.pgRestore`, restore.md 2절):** 흐름·SQL·Job·임시 Cluster 매니페스트는 core가 갖는다. 명령은 (app, run)과 검증된 값만 넘기고 단계 순서와 표식만 정한다. 4-2 산출물은 core가 기록 `restore-pg`의 `in.*`에 고정하고(명령은 `in.*`·`dropped`를 못 쓴다), DB 다시 만들기·본 복원·ACL 복원 앞에서 core가 잠금·앱 멈춤·입력 고정을 다시 본다. 덤프는 kubectl 둘을 잇는 파이프로만 흐른다.
- **봇 관리 기능(`ctx.bot`·`w.bot`, C05):** 읽기 문맥의 `ctx.bot`은 대상 파드 찾기(`pod()`)와 실행할 argv(`argv()`)만 내고 exec하지 않는다. 쓰기 문맥의 `w.bot.admin(cmd)`가 파드를 다시 찾아 `node /app/dist/src/admin-main.js <동작> [ID]`를 한 번 실행하고, 봇 출력의 결과 이름·상태 값만 돌려준다(꼴이 다르면 원문 없이 던진다). ns·라벨·컨테이너·진입점 경로는 core 상수(`podops.ts`)다. 계정 동작(C22·C23)은 `w.bot.admin`의 `account` 명령, 작업자 두 파드의 자격 파일 지문 대기 `w.bot.waitWorkerCredentials(want, 초, 방식)`(ns `sandbox`, Deployment `worker`·`worker-task`, 컨테이너 `worker`의 고정 파일 둘(그 방식의 자격 파일, 방식 표시 `CLAUDE_AUTH_METHOD`) `sha256sum`, exec 실패는 기다림의 일부, 구독은 방식 표시 파일이 없어도 된다), 토큰 입력 `w.readSetupTokens(lanes, separate)`, API 키 입력 `w.readApiKeys(lanes, separate)`(둘 다 Promise), 방식 표시·자리 표시값 쓰기 `w.infisical.setMarker`(값은 `subscription`·`api`·`unset`뿐)를 쓴다. 계정 이름 규칙·폴더·자리별 키·방식별 파일은 `../core/names`의 `BOT_ACCOUNT_NAME`·`botAccountFolder`·`BOT_LANES`·`botLaneKey`·`BOT_WORKER_FILE`·`BOT_METHOD_KEY`·`BOT_UNSET`이다. 직접 stdio는 github 위임뿐이고, `claude setup-token`은 쓰기 문맥의 가짜 터미널(`makeTerminalLogin`, argv 고정)로만 띄운다.
- **터미널 요약:** `CommandSpec.terminalSummary`인 명령은 `Plan.summary`(단계 id → 쉬운 이름, 기다림 진행 줄, 끝났을 때의 머리·줄·다음)를 준다. plan·실패·대기 요약은 엔진이 공통으로 만든다. 그 명령은 `--verbose` 플래그를 직접 둔다(전역 플래그가 아니라 다른 명령의 사용법이 바뀌지 않는다).
- **기다림 단계:** 바깥(PR 병합 등)을 기다리는 동안 뒤 단계를 돌리면 안 되면 관찰에 `hold`를 둔다(`same`일 때만). apply가 그 단계에서 멈추고 3(대기)으로 끝난다. 같은 명령을 다시 치면 이어 간다. 전체 읽기 때 알린 대기 주의는 apply가 그 단계를 다시 읽어 풀렸으면 지운다.
- **values YAML:** `../core/values`의 `setTopLevel(text, edits)`가 최상위 키만 한 줄 flow로 고치고 주석은 둔다. `setMapString(text, parent, key, value)`는 주석이 든 맵 블록(`env` 등)의 키 한 줄만 고치거나 더한다. 다시 읽은 값이 기대와 다르면 던진다.
- **PR:** `prStep({ command, app, title, body, files, edit })`. `edit(현재 내용)`은 같은 키로 원하는 내용(지우려면 null)을 돌려준다. 읽을 때와 apply 때 모두 그 시점의 main 스냅샷에서 다시 부른다.
- **Secret 값:** kubectl은 `secretHash`·`secretExists`(값은 밖으로 안 나온다), Infisical 값은 `getValue`가 불투명한 Secret으로 준다. 원문을 꺼내는 메서드가 없고(타입·런타임 둘 다, 객체는 freeze), 문자열로 바꾸면 `[secret]`이며, 할 수 있는 것은 `setValue`로 넘기기·`sha256Prefix`·`equals`뿐이다. 범용 kubectl 조회에는 Secret 종류가 없다.
- **logs:** `ctx.k8s.logs`는 앱 로그를 그대로 준다. 앱이 자격을 로그에 쓰지 않는 것은 앱 계약이다(설계 C.7). 이 실행이 다룬 16자 이상 시크릿이 섞이면 출력 계층이 막는다.
- **github 위임:** `ctx.github.run("plan" | "verify" | "apply", { allowDestroy })`. core가 main을 임시 폴더로 fresh clone하고 그 안의 `tools/tf-github.sh`를 부르며 종료 코드를 그대로 돌려준다. CLI를 실행한 checkout의 루트는 `TF_GITHUB_ORIGIN_ROOT`로 넘겨 state 백업이 그 안에 생기지 않게 하고, 래퍼에는 상속된 `GIT_*`를 넘기지 않는다. 직접 stdio도 이 경로만 쓴다.
- **바꾸는 일은 `ctx.engine({ command, app, steps })`의 `Step.apply()` 안에서만.** `read()`는 이미 된 일에 `same`을 낸다. `apply()`에 재시도 루프를 두지 않는다(타임아웃은 엔진이 재조회).
- **출력:** Result의 `target`·`detail`·`notes`·`next`로만 말한다. 실패에는 `error.next`(다음 행동)가 있다. 원인을 아는 실패는 `CliError(message, next)`로 던지면 단계 안에서도 엔진이 그 `next`를 쓴다(예 Infisical 로그인 만료 → `infisical login`). `exitCode`는 `github *`만.
- **시험:** `test/commands/<이름>.test.ts`에 `expectPlanReadOnly(...)`를 부르는 plan 시험(정적 시험이 확인), 다 된 상태에서 apply → 모든 `state: same`, 중간 쓰기 실패 → exit 1과 뒤 단계 `not-run` → 재실행으로 이어짐, 사람용·`--json` 출력에 가짜 시크릿 없음. 장치는 `test/harness.ts`(`runCli`, `testCtx`, `applyWith`, 규칙 도우미)이고 모양은 `test/core/pr.test.ts`·`engine.test.ts`·`adapters.test.ts`·`github-delegate.test.ts`를 본다. 스텁 응답 `responses`는 호출 순서대로 쓰이고, apply는 단계마다 전체 읽기·직전 읽기·(실행)·재조회 순으로 읽는다.
