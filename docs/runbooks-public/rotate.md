# 회전: 자격과 비밀번호 바꾸기 (초안)

자격·비밀번호를 바꾸는 순서다. 근거는 설계 [C.6.5](../plans/2026-10-17-homelab-rebuild/platform/design.md)(값 변경과 비밀번호 회전)다. T09가 초안을 만들었고, 각 자격을 만드는 티켓이 자기 절을 채운다(4절).

- 값은 출력하지 않는다. 확인은 응답 코드, 키 이름, 해시 앞부분으로만 한다.
- 외부 변경(발급, 폐기, Infisical 값 교체)은 [approvals.md](../plans/2026-10-17-homelab-rebuild/approvals.md)에 줄로 남긴다.
- 발급 화면의 경로나 범위 같은 세부는 저장소 밖 작업 기록에 둔다(D-23).
- 실행하다 이 문서와 다르게 한 것이 있으면 이 문서를 먼저 고친다.

## 0. 공통 규칙

- 네 단계는 원자적이지 않다: Infisical 원본 변경 → Kubernetes Secret 갱신 → 실제 자격 적용 → 쓰는 쪽이 새 자격 사용. 환경변수는 파드를 다시 만들어야 바뀐다.
- Infisical Free에는 버전 이력이 없다. 덮어쓸 값은 `<KEY>_PREVIOUS`로 남겼다가 새 값을 확인한 뒤 지운다.
  예외: Secret Sync가 내보내는 프로젝트(`homelab-ci-merge`)에는 `_PREVIOUS`를 만들지 않는다. Sync가 프로젝트의 키를 그대로 GitHub environment에 복제해, 옛 키가 두 번째 environment secret이 되고 T10 guard(secret 이름 집합 `[]` 또는 `[HOMELAB_MERGE_KEY]`)가 실패한다. 옛 App 키는 GitHub App 쪽에 남아 있어 Infisical 사본이 필요 없다.
- 즉시 동기화는 annotation으로 한다. `refreshInterval`(1h)을 기다리지 않는다.

  ```bash
  kubectl -n <ns> annotate externalsecret <이름> force-sync="$(date +%s)" --overwrite
  ```

- 자동 재시작 컨트롤러는 두지 않는다. 재시작은 순서의 한 단계로 명시한다.
- 필수 키가 빠지면 ExternalSecret이 `SecretSyncedError`로 멈추고 Secret은 바뀌지 않는다. 잘못된 값이 적용되지 않는다(시나리오 6). 키는 있는데 값이 틀린 경우는 다르다. ESO는 그 값을 그대로 옮기고 `SecretSynced`가 된다. 그래서 절마다 새 값을 실제로 쓰는지를 따로 확인한다.

## 1. ESO 부트스트랩 자격 (연 1회)

`eso-homelab`(VM은 `eso-homelab-dev`)의 Universal Auth client secret이다. T09 시나리오 7(2026-10-20)의 장애 주입과 복구가 이 순서였다.

1. Infisical에서 identity의 Universal Auth에 새 client secret을 만든다. TTL 0, 사용 횟수 0(무제한). ESO는 동기화마다 새로 로그인하므로 사용 횟수를 1로 두면 두 번째 동기화부터 실패한다. 옛 secret과 복구 자산의 옛 사본은 5단계까지 그대로 둔다. 새 값을 잘못 옮겨 적었을 때 돌아갈 값이 남아야 한다.
2. 새 값으로 직접 로그인해 본다. 응답 코드만 보고 토큰은 버린다. 값은 `export`한 환경변수로만 넘긴다(bootstrap.md 2.2와 같은 변수).

   ```bash
   bash -euo pipefail <<'EOF'
   : "${ESO_CLIENT_ID:?}" "${ESO_CLIENT_SECRET:?}"
   jq -n '{clientId: env.ESO_CLIENT_ID, clientSecret: env.ESO_CLIENT_SECRET}' \
     | curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://app.infisical.com/api/v1/auth/universal-auth/login \
         -H 'Content-Type: application/json' --data @-     # 200이어야 한다
   EOF
   ```

3. [bootstrap.md](bootstrap.md) 2.2의 명령으로 부트스트랩 Secret `external-secrets/infisical-universal-auth`를 바꾼다. 같은 명령이고 값만 새것이다.
4. 새 값으로 동기화되는지 확인한다. 이미 Ready·`SecretSynced`인 상태에서 교체하므로 상태만 보면 옛 결과를 새 값의 성공으로 오인한다. ExternalSecret 하나를 즉시 동기화하고 `refreshTime`이 교체 시각 뒤인지 본다. ESO는 동기화마다 부트스트랩 Secret으로 새로 로그인하므로(시나리오 7에서 폐기 직후 즉시 동기화가 바로 실패했다), 이 동기화가 성공이면 새 값이 맞다. ESO를 재시작하지 않아도 된다.

   ```bash
   date -u +%Y-%m-%dT%H:%M:%SZ               # 교체 시각(3단계 직후)
   kubectl -n argocd annotate externalsecret argocd-owner force-sync="$(date +%s)" --overwrite
   kubectl -n argocd get externalsecret argocd-owner \
     -o jsonpath='{.status.refreshTime} {.status.conditions[0].reason}{"\n"}'   # 교체 시각 뒤, SecretSynced
   kubectl get clustersecretstore            # 둘 다 READY True. Store는 5분마다 다시 검증한다
   ```

   새 값이 틀렸으면 이 동기화가 `SecretSyncedError`가 된다. 기존 Secret은 그대로이니 3단계를 맞는 값(또는 옛 값)으로 다시 한다.
5. 4단계가 새 값으로 성공한 뒤에 복구 자산 두 곳의 사본을 새 값으로 바꾼다.
6. 그다음에만 Infisical에서 옛 client secret을 폐기한다. 순서를 바꾸면 그 사이 동기화가 실패한다(기존 Secret과 서비스는 유지된다, 시나리오 7).

## 2. Argo CD `owner` 비밀번호

ExternalSecret `argocd/argocd-owner`가 Infisical `/platform/argocd`의 두 키를 `argocd-secret`에 합친다(`platform/external-secrets/templates/argocd-owner.yaml`). Argo CD는 bcrypt 해시만 받는다.

1. 새 비밀번호를 정하고 bcrypt 해시를 만든다. 비밀번호는 `getpass`로만 받아 화면·인자에 남기지 않는다. 8자 이상, 72바이트 이하다(bcrypt는 72바이트 뒤를 버린다). 해시는 비밀번호를 오프라인으로 추측할 수 있는 자료라 값처럼 다룬다: 에이전트가 읽는 터미널이나 기록이 남는 세션에서 돌리지 않고, Infisical에 붙여 넣은 뒤 화면과 스크롤백을 지운다. 파일로 저장하지 않는다.

   ```bash
   # uv는 .tool-versions에 고정돼 있다(mise install). bcrypt는 실행 때 정확한 버전으로 받는다
   uv run --no-project --with 'bcrypt==5.0.0' python -I -c \
     'import bcrypt, getpass; print(bcrypt.hashpw(getpass.getpass().encode(), bcrypt.gensalt(12)).decode())'
   date -u +%Y-%m-%dT%H:%M:%SZ               # 새 OWNER_PASSWORD_MTIME
   read -r -p "Infisical에 넣었으면 Enter" _; clear; printf '\033[3J'
   ```

2. Infisical `/platform/argocd`의 `OWNER_PASSWORD_BCRYPT`와 `OWNER_PASSWORD_MTIME`을 함께 바꾼다. MTIME을 바꾸면 그 전에 발급된 세션 토큰이 무효가 된다. 원문은 비밀번호 관리자에 둔다.
3. 즉시 동기화한다. Argo CD는 `argocd-secret`을 지켜보므로 재시작하지 않는다.

   ```bash
   kubectl -n argocd annotate externalsecret argocd-owner force-sync="$(date +%s)" --overwrite
   kubectl -n argocd get externalsecret argocd-owner   # SecretSynced
   ```

4. 새 비밀번호로 로그인해 본다. UI 경로가 생기기 전(T08a)에는 `argocd-server` Service로 port-forward해 `POST /api/v1/session`이 200인지 본다. 응답 본문(토큰)은 버린다.

## 3. GitHub App 병합 키 (T10 뒤)

병합 키 원본은 `homelab-ci-merge`이고, GitHub environment `automerge`의 secret `HOMELAB_MERGE_KEY`는 Infisical Secret Sync의 사본이다.
아래 `infisical run`은 [infra/README.md](../../infra/README.md) 2절의 백업 폴더 준비(쓰기 불가 확인)를 한 셸에서 한다.

1. `tools/tf-github.sh verify`(T12 뒤 `homelab github verify`)가 exit 0인지 본다. environment가 지워졌다 정책 없이 다시 생겼으면 여기서 guard 9가 멈춘다. 그 상태로 Sync가 돌면 키가 보호 없는 environment에 들어간다.
2. GitHub에서 병합 App의 새 개인 키를 발급한다. 내려받은 파일은 Infisical에 넣은 뒤 바로 지운다.
3. `homelab-ci-merge`의 `HOMELAB_MERGE_KEY` 값을 새 키로 바꾼다. 교체 시각을 적어 둔다.
4. environment secret이 교체 뒤에 갱신됐는지 본다. 시각이 교체보다 이전이거나 Infisical의 sync 실패 메일이 왔으면 Sync를 다시 실행한다.

   ```bash
   gh api repos/ukyi-app/homelab/environments/automerge/secrets/HOMELAB_MERGE_KEY --jq .updated_at
   ```

5. 새 키 자체로 인증되는지 본다. `updated_at`은 다시 쓰였다는 사실만 보여 주고, 그 키가 병합 App의 키인지는 보여 주지 않는다. 새 키로 App JWT를 만들어 `GET /app`의 `id`가 병합 App ID인지 본다. 키는 환경변수로만 받고 파일로 쓰지 않는다(서명은 프로세스 치환 파이프, 토큰은 curl 설정을 표준 입력으로).

   ```bash
   read -r -p 'homelab-ci-merge project ID: ' MERGE_PROJECT_ID
   read -r -p 'ukyi-merge App client ID: ' APP_CLIENT_ID
   export APP_CLIENT_ID
   infisical run --silent --log-level=error --projectId="$MERGE_PROJECT_ID" --env=prod --path=/ -- bash -c '
     set -euo pipefail
     b64() { openssl base64 -A | tr "+/" "-_" | tr -d "="; }
     now=$(date +%s)
     h=$(printf "{\"alg\":\"RS256\",\"typ\":\"JWT\"}" | b64)
     p=$(printf "{\"iat\":%d,\"exp\":%d,\"iss\":\"%s\"}" $((now - 60)) $((now + 540)) "$APP_CLIENT_ID" | b64)
     s=$(printf "%s.%s" "$h" "$p" | openssl dgst -sha256 -sign <(printf "%s\n" "$HOMELAB_MERGE_KEY") | b64)
     printf "header = \"Authorization: Bearer %s.%s.%s\"\n" "$h" "$p" "$s" |
       curl -sS -K - -H "Accept: application/vnd.github+json" https://api.github.com/app | jq -r .id'
   ```

   출력이 `infra/github/variables.tf`의 `homelab_merge_app_id`와 같아야 한다.
6. 그다음에만 옛 키를 지운다. App 키는 만료가 없고 25개까지 동시에 유효해, `deploy-merge`가 성공해도 옛 키로 성공했을 수 있다. 옛 키를 지운 뒤에야 401이 나고, 그때 배포 PR은 열린 채 남는다(안전한 쪽 실패).

## 3a. GitHub App 배포 키 (T10 뒤)

배포 키 원본은 `homelab-ci-deploy`의 `HOMELAB_DEPLOY_KEY`이고 GitHub에 사본이 없다. 앱 main push의 `app-build` deploy-pr job이 OIDC identity `gha-homelab-deploy`로 실행 중에만 받는다.

1. GitHub에서 배포 App의 새 개인 키를 발급한다.
2. `homelab-ci-deploy`의 `HOMELAB_DEPLOY_KEY` 값을 새 키로 바꾼다. `_PREVIOUS`를 만들지 않는다. 옛 키는 App 쪽에 남아 있다.
3. 3절 5번과 같은 방법으로 새 키의 `GET /app` `id`가 `homelab_deploy_app_id`인지 본다(프로젝트 ID, client ID, 키 이름만 바꾼다).
4. 앱 저장소 하나의 main 빌드가 배포 PR을 만들거나 갱신하는지 본다(`app-build` 요약).
5. 옛 키를 지운다.

## 3b. Infisical GitHub 연결 PAT (병합 키 Sync용, T10 뒤)

App Connection은 owner 계정의 fine-grained PAT다(리소스 소유자 `ukyi-app`, 저장소 `homelab`만, Metadata read, Environments RW, Secrets RW, 만료 없음. 사용자 결정 2026-10-21). 새었다고 의심되거나 범위를 바꿀 때 바꾼다. 만료가 없어 새면 회수할 때까지 유효하다.
회수되면 Sync가 실패하고 프로젝트 Admin에게 메일이 온다.

1. `tools/tf-github.sh verify` exit 0을 먼저 본다(3절 1번과 같은 이유).
2. 같은 범위로 새 PAT를 발급한다. 다른 저장소나 권한을 더하지 않는다. 더하면 그 PAT가 새는 순간 다른 저장소의 secret도 바뀐다.
3. Infisical App Connection의 토큰을 새 PAT로 바꾸고 Sync를 한 번 다시 실행한다.
4. 3절 4번의 `updated_at`이 Sync 재실행 뒤인지 본다.
5. 옛 PAT를 폐기한다. 폐기 뒤에도 4번이 그대로면 끝이다.

## 3c. 앱 DB 비밀번호 (T11, 시나리오 8)

원본은 Infisical `homelab`/`prod`의 `/apps/<앱>/postgres/PASSWORD` 하나다. 사본은 `database` ns의 역할 Secret `pg-role-<앱>`(데이터 차트, `cnpg.io/reload` 라벨)과 앱 ns의 연결 Secret `<앱>-db`(앱 차트 `DATABASE_URL`) 둘이다. 3~6단계 사이에 옛 값으로 새 연결을 여는 파드는 실패한다. 이미 열린 연결이 유지되는지는 U17로 이 순서에서 잰다.

```bash
export KUBECONFIG=~/.kube/homelab.yaml
APP=<앱 이름>
h() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d | sha256sum | cut -c1-12; }   # 값 대신 해시 앞부분
h database pg-role-$APP password; h app-$APP $APP-db DATABASE_URL                                      # 전
```

1. 새 값을 비밀번호 관리자에서 만들고(32자 이상, 영숫자) Infisical UI에서 바꾼다. 옛 값은 같은 폴더에 `PASSWORD_PREVIOUS`로 먼저 옮겨 둔다. CLI의 `secrets set KEY=VALUE`는 값이 명령행 인자라 쓰지 않는다.
2. `database` ns를 먼저 동기화한다. CNPG가 Secret 변경을 보고 바로 `ALTER ROLE` 한다[S31].

   ```bash
   kubectl -n database annotate externalsecret pg-role-$APP force-sync="$(date +%s)" --overwrite
   kubectl -n database get externalsecret pg-role-$APP          # SecretSynced
   h database pg-role-$APP password                              # 전과 다름
   kubectl -n database get secret pg-role-$APP -o jsonpath='{.metadata.resourceVersion}{"\n"}'
   kubectl -n database get databaserole $APP -o jsonpath='{.status.applied} {.status.secretResourceVersion} {.status.message}{"\n"}'
   # applied=true, secretResourceVersion이 바로 위 Secret의 resourceVersion과 같으면 적용됐다
   ```

3. U17: 이 시점에 앱이 계속 `/healthz/db` 200인지 본다(열린 연결 유지). 연결 풀이 새 연결을 열면 실패할 수 있다.
4. 앱 ns를 동기화하고 앱을 다시 띄운다. env는 파드를 다시 만들어야 바뀐다. Argo CD는 `rollout restart`가 더하는 주석을 되돌리지 않는다(Git에 없는 필드라 비교하지 않는다).

   ```bash
   kubectl -n app-$APP annotate externalsecret $APP-db force-sync="$(date +%s)" --overwrite
   h app-$APP $APP-db DATABASE_URL                               # 전과 다름
   kubectl -n app-$APP rollout restart deploy/$APP
   kubectl -n app-$APP rollout status deploy/$APP
   kubectl -n app-$APP port-forward deploy/$APP 18080:8080 &
   curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/healthz/db    # 200
   kill %1
   ```

5. 옛 값으로 새 접속이 실패하는지 본다(시나리오 8). 옛 값은 Infisical UI에서 비밀번호 관리자로만 옮기고, 화면에 띄우지 않고 표준 입력으로 넘긴다.

   ```bash
   PRIMARY=$(kubectl -n database get cluster pg -o jsonpath='{.status.currentPrimary}')
   read -rs OLD; printf '%s' "$OLD" | kubectl -n database exec -i $PRIMARY -c postgres -- sh -c \
     'IFS= read -r PGPASSWORD || true; export PGPASSWORD; psql "host=127.0.0.1 user='"$APP"' dbname='"$APP"' sslmode=require" -tAc "select 1"'; unset OLD
   # password authentication failed
   # 127.0.0.1: database ns의 5432 기본 거부(앱 ns만 허용)를 거치지 않는 TCP 비밀번호 접속이다. 로컬 소켓은 peer라 비밀번호를 안 본다.
   ```

6. `PASSWORD_PREVIOUS`를 지운다.

중단 없이 바꿔야 하면 역할 두 개를 번갈아 쓰는 방식이 있다(설계 C.6.5, 선택). 지금은 두지 않았다.

## 3d. Valkey 비밀번호 (T11)

원본은 `/apps/<앱>/valkey/PASSWORD` 하나다. 사본은 같은 앱 ns의 두 Secret이다: 서버용 `<앱>-valkey-auth`(캐시는 앱 차트, 영속은 데이터 차트)와 앱 연결용 `<앱>-valkey-url`(`VALKEY_URL`). 서버는 시작 때 ACL 파일을 만들므로 다시 띄워야 새 값이 적용된다. 그동안(수 초) 앱은 Valkey 오류를 낸다. 영속 Valkey는 AOF everysec라 재시작 손실이 약 1초다.

1. 3c 1단계처럼 Infisical 값을 바꾼다(옛 값은 `PASSWORD_PREVIOUS`).
2. 두 ExternalSecret을 동기화한다.

   ```bash
   kubectl -n app-$APP annotate externalsecret $APP-valkey-auth $APP-valkey-url force-sync="$(date +%s)" --overwrite
   h app-$APP $APP-valkey-auth password; h app-$APP $APP-valkey-url VALKEY_URL     # 둘 다 전과 다름
   ```

3. 서버, 그다음 앱을 다시 띄운다.

   ```bash
   kubectl -n app-$APP rollout restart deploy/$APP-valkey && kubectl -n app-$APP rollout status deploy/$APP-valkey
   kubectl -n app-$APP rollout restart deploy/$APP && kubectl -n app-$APP rollout status deploy/$APP
   ```

4. 앱 `/healthz/cache`가 200인지 본다(3c 4단계의 port-forward). 영속 Valkey면 다음 백업 Job도 새 값으로 도는지 수동 Job 하나로 본다([restore.md](restore.md) 1절 0단계).
5. `PASSWORD_PREVIOUS`를 지운다.

## 3e. 봇 작업자 모델 자격 (대화용·작업용, 구독·API 크레딧, T18 · CLI C22·C23·C35)

방식이 둘이다. 구독은 Claude 구독 장기 토큰(`claude setup-token`, 발급 뒤 1년 만료), API 크레딧은 Claude Console API 키다(아래 "API 크레딧 방식"). 자리도 둘이다: 대화용(대화와 PR 리뷰)과 작업용(코드 변경 작성). 기본은 값 하나를 두 자리에 함께 쓴다(로그인 한 번). `--separate-tokens`로 자리마다 따로 받을 수 있다. 함께 쓰면 한쪽만 교체·철회할 수 없고, 샌 값만으로 어느 자리인지 가를 수 없다. 개인 `~/.claude*`를 복사하지 않는다. 봇은 스스로 다른 계정·방식으로 바꾸지 않고, 바꾸는 것은 owner가 `homelab bot account`로만 한다(봇 DECISIONS D-14 조건 5). 구독 토큰은 만료 30일 전부터 봇 브리핑이 계정 이름과 남은 날수를 알린다.

자격 값은 계정마다 Infisical `/bot-accounts/<이름>`에 두고(작업자가 읽지 않는 폴더), `homelab bot account use`가 지금 쓸 계정·방식의 값을 작업자 키로 옮긴다. 같은 계정의 값 교체도 같은 절차다(`add --replace` → `use`).

| 자리 | 방식 | 계정 폴더 `/bot-accounts/<이름>` | 작업자 키 `/apps/homelab-bot/worker` | Secret 키(파일 이름) | Secret · 파드 |
|---|---|---|---|---|---|
| 대화용 | 구독 | `CLAUDE_CODE_OAUTH_TOKEN` | `CLAUDE_CODE_OAUTH_TOKEN` | `CLAUDE_CODE_OAUTH_TOKEN` | `sandbox/worker-credential-claude-subscription` · `worker` |
| 대화용 | API 크레딧 | `ANTHROPIC_API_KEY` | `ANTHROPIC_API_KEY` | `ANTHROPIC_API_KEY` | 같음 |
| 작업용 | 구독 | `CLAUDE_CODE_OAUTH_TOKEN_TASK` | `CLAUDE_CODE_OAUTH_TOKEN_TASK` | `CLAUDE_CODE_OAUTH_TOKEN` | `sandbox/worker-task-credential-claude-subscription` · `worker-task` |
| 작업용 | API 크레딧 | `ANTHROPIC_API_KEY_TASK` | `ANTHROPIC_API_KEY_TASK` | `ANTHROPIC_API_KEY` | 같음 |
| 둘 다 | 방식 표시 | 없음 | `CLAUDE_AUTH_METHOD`(`subscription` 또는 `api`) | `CLAUDE_AUTH_METHOD` | 두 Secret 모두 |

작업자는 실행마다 방식 표시와 그 방식의 자격 파일을 함께 읽고 그 자격 하나만 실행 env에 넣는다. 표시가 없으면 구독이다. 표시와 자격이 맞지 않으면(예: 표시는 `api`인데 API 키 자리가 비었다) 실행하지 않는다. 안 쓰는 방식의 작업자 키는 지우지 않고 값 `unset`으로 둔다. ExternalSecret은 키가 Infisical에 있어야 Ready라서다. `homelab bot account use`가 이 값을 쓴다. 손으로 고치지 않는다.

VM `homelab-dev`에는 실제 토큰을 넣지 않는다([bootstrap.md](bootstrap.md) 2.2 vm 1단계). 셋 다 `--apply` 없이 먼저 돌려 계획을 본다.

1. drain한다(유출이 의심되거나 실행 중인 일을 옛 토큰으로 끝내면 안 될 때). `homelab bot emergency-stop --apply`로 새 모델 실행을 막고 `homelab bot status --apply`로 `executionPending=false`인지 본다. `unknown`이 있으면 `homelab bot release <작업 ID> --apply`로 정리부터 한다. 만료 전 교체만이면 drain하지 않아도 된다(이미 돌던 실행은 옛 자격으로 끝난다).
2. 새 토큰을 등록한다. 이 기기에 Claude Code CLI(`claude`)가 있어야 한다.

   ```bash
   homelab bot account add <이름> --apply            # 새 계정
   homelab bot account add <이름> --replace --apply  # 같은 계정의 토큰 교체(만료 전·유출)
   # 대화용·작업용에 따로 받으려면 --separate-tokens(로그인 두 번)
   ```

   `claude setup-token`이 한 번 뜬다. 봇 계정으로 브라우저 로그인을 하면 CLI가 화면에서 토큰을 받아 대화용·작업용 두 자리에 쓴다. 화면에는 토큰 대신 `[토큰을 받아 화면에서 가렸다]`가 보인다. 토큰을 받은 뒤에는 "토큰 저장 중(Infisical)", "봇 DB에 계정 기록 중"이 한 줄씩 보인다. claude 화면 꼴이 바뀌어 값을 확신하지 못하면 토큰을 가린 채 받지 않고 가려진 입력을 띄운다. 그때는 다른 터미널에서 `claude setup-token`을 실행해 나온 토큰을 붙여 넣고 그 터미널 스크롤을 지운다. 가린 토큰은 저장되지 않았으니 Claude 설정에서 철회한다. 화면에 토큰 꼴(`sk-ant-`)이 아예 없으면 가리지 않으므로, 보이는 토큰을 붙여 넣고 스크롤을 지운다. `--separate-tokens`면 자리마다(대화용 다음 작업용) 로그인하고, 두 토큰이 같으면 거부한다. 값은 Infisical 요청 본문으로만 가고 CLI 출력·argv·파일에 남지 않는다. 끝나면 봇 DB에 이름·방식·발급일이 적히고, 화면에는 요약 몇 줄과 다음 명령이 보인다(전체 단계 표는 `--verbose`).
3. 바꾸고 반영을 확인한다.

   ```bash
   homelab bot account use <이름> --apply
   homelab bot account list --apply                  # 지금 계정, 토큰 만료일, 멈춘 작업 수
   ```

   CLI가 먼저 두 작업자 ExternalSecret이 구독 토큰을 옮기는지 보고(아니면 아무것도 쓰지 않는다) → 두 값을 작업자 키로 옮기고(둘 다 쓴 뒤에만 다음) → 방식 표시를 `subscription`으로 쓰고 → 두 ExternalSecret을 즉시 동기화하고 → Secret 해시가 계정 값과 같아지는지 보고 → 작업자 두 파드의 자격 파일 지문(`sha256sum` 앞 12자)이 같아질 때까지 기다린 뒤(kubelet 볼륨 갱신, 보통 1분 안팎) → API 키 두 자리를 `unset`으로 쓰고(그 키를 옮기는 Secret이면 다시 동기화해 비워졌는지 본다) → 봇의 지금 계정을 바꾸고 모델 멈춤 작업(결제 멈춤 포함)을 해제한다. 앞 단계가 실패하면 해제하지 않는다. 같은 명령을 다시 치면 된 단계는 건너뛰고 이어 간다. `worker-task`의 `kubectl exec`는 정리 sweep에 죽을 수 있어 CLI가 기한 안에서 다시 본다. 대화용·작업용이 같은 토큰이어도 확인은 같다. 터미널에서는 기다리는 동안 무엇을 기다리는지 한 줄씩 보이고, 끝나면 지금 계정·반영 확인·해제 건수 몇 줄이 보인다(전체 단계 표는 `--verbose`). 그다음 승인된 최소 호출 하나로 새 토큰을 확인한다. 파드 Ready는 토큰 모양만 보므로 Ready만으로는 새 토큰이 유효한지 모른다.
4. 1단계에서 drain했으면 푼다: `homelab bot resume emergency-stop --apply` 뒤 `homelab bot account use <이름> --apply`를 한 번 더 친다. 비상 정지 중에는 3단계가 지금 계정만 바꾸고 멈춘 일 해제를 미뤘기 때문이다(결과의 `비상 정지 중이라 … 해제하지 않았다`).
5. 옛 토큰을 철회한다(Claude Settings → Claude Code의 토큰 삭제). 토큰 하나만 철회할 수 있는지는 [미확인]이다. 사람이 확인해 이 줄을 고친다. 기본(토큰 하나를 함께 씀)이면 철회 한 번이 대화용·작업용을 함께 끊는다. `--replace`가 계정 폴더의 옛 값을 덮었으므로 `_PREVIOUS` 키는 두지 않는다. 샌 것이 의심되면 2단계 전에 철회부터 한다.
6. 복구 자산의 내보내기를 새로 뜬다([recovery-assets.md](recovery-assets.md)). 옛 내보내기는 철회된 토큰을 담는다. 계정 폴더 `/bot-accounts`는 손 Secret 지도에 없다. 재해 복구 뒤 다른 계정으로 바꾸려면 그 계정을 2단계부터 다시 등록한다.

새 토큰이 틀리면 작업은 `auth_expired` 대기로 남는다. 맞는 값으로 2단계부터 다시 하면 3단계의 해제가 이어 준다. CLI 없이 손으로 할 때의 확인 명령(해시만 본다):

```bash
SECRET=worker-task-credential-claude-subscription   # 대화+리뷰면 worker-credential-claude-subscription
DEPLOY=worker-task                                  # 대화+리뷰면 worker
kubectl -n sandbox annotate externalsecret "$SECRET" force-sync="$(date +%s)" --overwrite
kubectl -n sandbox get secret "$SECRET" -o jsonpath='{.data.CLAUDE_CODE_OAUTH_TOKEN}' | base64 -d | sha256sum | cut -c1-12
kubectl -n sandbox exec "deploy/$DEPLOY" -c worker -- sha256sum /run/worker-credential/CLAUDE_CODE_OAUTH_TOKEN | cut -c1-12
# 방식 표시는 비밀이 아니다. 파일이 없으면(sandbox가 아직 옮기지 않음) 구독이다.
kubectl -n sandbox exec "deploy/$DEPLOY" -c worker -- cat /run/worker-credential/CLAUDE_AUTH_METHOD
```

### API 크레딧 방식 (C23)

구독 한도에 걸렸을 때 같은 모델(Opus 5.5)을 Claude Console의 API 크레딧으로 이어 쓰는 방식이다. 봇 DECISIONS "동료 봇 전환" 8과 "C23 API 크레딧 방식"이 근거다. 크레딧 잔액은 봇·CLI가 보이지 않는다(Console에서 본다).

**전제(한 번).** 작업자 Secret이 API 키와 방식 표시를 옮겨야 한다(sandbox ExternalSecret에 키 이름을 더하는 배포 PR, C23 할 일 6). 그 PR을 병합하기 전에 Infisical `/apps/homelab-bot/worker`에 `CLAUDE_AUTH_METHOD`·`ANTHROPIC_API_KEY`·`ANTHROPIC_API_KEY_TASK` 키가 있어야 한다. 없으면 ExternalSecret이 Degraded라 root가 sandbox wave에서 멈춘다. 지금 계정으로 `homelab bot account use <지금 계정> --apply`를 한 번 치면 세 키가 생긴다(방식 표시 `subscription`, API 키 두 자리 `unset`). 배포 PR 전에는 `use --by api`가 plan에서부터 "ExternalSecret이 API 키·방식 표시를 옮기지 않는다"로 실패하고 아무것도 쓰지 않는다(쓰면 다음 동기화가 구독 토큰 자리의 `unset`만 Secret에 들여 지금 작업자의 인증이 깨진다).

**권장 Console 설정(사람).** 봇 전용 workspace를 만들고 그 안에서만 키를 만든다. 자동 충전(auto-reload)은 끈다. 그러면 키가 새도 피해가 그 workspace에 남은 그달 크레딧까지다. 기본은 키 하나를 대화용·작업용에 함께 쓴다. 작업 파드에서 샌 키로 대화용까지 잃지 않게 하려면 키를 자리마다 따로 만들고 `--separate-tokens`로 등록한다. 따로 만들면 키 이름에 자리(대화용·작업용)를 적어 철회할 때 고르기 쉽게 한다. workspace·키 이름은 저장소에 적지 않는다(D-23).

1. 등록한다. `claude`는 필요 없다.

   ```bash
   homelab bot account add <이름> --by api --apply            # 새 계정의 API 키
   homelab bot account add <이름> --by api --replace --apply  # 같은 계정의 키 교체(유출·정기 교체)
   # 대화용·작업용에 다른 키를 넣으려면 --separate-tokens
   ```

   Console API 키를 가려진 입력에 한 번 붙여 넣는다(대화용·작업용에 함께 쓴다). 파이프면 stdin 한 줄이다. `--separate-tokens`면 자리마다(대화용 다음 작업용) 붙여 넣고(파이프면 두 줄), 두 값이 같으면 거부한다. 값은 `/bot-accounts/<이름>`의 `ANTHROPIC_API_KEY`·`ANTHROPIC_API_KEY_TASK`에만 가고 출력·argv·파일에 남지 않는다. 봇 DB에는 이름과 방식(api)만 적힌다(발급일·만료일 없음).
2. 바꾼다.

   ```bash
   homelab bot account use <이름> --by api --apply
   ```

   CLI는 먼저 두 작업자 ExternalSecret이 대화용·작업용 API 키와 방식 표시를 옮기는지 본다(전제의 배포 PR). 그다음 순서: API 키 둘 → 방식 표시 `api` → 두 ExternalSecret 즉시 동기화 → Secret의 `ANTHROPIC_API_KEY` 해시와 방식 표시 확인 → 작업자 두 파드의 `ANTHROPIC_API_KEY` 지문과 방식 표시 확인 → 그 뒤에만 구독 토큰 두 자리 `unset`과 다시 동기화 → 봇의 지금 계정·방식을 바꾸고 모델 멈춤 작업(결제 멈춤 포함)을 해제. 확인과 비우기 사이에는 Secret에 두 방식 자격이 함께 보이지만 작업자는 방식 표시의 자격만 쓴다. 옛 자격을 먼저 비우지 않으므로 어느 단계에서 멈춰도 작업자에 쓸 자격이 남는다. 다 끝나면 작업자 키에 자격이 하나뿐이다. 구독 계정의 토큰은 계정 폴더 `/bot-accounts/<이름>`에 그대로 남는다.
3. 구독으로 돌아간다: `homelab bot account use <이름> --apply`(방식 생략 = 구독). 순서는 같은 꼴이다: 구독 토큰 둘 → 방식 표시 `subscription` → 동기화·Secret·파드 반영 확인 → 그 뒤에만 API 키 두 자리 `unset`.
4. 크레딧이 떨어지면 작업자가 결제 멈춤으로 닫고 저절로 재개하지 않는다. 운영 알림(`HomelabBotModelPausedBilling`)이 온다. Console에서 크레딧을 채운 뒤 `homelab bot account use <이름> --by api --apply`로 같은 계정을 다시 고르면 해제만 다시 한다. 또는 3단계로 구독으로 돌아간다. API 방식에서는 분당 한도(429)도 결제 멈춤으로 닫는다(지출 상한과 구별하지 못해서다).
5. 키를 철회한다. Console에서 그 workspace의 키를 끈다(Disable·Delete). 샌 것이 의심되면 먼저 철회하고, 그 키를 쓰던 중이면 1·2단계로 새 키를 넣거나 3단계로 구독으로 돌아간다. 철회한 키가 지금 키면 그동안 실행은 인증 실패로 멈춘다(`auth_expired`, 30분마다 다시 본다). `--replace`가 계정 폴더의 옛 값을 덮으므로 `_PREVIOUS` 키는 두지 않는다.
6. 바꾼 뒤 복구 자산 내보내기를 새로 뜬다(3e 6단계와 같다). [approvals.md](../plans/2026-10-17-homelab-rebuild/approvals.md)에 줄을 남긴다(키 값·workspace 이름 없이).

## 3f. R08 연결 폐기와 기기 분실 (T18)

연결 폐기와 tailnet 기기 철회는 서로를 대신하지 않는다. 연결을 폐기해도 그 기기는 tailnet에 남고, 기기를 철회해도 연결의 개인키는 서버에서 유효하다. 기기를 잃으면 둘 다 한다. 경로와 켜는 순서는 설계 C.8 "R08 수신 경로"다.

1. 봇 연결을 해제한다. 다른 기기의 Discord에서 owner가 봇의 R08 연결 해제 명령(이름은 봇 저장소 `docs/ai-bot/ARCHITECTURE.md` R08 절)을 그 기기의 연결마다 실행한다. 해제하면 수신과 미게시 알림이 막힌다. 목록 명령으로 남은 연결이 없는지 본다.
2. 기기를 잃었으면 Tailscale 관리 콘솔에서 그 기기를 제거한다. 그 기기에 있던 SSH 키는 별도로 회수한다(설계 C.3.5 "남는 위험").
3. 남은 owner 기기에서 수신 경로가 그대로인지 본다. 서명 없는 요청이 거절 응답이면 경로는 살아 있다. 응답을 받지 못하면 ACL과 Ingress를 본다. 주소는 실행 때 넣고 저장소에 적지 않는다.

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' -X POST "https://task-events.<tailnet>.ts.net/external-task-events"
   ```

4. 경로 전체를 닫아야 하면 `platform/root/values-prod.yaml`의 `cluster.r08.enabled`를 `false`로 하고 `apps/homelab-bot/values.yaml`의 `EXTERNAL_TASK_EVENTS_ENABLED`를 `"false"`로, `EXTERNAL_TASK_ENVIRONMENT`를 지우는 PR을 낸다. 스위치 줄은 지우지 않는다. `env`에 `EXTERNAL_TASK_*` 줄이 하나도 없으면 `homelab db restore`가 복원 세대를 올리지 않아, 다시 켤 때 폐기한 연결이 되살아난다. 끄면 해제 명령도 사라지므로 1단계를 먼저 한다. ACL은 프록시 기기가 사라진 뒤에 고친다.
5. [approvals.md](../plans/2026-10-17-homelab-rebuild/approvals.md)에 줄을 남긴다. 기기 이름·tailnet 이름은 저장소에 적지 않는다.

봇 DB를 복원하면 복원 시점 뒤의 해제가 되돌아간다. 봇은 복원을 감지하면 활성 연결을 모두 닫는데, 한 앱 복원(pg_dump)은 `EXTERNAL_TASK_RESTORE_EPOCH`가 바뀌어야 감지한다. `homelab db restore`의 재개 PR이 이 값을 함께 올리고, CLI 없이 복원하면 직접 올린다([restore.md](restore.md) 2.1 "R08 복원 세대"). 그 복원 뒤에는 활성 연결이 모두 닫혀 있으니 기기마다 다시 연결한다.

## 3g. Cloudflare Tunnel 토큰

**이 절은 아직 운영에서 돌려 보지 않았다.** 2026-11-14에 공식 문서와 저장소 선언을 읽고 쓴 순서다. 처음 회전할 때 다르게 한 것이 있으면 이 절을 먼저 고친다. 두 절(3g, 3h)을 처음 해 본다면 되돌릴 수 있는 3h를 먼저 한다.

**순서 요약**

1. 지금 상태를 적어 둔다(파드, 연결 수, Secret 해시).
2. Cloudflare에서 토큰을 회전한다. **이 순간 옛 토큰으로는 새 연결을 만들 수 없다. 되돌릴 수 없다.**
3. Infisical의 `TUNNEL_TOKEN`을 새 값으로 바꾸고 동기화한 뒤 해시를 견준다.
4. cloudflared를 다시 띄우고 새 파드의 에지 연결을 확인한다.
5. 공개 경로를 확인하고 `_PREVIOUS`를 지운다.

**자격이 가는 길.** 원본은 Infisical `homelab`/`prod`의 `/platform/cloudflared/TUNNEL_TOKEN`이다. ExternalSecret `cloudflared/cloudflared-tunnel`이 Secret `cloudflared-tunnel`의 `token`으로 옮기고, Deployment `cloudflared`가 환경변수 `TUNNEL_TOKEN`으로 받는다(`platform/cloudflared/templates/`). 환경변수라 파드를 다시 띄워야 바뀐다. Terraform(`infra/cloudflare`)은 터널을 만들고 토큰을 읽기만 한다. 이 회전은 터널을 다시 만드는 일도, Terraform의 Cloudflare API 토큰을 바꾸는 일도 아니다.

**알아 둘 것**

- Cloudflare에서 회전하면 옛 토큰은 새 연결에 쓸 수 없고, 이미 붙은 커넥터는 유지된다([Tunnel tokens](https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/)). 그래서 다른 절과 달리 "새 값을 확인한 뒤 옛 값을 철회"하는 순서가 아니다. `_PREVIOUS`에 둔 옛 값은 되돌릴 수단이 못 된다.
- Deployment는 파드 하나에 `maxSurge: 1`, `maxUnavailable: 0`이고 준비 확인이 에지 연결을 본다. 새 파드가 붙은 뒤에 옛 파드가 내려간다. 새 토큰이 틀리면 새 파드가 준비되지 못해 옛 파드가 남는다. 2단계와 4단계 사이에 옛 파드가 재시작하면 새 토큰이 들어갈 때까지 공개 경로가 끊긴다. 그 사이를 짧게 한다.
- 3단계의 `infisical run`은 [infra/README.md](../../infra/README.md) 2절의 백업 폴더 준비(쓰기 불가 확인)를 한 셸에서 한다. 로그인 사용자로 돌리면 CLI가 가져온 값을 `~/.infisical/secrets-backup/`에 파일로 남기기 때문이다. 끝난 뒤 그 절의 `backup_files`가 0인지 본다.
- cloudflared를 다시 띄우면 다시 붙는 몇 초 동안 공개 URL이 끊긴다([bootstrap.md](bootstrap.md)의 "적용 뒤 확인"). 공식 절차는 커넥터를 둘 이상 두고 하나씩 바꾸며 10분을 기다리는데, 이 배포는 파드가 하나라 그 조건이 없다.

```bash
export KUBECONFIG=~/.kube/homelab.yaml
h() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d | sha256sum | cut -c1-12; }   # 값 대신 해시 앞부분
kubectl -n cloudflared get pods -l app=cloudflared -o wide    # 전: 파드 이름과 시작 시각
h cloudflared cloudflared-tunnel token                         # 전
```

1. **준비.** kubeconfig, Cloudflare의 터널, Infisical 프로젝트가 같은 클러스터(운영)를 가리키는지 본다. 운영 토큰을 VM에 넣지 않는다. Infisical에서 지금 값을 `TUNNEL_TOKEN_PREVIOUS`로 옮겨 둔다(유출 조사용 기록이다. 회전 뒤에는 쓸 수 없다).
2. **회전.** Cloudflare 대시보드의 터널 화면에서 토큰을 회전하고 새 토큰을 받는다. 공식 문서가 메뉴 이름을 두 가지로 적는다(Networking → Tunnels → 터널 → **Rotate token**, 또는 터널 Overview의 **Refresh token**). **[미확인] 지금 화면의 이름은 관리자가 본다.** 화면이 보여 주는 설치 명령은 실행하지 않고 토큰만 가져온다. 클립보드와 마스킹 입력은 [infra/README.md](../../infra/README.md) 5절을 따른다. 회전 직후의 `tf cloudflare output -raw tunnel_token`은 state에 남은 옛 값일 수 있으니 새 토큰의 출처로 쓰지 않는다(state의 출력은 다음 apply나 refresh 때 바뀐다. Terraform의 일반 동작이고 여기서 돌려 보지는 않았다).
3. **Infisical과 동기화.** Infisical UI에서 `/platform/cloudflared/TUNNEL_TOKEN`을 새 값으로 바꾼다. CLI의 `secrets set KEY=VALUE`는 값이 명령행 인자라 쓰지 않는다.

   ```bash
   kubectl -n cloudflared annotate externalsecret cloudflared-tunnel force-sync="$(date +%s)" --overwrite
   kubectl -n cloudflared get externalsecret cloudflared-tunnel      # SecretSynced
   h cloudflared cloudflared-tunnel token                             # 전과 다름
   # 원본의 해시 앞부분. 위와 같아야 한다. HOMELAB_PROJECT_ID는 homelab 프로젝트의 ID다(저장소 밖). 돌려 보지 않은 명령이다
   # 먼저 infra/README.md 2절의 백업 폴더 준비를 이 셸에서 한다(위 "알아 둘 것")
   infisical run --silent --log-level=error --projectId="$HOMELAB_PROJECT_ID" --env=prod --path=/platform/cloudflared -- \
     bash -c 'printf %s "$TUNNEL_TOKEN" | sha256sum | cut -c1-12'
   ```

   동기화가 실패하면 여기서 멈춘다. 옛 파드를 건드리지 않고 Infisical 값과 ESO 경로를 고친다. 해시가 같아도 토큰 자체가 맞는지는 다음 단계의 연결이 말해 준다.
4. **다시 띄우기.**

   ```bash
   kubectl -n cloudflared rollout restart deployment/cloudflared
   kubectl -n cloudflared rollout status deployment/cloudflared --timeout=180s
   kubectl -n cloudflared get pods -l app=cloudflared -o wide     # 새 파드 하나만, Ready
   ```

   새 파드의 로그에 `Registered tunnel connection`이 있는지, 지표 `cloudflared_tunnel_ha_connections`가 1 이상이고 `up{job="cloudflared"}`가 1인지 본다. 시간 초과는 성공이 아니다. 새 파드가 준비되지 못하면 옛 파드가 남아 서비스는 이어진다. 그 상태에서 3단계의 값을 다시 본다. `rollout undo`는 Secret을 되돌리지 않고 옛 토큰을 되살리지도 않는다.
5. **확인과 정리.** 공개 경로 하나의 응답이 회전 전과 같은지 본다([bootstrap.md](bootstrap.md)의 공개 URL 줄. 봇이 꺼져 있는 동안에는 그 줄의 기대 응답이 나오지 않으니, 회전 전에 같은 요청의 응답을 적어 두고 견준다). `CloudflaredTunnelDown`이 울리지 않는지 본다. Cloudflare의 터널 화면에 옛 커넥터가 남지 않았는지 본다. `TUNNEL_TOKEN_PREVIOUS`를 지우고, 복구 자산 내보내기를 갱신하고([recovery-assets.md](recovery-assets.md)), [approvals.md](../plans/2026-10-17-homelab-rebuild/approvals.md)에 줄을 남긴다.

**도중에 실패하면.** 2단계 전에는 그냥 멈추면 된다. 2단계 뒤에는 옛 토큰을 되살릴 수 없다. 살아 있는 옛 파드를 그대로 두고 3~4단계를 바로잡는다. 토큰을 다시 회전하면 방금 받은 새 토큰도 무효가 되므로, 다시 회전하는 것으로 복구하려 하지 않는다. 옛 연결까지 끊겼다면 새 토큰이 붙을 때까지 터널을 거치는 공개 서비스가 멈춘다. 터널을 거치지 않는 tailnet 경로는 이 토큰을 쓰지 않는다.

**유출이 의심되면.** 순서가 다르다. 바로 회전하고, 이미 붙은 연결을 모두 끊는다(공식 문서의 터널 연결 삭제 API. 관리자가 실행하는 파괴 작업이다). 새 토큰이 붙을 때까지 끊긴다. 연결을 끊지 않으면 훔친 토큰으로 붙어 있는 커넥터가 남는다([유출 대응](https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/#rotate-a-token)).

## 3h. R2 백업 키

**이 절은 아직 운영에서 돌려 보지 않았다.** 2026-11-14에 공식 문서, 저장소 선언, Barman Cloud Plugin v0.15.1의 소스를 읽고 쓴 순서다. 처음 회전할 때 다르게 한 것이 있으면 이 절을 먼저 고친다.

**순서 요약**

1. 이 키를 쓰는 곳을 모두 찾고, 진행 중인 백업이 없는 때를 고른다.
2. Cloudflare에서 새 R2 토큰을 만든다. 옛 토큰은 그대로 둔다.
3. Infisical의 키 쌍을 새 값으로 바꾸고 동기화한 뒤 해시를 견준다.
4. 새 키로 백업 하나와 WAL 아카이브가 성공하는지 본다.
5. 옛 토큰을 철회하고, 그 뒤에도 백업과 WAL이 성공하는지와 옛 키가 거절되는지 본다.

5단계 전까지는 옛 키 쌍으로 되돌릴 수 있다.

**자격이 가는 길.** 원본은 Infisical `homelab`/`prod`의 `/platform/backup`에 있는 `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`다. ExternalSecret `database/r2-backup`이 Secret `r2-backup`의 `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `ENDPOINT_URL`로 옮긴다(`platform/cnpg/cluster/templates/externalsecret.yaml`). 영속 Valkey를 쓰는 앱이 있으면 `<앱>-valkey-backup-r2`도 같은 원본을 읽는다(`platform/charts/app-data/templates/valkey.yaml`). Terraform은 버킷만 선언하고 이 토큰은 만들지 않는다. Terraform state 버킷의 키(`/terraform/state`)와 Cloudflare API 토큰(`/terraform/cloudflare`)은 다른 자격이다. 이 절에서 건드리지 않는다.

**알아 둘 것**

- 키 쌍만 바꾸면 PostgreSQL을 다시 띄우지 않아도 된다는 것이 소스를 읽은 판단이다. Plugin v0.15.1은 WAL 작업과 base backup마다 Secret에서 자격을 읽고 약 10초 기억한다. 초 단위로 견줘서 11초까지 옛 값이 남을 수 있다([wal.go](https://github.com/cloudnative-pg/plugin-barman-cloud/blob/v0.15.1/internal/cnpgi/common/wal.go#L126), [client.go](https://github.com/cloudnative-pg/plugin-barman-cloud/blob/v0.15.1/internal/cnpgi/instance/internal/client/client.go#L36)). 공식 문서에는 회전 때 재시작이 필요한지가 적혀 있지 않다. 다른 plugin 버전에는 이 판단을 옮기지 않는다.
- `R2_ENDPOINT`는 바꾸지 않는다. endpoint는 환경변수로 들어가서 바꾸면 파드를 다시 만들어야 하고, Cluster `pg`는 인스턴스가 하나라 DB가 끊긴다. endpoint나 버킷을 바꾸는 일은 따로 한다.
- 두 키의 저장과 ESO 동기화는 한 번에 일어나지 않는다. 한 키만 바뀐 채 동기화되면 백업과 WAL이 잠깐 실패한다. 두 키를 연달아 저장하고 곧바로 동기화한다.
- 이미 시작한 백업과 Job은 시작할 때 읽은 키로 끝까지 간다. 그래서 확인하는 때와 철회하는 때를 나눈다.
- 3단계의 `infisical run`은 [infra/README.md](../../infra/README.md) 2절의 백업 폴더 준비(쓰기 불가 확인)를 한 셸에서 한다. 로그인 사용자로 돌리면 CLI가 가져온 값을 `~/.infisical/secrets-backup/`에 파일로 남기기 때문이다. 끝난 뒤 그 절의 `backup_files`가 0인지 본다.

```bash
export KUBECONFIG=~/.kube/homelab.yaml
h() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d | sha256sum | cut -c1-12; }   # 값 대신 해시 앞부분
# 이 키를 읽는 ExternalSecret 전부. database/r2-backup 말고 더 있으면 4단계와 5단계에서 함께 본다
kubectl get externalsecret -A -o json \
  | jq -r '.items[] | select([.spec.data[]?.remoteRef.key] | any(test("R2_ACCESS_KEY_ID"))) | "\(.metadata.namespace)/\(.metadata.name)"'
kubectl -n database get backups     # 진행 중인 백업이 없어야 한다. 정기 base backup은 매일 03:00 KST다
h database r2-backup ACCESS_KEY_ID; h database r2-backup SECRET_ACCESS_KEY     # 전
```

1. **쓰는 곳과 때.** 위 조회로 쓰는 곳을 적는다. 진행 중인 base backup, Valkey 백업 Job, 복원 작업이 있으면 끝난 뒤에 한다. 클러스터 밖에서 같은 키를 쓰는 곳(복원 시험 등)이 있는지는 관리자가 안다.
2. **새 토큰.** Cloudflare 대시보드의 R2 → API Tokens에서 새 토큰을 만든다. 권한은 **Object Read & Write**, 대상은 백업 버킷 하나다. 계정 전체 권한으로 넓히지 않는다. Access Key ID와 Secret Access Key를 한 쌍으로 받는다. Secret Access Key는 다시 볼 수 없다([R2 API tokens](https://developers.cloudflare.com/r2/api/tokens/)). 옛 토큰은 아직 철회하지 않는다.
3. **Infisical과 동기화.** 같은 폴더에 `R2_ACCESS_KEY_ID_PREVIOUS`, `R2_SECRET_ACCESS_KEY_PREVIOUS`로 옛 쌍을 옮겨 두고, 두 키를 연달아 새 값으로 바꾼다. `R2_ENDPOINT`는 그대로 둔다. 그리고 바로 동기화한다.

   ```bash
   kubectl -n database annotate externalsecret r2-backup force-sync="$(date +%s)" --overwrite
   kubectl -n database get externalsecret r2-backup                              # SecretSynced
   h database r2-backup ACCESS_KEY_ID; h database r2-backup SECRET_ACCESS_KEY     # 둘 다 전과 다름
   # 원본의 해시 앞부분. 위 두 값과 차례로 같아야 한다. 돌려 보지 않은 명령이다
   # 먼저 infra/README.md 2절의 백업 폴더 준비를 이 셸에서 한다(위 "알아 둘 것")
   infisical run --silent --log-level=error --projectId="$HOMELAB_PROJECT_ID" --env=prod --path=/platform/backup -- \
     bash -c 'printf %s "$R2_ACCESS_KEY_ID" | sha256sum | cut -c1-12; printf %s "$R2_SECRET_ACCESS_KEY" | sha256sum | cut -c1-12'
   ```

   1단계에서 찾은 다른 ExternalSecret도 같은 방법으로 동기화하고 견준다. 해시가 같아도 키 쌍이 맞는지는 다음 단계가 말해 준다.
4. **새 키로 백업과 WAL.** 3단계에서 두 해시가 원본과 같아진 것을 본 뒤 15초 넘게 기다렸다가 새 백업을 만든다. 그보다 일찍 시작한 백업은 옛 키를 읽었을 수 있다([restore.md](restore.md) 2절의 온디맨드 Backup과 같은 모양이다).

   ```bash
   B=rotate-$(date -u +%Y%m%d%H%M%S)
   kubectl -n database create -f - <<EOF
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata: { name: $B, namespace: database }
   spec: { cluster: { name: pg }, method: plugin, pluginConfiguration: { name: barman-cloud.cloudnative-pg.io } }
   EOF
   kubectl -n database get backup "$B" -o custom-columns='PHASE:.status.phase,STARTED:.status.startedAt,STOPPED:.status.stoppedAt'   # completed
   ```

   그렇게 기다린 뒤 시작한 이 백업이 `completed`면 base backup과 그 끝의 WAL이 새 키로 올라간 것이다(백업은 시작할 때 읽은 자격을 끝까지 쓰고, `pg_backup_stop`은 끝 WAL이 아카이브될 때까지 기다린다. restore.md 2절). 지표로도 본다: `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`가 앞으로 가고, `cnpg_pg_stat_archiver_last_archived_time`이 `cnpg_pg_stat_archiver_last_failed_time`보다 뒤다. 3단계 전에 시작한 백업이 끝난 것은 새 키의 확인이 아니다. Valkey 쪽이 있으면 새로 시작한 백업 Job의 성공을 본다.

   실패하면 5단계로 가지 않는다. 옛 쌍(`_PREVIOUS`)을 두 키에 함께 되돌리고 동기화한 뒤 백업 하나로 복구를 확인한다. 한 키만 되돌리지 않는다.
5. **옛 토큰 철회.** 4단계가 끝나고, 옛 키로 시작한 작업이 남지 않았을 때 Cloudflare에서 옛 토큰을 지운다. **[미확인] 지금 화면에서 토큰을 지우는 자리는 관리자가 본다.** 버킷이나 객체를 지우는 일이 아니다. 지운 뒤 두 가지를 본다. 첫째, 4단계의 백업을 한 번 더 만들어 `completed`를 보고 `PGBackupStale`과 `WALArchiveFailing`이 울리지 않는지 본다. 둘째, 옛 키가 정말 거절되는지 본다. 새 키가 되는 것은 옛 키가 죽었다는 증거가 아니다. 옛 키 쌍(`_PREVIOUS`)으로 백업 버킷에 읽기 요청 하나를 보내 인증 거부(HTTP 401이나 403, `InvalidAccessKeyId`·`AccessDenied` 같은 응답)가 오는지 본다. 객체 없음(404)이나 연결 실패는 거부가 아니다. **[미확인] 값을 화면에 내지 않고 이 요청을 보낼 도구는 관리자가 정한다**(이 저장소가 고정한 S3 도구는 없다). 거부를 확인하지 못했으면 `_PREVIOUS`를 지우지 않고 "철회 확인 미완료"로 적는다. 거부를 확인한 뒤에 `_PREVIOUS` 두 키를 지우고, 복구 자산 내보내기를 갱신하고, [approvals.md](../plans/2026-10-17-homelab-rebuild/approvals.md)에 줄을 남긴다.

**도중에 실패하면.** 철회 전이면 옛 쌍을 되돌린다(4단계 끝의 방법). 철회한 뒤에는 옛 키를 되살릴 수 없으니 새 토큰을 다시 만들어 3단계부터 한다. 키가 틀린 채로 두면 WAL이 아카이브되지 못하고 쌓여 루트 디스크를 채운다. 백업을 거듭 만들어 밀어붙이지 말고 맞는 키부터 되돌린다.

**유출이 의심되면.** 옛 토큰을 먼저 철회하고 새 키를 넣는다. 새 키가 들어갈 때까지 백업과 WAL 아카이브가 멈춘다. 유출된 키는 되돌릴 값으로 쓰지 않는다.

## 4. 아직 채우지 않은 절

설계 C.6.5 표의 순서를 따른다. 자격을 만드는 티켓이 이 문서에 절을 더한다.

| 자격 | 채우는 티켓 |
|---|---|
| 플랫폼 토큰(Tailscale operator OAuth, Telegram 봇, healthchecks ping URL), Grafana·AdGuard 관리자 | T08a, T08b |
| Terraform 자격(`homelab-admin`의 R2 state 키, Cloudflare 토큰, Tailscale OAuth) | T08a |
