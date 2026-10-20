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
   read -r -p 'homelab-merge App client ID: ' APP_CLIENT_ID
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

App Connection은 owner 계정의 fine-grained PAT다(리소스 소유자 `ukyi-app`, 저장소 `homelab`만, Metadata read, Environments RW, Secrets RW, 만료 지정). 만료 전에 바꾼다. 만료되면 Sync가 실패하고 프로젝트 Admin에게 메일이 온다.

1. `tools/tf-github.sh verify` exit 0을 먼저 본다(3절 1번과 같은 이유).
2. 같은 범위로 새 PAT를 발급한다. 다른 저장소나 권한을 더하지 않는다. 더하면 그 PAT가 새는 순간 다른 저장소의 secret도 바뀐다.
3. Infisical App Connection의 토큰을 새 PAT로 바꾸고 Sync를 한 번 다시 실행한다.
4. 3절 4번의 `updated_at`이 Sync 재실행 뒤인지 본다.
5. 옛 PAT를 폐기한다. 폐기 뒤에도 4번이 그대로면 끝이다.

## 4. 아직 채우지 않은 절

설계 C.6.5 표의 순서를 따른다. 자격을 만드는 티켓이 이 문서에 절을 더한다.

| 자격 | 채우는 티켓 |
|---|---|
| 플랫폼 토큰(터널, Tailscale operator OAuth, Telegram 봇, healthchecks ping URL), Grafana·AdGuard 관리자 | T08a, T08b |
| Terraform 자격(`homelab-admin`의 R2 state 키, Cloudflare 토큰, Tailscale OAuth) | T08a |
| DB·Valkey 비밀번호 | T11 |
