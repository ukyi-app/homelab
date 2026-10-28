# 앱 운영: 실패한 배포 되돌리기

앱(`apps/<앱>/`)·데이터(`data/<앱>/`) Application의 배포가 잘못된 values로 실패해 되돌릴 때의 순서다. 근거는 설계 [B.8](../plans/2026-10-17-homelab-rebuild/platform/design.md) E2의 Argo CD 재시도 함정, C.3.3(retry 설정), C.4.9(Argo CD rollback을 쓰지 않는다)다. 이미지만 이전으로 돌리는 것은 `homelab rollback`(설계 C.4.9), 데이터를 되돌리는 것은 [restore.md](restore.md)다.

- 바꾸는 길은 Git뿐이다. 되돌림도 PR이다.
- 외부 변경(병합, Application 패치)은 [approvals.md](../plans/2026-10-17-homelab-rebuild/approvals.md)에 줄로 남긴다.
- 실행하다 이 문서와 다르게 한 것이 있으면 이 문서를 먼저 고친다.

## 1. 잘못된 values로 실패한 배포

### 1.1 되돌림 PR만으로는 바로 고쳐지지 않는 이유

Argo CD v3.5.5 자동 sync는 작업(operation)을 만들 때 그때의 `spec.source`(ApplicationSet이 넣은 `helm.valuesObject`, 차트 태그 `targetRevision` 포함)와 retry 설정을 작업에 복사한다. 재시도는 그 사본(`status.operationState.operation.sync.source`)으로 렌더하고 `spec.source`를 다시 읽지 않는다. 그래서 되돌림 PR이 병합되어 ApplicationSet이 `spec`을 고쳐도, 실패해 재시도 중인 작업은 옛 값으로 계속 실패한다. 고친 값은 그 작업이 끝난 뒤의 새 자동 sync에서 쓰인다. 새 자동 sync는 Application이 `OutOfSync`일 때만 시작한다. 되돌린 목표가 라이브와 이미 같아 `Synced`면 새 작업 없이 끝난다(1.3의 5단계).

- 근거(v3.5.5 소스): 작업 생성 `controller/appcontroller.go:2458-2479`, 재시도 `:1621-1663`, 재시도가 쓰는 source `controller/sync.go:79-92`. v3.2.0에서 들어온 동작이다. v3.1.x는 재시도마다 spec을 다시 읽었다.
- `syncPolicy.retry.refresh: true`는 해법이 아니다. 재시도 전에 revision만 비워 같은 `targetRevision`을 다시 풀고, source 사본(values)은 그대로 둔다(`appcontroller.go:1649-1655`, `controller/state.go:310-313`). 봇 자리는 values가 Git 경로의 파일이라 refresh로 고쳐지지만(설계 C.8), 앱·데이터 Application은 values가 spec 안이라 고쳐지지 않는다.
- 실측(T13 시나리오 6, 2026-10-27): Infisical에 없는 키를 요구한 #945의 작업(04:34:39Z 시작)이 재시도하는 동안 되돌림 #946(04:46:16Z 병합)이 반영되지 않았다. 재시도 10회를 다 쓴 05:17:23Z에 새 작업이 시작되어 05:17:34Z에 Synced가 됐다. 병합부터 약 31분이다.

### 1.2 기다릴지, 끝낼지

| | 기다리기 | 진행 중 작업 끝내기(1.3의 4단계) |
|---|---|---|
| 고친 값 반영 | 재시도를 다 쓴 뒤. `OutOfSync`면 새 자동 sync | 끝낸 직후. `OutOfSync`면 새 자동 sync |
| 걸리는 시간 | 앱·데이터 Application(limit 10, backoff 30s → 최대 5m)의 재시도 대기 합 **42분**(아래). T13 실측은 작업 시작부터 마지막 실패까지 42분 44초, 되돌림 병합부터 반영까지 약 31분 | T13 실측(2026-10-28): 패치 뒤 작업 완료 5초, Synced/Healthy 관측 6초, 되돌림 병합부터 정상 상태 관측까지 36초 |
| 위험 | 운영 쓰기가 없다 | Application status를 직접 고친다(아래 판정·test가 다른 작업을 끝내지 않게 막는다). T13에서 한 번 운영 실측했다 |

재시도 대기 42분은 v3.5.5에서 이렇게 나온다. 실패하면 `retryCount`를 먼저 1 올리고(`controller/appcontroller.go:1704-1715`), 대기할 때 올린 값으로 `30s × 2^retryCount`(최대 5m, factor 기본 2)를 다시 계산한다(`:1632-1646`, `pkg/apis/application/v1alpha1/types.go:1566-1594`, 같은 디렉터리의 `application_defaults.go:5-8`). retryCount 1~10의 대기가 60s+120s+240s+300s×7 = 2520초다.

- 작업 시작부터 센 대기만의 합이다. 시도마다의 실행·health 대기와 컨트롤러 처리 시간은 따로 더해진다. 되돌림 병합부터 남은 시간도, 복구에 걸리는 시간의 상한도 아니다.
- 실패 메시지의 `Retrying attempt #n at <시각>`은 올리기 전 값으로 계산한 시각이라 처음 네 번은 실제보다 이르다. 남은 시간을 그 시각으로 어림하지 않는다.

실패가 뒤 wave 적용 전에 났으면(시나리오 6의 ExternalSecret 실패처럼) 그동안 옛 파드가 그대로 돈다. 그러면 기다려도 된다. 새 파드가 이미 깨졌거나 기다리기가 길면 끝낸다.

### 1.3 순서

0. 대상을 고른다. 앱은 Application `<앱>`, 데이터는 `<앱>-data`다.

   ```bash
   export KUBECONFIG=~/.kube/homelab.yaml
   APP=<앱>   # 데이터 Application이면 <앱>-data
   ```

1. 되돌림 PR을 병합한다. 평소 사람 PR과 같다(ci 성공, owner 검토, `gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`, 설계 C.4.7).

2. ApplicationSet이 `spec`을 바꿨는지 본다. ApplicationSet은 main을 60초마다 읽는다(`requeueAfterSeconds: 60`). 되돌린 키가 고친 값으로 보일 때까지 기다린다. 예: `secrets`를 되돌렸으면

   ```bash
   kubectl -n argocd get application "$APP" -o json | jq '.spec.source.helm.valuesObject.secrets'
   ```

   **고친 값이 보이기 전에 4단계로 가지 않는다.** 그때는 `spec`과 진행 중 작업의 source가 아직 같아 3단계 판정이 맞지 않고, 4단계 명령도 거부한다. 먼저 끝내도 옛 값으로 다시 시작하지는 않는다(같은 source로 실패한 작업은 자동 sync가 다시 하지 않는다, `alreadyAttemptedSync`). 새 작업은 `spec`이 바뀐 뒤에야 생긴다.

3. 진행 중 작업이 옛 source로 도는지 본다.

   ```bash
   kubectl -n argocd get application "$APP" -o json | jq '{
     operation: (.operation != null),
     phase: .status.operationState.phase,
     startedAt: .status.operationState.startedAt,
     finishedAt: .status.operationState.finishedAt,
     retryCount: .status.operationState.retryCount,
     message: .status.operationState.message,
     sameSource: (.spec.source == .status.operationState.operation.sync.source)
   }'
   ```

   | 결과 | 뜻 | 할 일 |
   |---|---|---|
   | `operation: true`, `phase: "Running"`, `sameSource: false`, `finishedAt` 있음 | 옛 source로 실패하고 다음 재시도를 기다리는 중 | 4단계 |
   | 위와 같은데 `finishedAt: null` | 시도가 도는 중 | 끝내지 않는다. 몇 초 뒤 3단계를 다시 본다 |
   | `sameSource: true` | 진행 중 작업이 이미 지금 spec으로 돈다 | 끝내지 않는다. 5단계 |
   | `operation: false`, phase가 `Succeeded`·`Failed`·`Error` | 작업이 끝났다 | 끝내지 않는다. 5단계(새 작업은 `OutOfSync`일 때만 생긴다) |
   | 그 밖 | 이 절이 다루지 않는 상태 | 멈추고 `kubectl -n argocd get application "$APP" -o yaml`의 `status.conditions`·`operationState`를 본다 |

   두 값을 직접 대조하려면 `jq '{spec: .spec.source.helm.valuesObject, running: .status.operationState.operation.sync.source.helm.valuesObject}'`로 본다. values는 공개 저장소의 파일이고 `secrets`는 키 이름뿐이라 출력해도 된다.

4. 진행 중 작업을 끝낸다(T13 운영 실측 2026-10-28, 이 단계 끝).

   공식 길은 `argocd app terminate-op <앱>`(owner 로그인 UI의 Terminate도 같은 서버 호출)이다. 서버는 `status.operationState.phase`를 `Terminating`으로 바꿔 쓰기만 하고, 정리는 컨트롤러가 한다(v3.5.5 `server/application/application.go:2508-2521`, `controller/sync.go:358-362`). 이 저장소는 argocd CLI를 고정 도구(`.tool-versions`)에 두지 않으므로 kubectl로 같은 필드를 쓴다.

   - Application CRD에 status subresource가 없어(`subresources: {}`) 일반 patch가 status를 바꾼다.
   - 권한은 Argo CD RBAC이 아니라 Kubernetes RBAC이다. 운영자 kubeconfig는 `kubectl auth can-i patch applications.argoproj.io -n argocd`가 `yes`다. 봇 계정 `bot-reader`는 할 수 없다.
   - 같은 패치(merge patch)로 2026-10-23 `sandbox`의 멈춘 작업을 끝낸 적이 있다(approvals 01:49 행). 그때는 시도 중 health 대기였고, 재시도 대기 중에 끝낸 것은 T13 실측(2026-10-28)이 처음이다.

   ```bash
   # 한 번 읽은 JSON(SNAP)에서 3단계 표 첫 줄의 조건을 모두 다시 보고, 맞을 때만 그 JSON의 시각으로 패치를 묶는다.
   # 시각만 따로 다시 읽으면 안 된다. 3단계 뒤 옛 작업이 끝나고 고친 source의 새 작업이 재시도 대기에 들어갔으면
   # 그 새 작업을 끝내게 되고, 고친 source로 실패한 작업은 자동 sync가 다시 하지 않는다(alreadyAttemptedSync,
   # appcontroller.go:2485-2500·2596-2600). startedAt이 작업을 가린다(새 작업은 옛 작업이 끝난 뒤에 시작한다).
   # 그사이 다음 시도가 시작됐거나 작업이 끝났거나 다른 작업으로 바뀌었으면 test가 실패하고 아무것도 바뀌지 않는다.
   # 끝난 작업에 Terminating을 쓰면 .operation 없이 진행 중 표시만 남는다(컨트롤러는 .operation이 있을 때만 작업을
   # 처리한다, appcontroller.go:1138-1140). 시도 중에 끝내면 마이그레이션 Job 같은 hook을 중간에 지울 수 있다
   # (Terminate는 hook을 먼저 정리한다, gitops-engine sync_context.go:725-745). 판정과 test가 둘 다 막는다.
   SNAP=$(kubectl -n argocd get application "$APP" -o json)
   STARTED=$(jq -r '.status.operationState.startedAt' <<<"$SNAP")
   PATCH=$(jq -ec '.status.operationState as $s
     | if .operation != null and $s.phase == "Running" and $s.finishedAt != null
          and .spec.source != $s.operation.sync.source
       then [
         {op: "test", path: "/status/operationState/phase", value: "Running"},
         {op: "test", path: "/status/operationState/startedAt", value: $s.startedAt},
         {op: "test", path: "/status/operationState/finishedAt", value: $s.finishedAt},
         {op: "replace", path: "/status/operationState/phase", value: "Terminating"}]
       else error("끝낼 작업이 아니다(3단계 표 첫 줄이 아님). 3단계부터 다시") end' <<<"$SNAP") &&
     kubectl -n argocd patch application "$APP" --type=json -p "$PATCH"
   ```

   `jq`가 거부하면 `&&` 때문에 패치하지 않는다. `test failed`가 나오면 아무것도 바뀌지 않은 것이다. 둘 다 3단계부터 다시 본다.

   판정의 거부(고친 source의 작업, 시도 중, 끝난 작업, spec 반영 전)와 test의 거부(3단계 뒤 고친 source의 새 작업으로 바뀜, 다른 `finishedAt`, 시도 중, 끝난 작업)는 로컬 사본과 `kubectl patch --local`로 확인했다(2026-10-27). 운영 적용(T13, 2026-10-28, `homelab-smoke`): 없는 키를 요구한 작업이 재시도 3회째를 기다릴 때 되돌림 병합 → spec 반영(6초) → 3단계 판정 첫 줄 → 이 블록으로 패치 → 같은 초에 "Operation terminated (retried 3 times)"와 새 자동 sync, 5초 뒤 작업 Succeeded, 6초 뒤 Synced/Healthy·ExternalSecret Ready 관측. 되돌림 병합부터 정상 상태 관측까지 36초다(approvals 같은 날 행).

   하지 않는 것: `.operation`을 지우지 않는다(작업이 정상 종료되지 않고 `Running` 표시가 남을 수 있다). 컨트롤러 파드를 다시 시작하지 않는다(작업 상태는 `status`에 남아 이어진다). `retry` 설정을 바꿔도 이미 만든 작업에는 적용되지 않는다(작업에 복사되어 있다).

5. 끝난 뒤를 본다. 끝낸 작업은 몇 초 안에 `Terminating` → `Failed`("Operation terminated")가 된다. 그다음은 `sync`로 갈린다. 새 자동 sync는 Application이 `OutOfSync`일 때만 시작하기 때문이다(v3.5.5 `appcontroller.go:2437-2442`).

   ```bash
   kubectl -n argocd get application "$APP" -o json | jq '{
     phase: .status.operationState.phase,
     startedAt: .status.operationState.startedAt,
     message: .status.operationState.message,
     sameSource: (.spec.source == .status.operationState.operation.sync.source),
     sync: .status.sync.status,
     health: .status.health.status,
     conditions: [.status.conditions[]?.type]
   }'
   ```

   | `sync` | 뜻 | 할 일 |
   |---|---|---|
   | `OutOfSync` | 고친 목표가 라이브와 달라 새 자동 sync가 돈다 | `startedAt`이 4단계의 `$STARTED`보다 뒤인 새 작업이 `sameSource: true`로 돌고, 끝에 `phase: "Succeeded"`, Synced/Healthy인지 본다 |
   | `Synced` | 되돌린 목표가 라이브와 이미 같다. 새 작업이 생기지 않는 것이 정상이다 | 새 작업을 기다리지 않는다. 아래 리소스 상태로 복귀를 본다 |
   | `Unknown`, 또는 `conditions`에 `ComparisonError` | 비교가 되지 않는다 | 멈추고 `status.conditions`를 본다 |

   - `Synced`로 끝나는 예: 이미지와 `migration.command`를 함께 바꾼 배포가 wave 1의 마이그레이션 Job에서 실패하고 그 PR 전체를 되돌린 경우. Deployment(wave 2)는 옛 이미지 그대로라 되돌린 목표와 같고, hook은 sync 상태에 들어가지 않는다(`controller/state.go:980-998`, 설계 C.5.4). 되돌린 설정으로 실패한 migrate Job은 다음 hook을 만들 때까지 남는다(`BeforeHookCreation`). `homelab status`가 그 Job의 실패를 보여도 복귀 판정은 아래 리소스 상태로 한다.
   - 라이브와 다른 것이 hook(마이그레이션 Job)뿐이면 새 자동 sync가 시작하지 않는다(설계 C.5.4의 `migration`만 바꾼 PR과 같다). hook을 다시 돌려야 하면 다음 배포 PR의 sync를 기다리거나 명시 sync가 필요하다. 이 절은 명시 sync를 다루지 않는다.
   - `phase`가 같은 `startedAt`으로 `Running`에 돌아갔으면 컨트롤러의 쓰기가 패치를 덮은 것이다. 3단계부터 다시 한다.
   - `OutOfSync`인데 `Failed`("Operation terminated")에서 2분 넘게 새 작업이 없으면 멈추고 원인을 본다. 자동 sync는 마지막 시도와 revision·source가 같으면 다시 하지 않는다(`alreadyAttemptedSync`, `appcontroller.go:2568-2600`). 2단계에서 spec이 바뀐 것을 봤다면 여기에 해당하지 않아야 한다.
   - 복귀는 리소스 상태로 확인한다(설계 B.8 E7): 되돌린 것이 ExternalSecret이면 `Ready=True`, 이미지면 파드 imageID가 `image.yaml`의 digest와 같은지. `Synced`로 끝난 경우도 같다.
