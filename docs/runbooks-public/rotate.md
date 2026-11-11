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
- 필수 키가 빠지면 ExternalSecret이 `SecretSyncedError`로 멈추고 Secret은 바뀌지 않는다. 잘못된 값이 적용되지 않는다(시나리오 6).

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

## 3e. 봇 작업자 모델 자격 (레인별, 구독·API 크레딧, T18 · CLI C22·C23)

방식이 둘이다. 구독은 Claude 구독 장기 토큰(`claude setup-token`, 발급 뒤 1년 만료), API 크레딧은 Claude Console API 키다(아래 "API 크레딧 방식"). 레인마다 따로다. 개인 `~/.claude*`를 복사하지 않는다. 봇은 스스로 다른 계정·방식으로 바꾸지 않고, 바꾸는 것은 owner가 `homelab bot account`로만 한다(봇 DECISIONS D-14 조건 5). 구독 토큰은 만료 30일 전부터 봇 브리핑이 계정 이름과 남은 날수를 알린다.

자격 값은 계정마다 Infisical `/bot-accounts/<이름>`에 두고(작업자가 읽지 않는 폴더), `homelab bot account use`가 지금 쓸 계정·방식의 값을 작업자 키로 옮긴다. 같은 계정의 값 교체도 같은 절차다(`add --replace` → `use`).

| 레인 | 방식 | 계정 폴더 `/bot-accounts/<이름>` | 작업자 키 `/apps/homelab-bot/worker` | Secret 키(파일 이름) | Secret · 파드 |
|---|---|---|---|---|---|
| 대화+리뷰 | 구독 | `CLAUDE_CODE_OAUTH_TOKEN` | `CLAUDE_CODE_OAUTH_TOKEN` | `CLAUDE_CODE_OAUTH_TOKEN` | `sandbox/worker-credential-claude-subscription` · `worker` |
| 대화+리뷰 | API 크레딧 | `ANTHROPIC_API_KEY` | `ANTHROPIC_API_KEY` | `ANTHROPIC_API_KEY` | 같음 |
| 작업 | 구독 | `CLAUDE_CODE_OAUTH_TOKEN_TASK` | `CLAUDE_CODE_OAUTH_TOKEN_TASK` | `CLAUDE_CODE_OAUTH_TOKEN` | `sandbox/worker-task-credential-claude-subscription` · `worker-task` |
| 작업 | API 크레딧 | `ANTHROPIC_API_KEY_TASK` | `ANTHROPIC_API_KEY_TASK` | `ANTHROPIC_API_KEY` | 같음 |
| 둘 다 | 방식 표시 | 없음 | `CLAUDE_AUTH_METHOD`(`subscription` 또는 `api`) | `CLAUDE_AUTH_METHOD` | 두 Secret 모두 |

작업자는 실행마다 방식 표시와 그 방식의 자격 파일을 함께 읽고 그 자격 하나만 실행 env에 넣는다. 표시가 없으면 구독이다. 표시와 자격이 맞지 않으면(예: 표시는 `api`인데 API 키 자리가 비었다) 실행하지 않는다. 안 쓰는 방식의 작업자 키는 지우지 않고 값 `unset`으로 둔다. ExternalSecret은 키가 Infisical에 있어야 Ready라서다. `homelab bot account use`가 이 값을 쓴다. 손으로 고치지 않는다.

VM `homelab-dev`에는 실제 토큰을 넣지 않는다([bootstrap.md](bootstrap.md) 2.2 vm 1단계). 셋 다 `--apply` 없이 먼저 돌려 계획을 본다.

1. drain한다(유출이 의심되거나 실행 중인 일을 옛 토큰으로 끝내면 안 될 때). `homelab bot emergency-stop --apply`로 새 모델 실행을 막고 `homelab bot status --apply`로 `executionPending=false`인지 본다. `unknown`이 있으면 `homelab bot release <작업 ID> --apply`로 정리부터 한다. 만료 전 교체만이면 drain하지 않아도 된다(이미 돌던 실행은 옛 자격으로 끝난다).
2. 새 토큰을 등록한다. 이 기기에 Claude Code CLI(`claude`)가 있어야 한다.

   ```bash
   homelab bot account add <이름> --apply            # 새 계정
   homelab bot account add <이름> --replace --apply  # 같은 계정의 토큰 교체(만료 전·유출)
   ```

   레인마다 `claude setup-token`이 뜬다. 봇 계정으로 브라우저 로그인을 하고, 화면에 나온 토큰을 에코 없는 입력에 붙여 넣는다(두 번, 대화·리뷰 다음 작업). 두 값이 같으면 거부한다. 값은 Infisical 요청 본문으로만 가고 CLI 출력·argv·파일에 남지 않는다. 다만 `claude setup-token`이 토큰을 터미널에 한 번 출력하므로 붙여 넣은 뒤 터미널 스크롤을 지운다. 끝나면 봇 DB에 이름·방식·발급일이 적힌다.
3. 바꾸고 반영을 확인한다.

   ```bash
   homelab bot account use <이름> --apply
   homelab bot account list --apply                  # 지금 계정, 토큰 만료일, 멈춘 작업 수
   ```

   CLI가 먼저 두 작업자 ExternalSecret이 구독 토큰을 옮기는지 보고(아니면 아무것도 쓰지 않는다) → 두 값을 작업자 키로 옮기고(둘 다 쓴 뒤에만 다음) → 방식 표시를 `subscription`으로 쓰고 → 두 ExternalSecret을 즉시 동기화하고 → Secret 해시가 계정 값과 같아지는지 보고 → 작업자 두 파드의 자격 파일 지문(`sha256sum` 앞 12자)이 같아질 때까지 기다린 뒤(kubelet 볼륨 갱신, 보통 1분 안팎) → API 키 두 자리를 `unset`으로 쓰고(그 키를 옮기는 Secret이면 다시 동기화해 비워졌는지 본다) → 봇의 지금 계정을 바꾸고 모델 멈춤 작업(결제 멈춤 포함)을 해제한다. 앞 단계가 실패하면 해제하지 않는다. 같은 명령을 다시 치면 된 단계는 건너뛰고 이어 간다. `worker-task`의 `kubectl exec`는 정리 sweep에 죽을 수 있어 CLI가 기한 안에서 다시 본다. 그다음 승인된 최소 호출 하나로 새 토큰을 확인한다. 파드 Ready는 토큰 모양만 보므로 Ready만으로는 새 토큰이 유효한지 모른다.
4. 1단계에서 drain했으면 푼다: `homelab bot resume emergency-stop --apply` 뒤 `homelab bot account use <이름> --apply`를 한 번 더 친다. 비상 정지 중에는 3단계가 지금 계정만 바꾸고 멈춘 일 해제를 미뤘기 때문이다(결과 줄의 `비상 정지 중이라 해제하지 않았다`).
5. 옛 토큰을 철회한다(Claude Settings → Claude Code의 토큰 삭제). 토큰 하나만 철회할 수 있는지는 [미확인]이다. 작업 레인을 켜기 전에 사람이 확인해 이 줄을 고친다. `--replace`가 계정 폴더의 옛 값을 덮었으므로 `_PREVIOUS` 키는 두지 않는다. 샌 것이 의심되면 2단계 전에 철회부터 한다.
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

**권장 Console 설정(사람).** 봇 전용 workspace를 만들고 그 안에서만 키를 만든다. 자동 충전(auto-reload)은 끈다. 그러면 키가 새도 피해가 그 workspace에 남은 그달 크레딧까지다. 키는 레인마다 따로 만든다(작업 파드에서 샌 키로 대화 레인까지 잃지 않게). 키 이름에는 레인을 적어 철회할 때 고르기 쉽게 한다. workspace·키 이름은 저장소에 적지 않는다(D-23).

1. 등록한다. `claude`는 필요 없다.

   ```bash
   homelab bot account add <이름> --by api --apply            # 새 계정의 API 키
   homelab bot account add <이름> --by api --replace --apply  # 같은 계정의 키 교체(유출·정기 교체)
   ```

   레인마다(대화·리뷰 다음 작업) Console API 키를 에코 없는 입력에 붙여 넣는다. 파이프면 stdin 두 줄이다. 두 값이 같으면 거부한다. 값은 `/bot-accounts/<이름>`의 `ANTHROPIC_API_KEY`·`ANTHROPIC_API_KEY_TASK`에만 가고 출력·argv·파일에 남지 않는다. 봇 DB에는 이름과 방식(api)만 적힌다(발급일·만료일 없음).
2. 바꾼다.

   ```bash
   homelab bot account use <이름> --by api --apply
   ```

   CLI는 먼저 두 작업자 ExternalSecret이 레인별 API 키와 방식 표시를 옮기는지 본다(전제의 배포 PR). 그다음 순서: API 키 둘 → 방식 표시 `api` → 두 ExternalSecret 즉시 동기화 → Secret의 `ANTHROPIC_API_KEY` 해시와 방식 표시 확인 → 작업자 두 파드의 `ANTHROPIC_API_KEY` 지문과 방식 표시 확인 → 그 뒤에만 구독 토큰 두 자리 `unset`과 다시 동기화 → 봇의 지금 계정·방식을 바꾸고 모델 멈춤 작업(결제 멈춤 포함)을 해제. 확인과 비우기 사이에는 Secret에 두 방식 자격이 함께 보이지만 작업자는 방식 표시의 자격만 쓴다. 옛 자격을 먼저 비우지 않으므로 어느 단계에서 멈춰도 작업자에 쓸 자격이 남는다. 다 끝나면 작업자 키에 자격이 하나뿐이다. 구독 계정의 토큰은 계정 폴더 `/bot-accounts/<이름>`에 그대로 남는다.
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

## 4. 아직 채우지 않은 절

설계 C.6.5 표의 순서를 따른다. 자격을 만드는 티켓이 이 문서에 절을 더한다.

| 자격 | 채우는 티켓 |
|---|---|
| 플랫폼 토큰(터널, Tailscale operator OAuth, Telegram 봇, healthchecks ping URL), Grafana·AdGuard 관리자 | T08a, T08b |
| Terraform 자격(`homelab-admin`의 R2 state 키, Cloudflare 토큰, Tailscale OAuth) | T08a |
