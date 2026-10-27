# 앱 운영: 실패한 배포 되돌리기

앱(`apps/<앱>/`)·데이터(`data/<앱>/`) Application의 배포가 잘못된 values로 실패해 되돌릴 때의 순서다. 근거는 설계 [B.8](../plans/2026-10-17-homelab-rebuild/platform/design.md) E2의 Argo CD 재시도 함정, C.3.3(retry 설정), C.4.9(Argo CD rollback을 쓰지 않는다)다. 이미지만 이전으로 돌리는 것은 `homelab rollback`(설계 C.4.9), 데이터를 되돌리는 것은 [restore.md](restore.md)다.

- 바꾸는 길은 Git뿐이다. 되돌림도 PR이다.
- 외부 변경(병합, Application 패치)은 [approvals.md](../plans/2026-10-17-homelab-rebuild/approvals.md)에 줄로 남긴다.
- 실행하다 이 문서와 다르게 한 것이 있으면 이 문서를 먼저 고친다.

## 1. 잘못된 values로 실패한 배포

### 1.1 되돌림 PR만으로는 바로 고쳐지지 않는 이유

Argo CD v3.5.5 자동 sync는 작업(operation)을 만들 때 그때의 `spec.source`(ApplicationSet이 넣은 `helm.valuesObject`, 차트 태그 `targetRevision` 포함)와 retry 설정을 작업에 복사한다. 재시도는 그 사본(`status.operationState.operation.sync.source`)으로 렌더하고 `spec.source`를 다시 읽지 않는다. 그래서 되돌림 PR이 병합되어 ApplicationSet이 `spec`을 고쳐도, 실패해 재시도 중인 작업은 옛 값으로 계속 실패한다. 고친 값은 그 작업이 끝나고 새 자동 sync가 시작될 때 쓰인다.

- 근거(v3.5.5 소스): 작업 생성 `controller/appcontroller.go:2458-2479`, 재시도 `:1621-1663`, 재시도가 쓰는 source `controller/sync.go:79-92`. v3.2.0에서 들어온 동작이다. v3.1.x는 재시도마다 spec을 다시 읽었다.
- `syncPolicy.retry.refresh: true`는 해법이 아니다. 재시도 전에 revision만 비워 같은 `targetRevision`을 다시 풀고, source 사본(values)은 그대로 둔다(`appcontroller.go:1649-1655`, `controller/state.go:310-313`). 봇 자리는 values가 Git 경로의 파일이라 refresh로 고쳐지지만(설계 C.8), 앱·데이터 Application은 values가 spec 안이라 고쳐지지 않는다.
- 실측(T13 시나리오 6, 2026-10-27): Infisical에 없는 키를 요구한 #945의 작업(04:34:39Z 시작)이 재시도하는 동안 되돌림 #946(04:46:18Z 병합)이 반영되지 않았다. 재시도 10회를 다 쓴 05:17:23Z에 새 작업이 시작되어 05:17:34Z에 Synced가 됐다. 병합부터 약 31분이다.

### 1.2 기다릴지, 끝낼지

| | 기다리기 | 진행 중 작업 끝내기(1.3의 4단계) |
|---|---|---|
| 고친 값 반영 | 재시도를 다 쓴 뒤 새 자동 sync | 끝낸 직후 새 자동 sync |
| 걸리는 시간 | 앱·데이터 Application(limit 10, backoff 30s → 최대 5m)의 재시도 대기 합이 설정상 **약 37분**(30s+60s+120s+240s+300s×6 = 37분 30초). T13 실측은 작업 시작부터 실패까지 42분 44초, 되돌림 병합부터 반영까지 약 31분 | 수 초에서 1분 남짓으로 예상(**T13에서 실측 예정**) |
| 위험 | 운영 쓰기가 없다 | 운영 실측 전이다. 2단계를 건너뛰면 새 작업이 옛 값으로 다시 시작해 재시도를 처음부터 한다 |

실패가 뒤 wave 적용 전에 났으면(시나리오 6의 ExternalSecret 실패처럼) 그동안 옛 파드가 그대로 돈다. 그러면 기다려도 된다. 새 파드가 이미 깨졌거나 37분이 길면 끝낸다.

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

   **고친 값이 보이기 전에 4단계로 가지 않는다.** 먼저 끝내면 새 자동 sync가 옛 값으로 시작해 재시도를 처음부터 다시 한다.

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
   | `operation: false`, phase가 `Succeeded`·`Failed`·`Error` | 작업이 끝났다 | 끝내지 않는다. 5단계(새 자동 sync가 곧 시작한다) |
   | 그 밖 | 이 절이 다루지 않는 상태 | 멈추고 `kubectl -n argocd get application "$APP" -o yaml`의 `status.conditions`·`operationState`를 본다 |

   두 값을 직접 대조하려면 `jq '{spec: .spec.source.helm.valuesObject, running: .status.operationState.operation.sync.source.helm.valuesObject}'`로 본다. values는 공개 저장소의 파일이고 `secrets`는 키 이름뿐이라 출력해도 된다.

4. 진행 중 작업을 끝낸다(**T13에서 실측 예정**).

   공식 길은 `argocd app terminate-op <앱>`(owner 로그인 UI의 Terminate도 같은 서버 호출)이다. 서버는 `status.operationState.phase`를 `Terminating`으로 바꿔 쓰기만 하고, 정리는 컨트롤러가 한다(v3.5.5 `server/application/application.go:2508-2521`, `controller/sync.go:358-362`). 이 저장소는 argocd CLI를 고정 도구(`.tool-versions`)에 두지 않으므로 kubectl로 같은 필드를 쓴다.

   - Application CRD에 status subresource가 없어(`subresources: {}`) 일반 patch가 status를 바꾼다.
   - 권한은 Argo CD RBAC이 아니라 Kubernetes RBAC이다. 운영자 kubeconfig는 `kubectl auth can-i patch applications.argoproj.io -n argocd`가 `yes`다. 봇 계정 `bot-reader`는 할 수 없다.
   - 같은 패치(merge patch)로 2026-10-23 `sandbox`의 멈춘 작업을 끝낸 적이 있다(approvals 01:49 행). 그때는 시도 중 health 대기였고, 재시도 대기 중에 끝내는 것은 아직 운영에서 하지 않았다.

   ```bash
   # 3단계에서 본 작업의 시작·실패 시각. 패치는 그 작업이 아직 같은 재시도 대기 중일 때만 적용된다(JSON patch test).
   # 그사이 다음 시도가 시작됐거나 작업이 끝났으면 test가 실패하고 아무것도 바뀌지 않는다. 그때는 3단계부터 다시.
   # 끝난 작업에 Terminating을 쓰면 .operation 없이 진행 중 표시만 남는다(컨트롤러는 .operation이 있을 때만 작업을
   # 처리한다, appcontroller.go:1138-1140). 시도 중에 끝내면 마이그레이션 Job 같은 hook을 중간에 지울 수 있다
   # (Terminate는 hook을 먼저 정리한다, gitops-engine sync_context.go:725-745). test가 둘 다 막는다.
   STARTED=$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.operationState.startedAt}')
   FINISHED=$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.operationState.finishedAt}')
   : "${STARTED:?작업 없음}" "${FINISHED:?재시도 대기 중이 아니다. 몇 초 뒤 3단계부터}"
   kubectl -n argocd patch application "$APP" --type=json -p "$(jq -nc --arg s "$STARTED" --arg f "$FINISHED" '[
     {op: "test", path: "/status/operationState/phase", value: "Running"},
     {op: "test", path: "/status/operationState/startedAt", value: $s},
     {op: "test", path: "/status/operationState/finishedAt", value: $f},
     {op: "replace", path: "/status/operationState/phase", value: "Terminating"}]')"
   ```

   test 연산의 거부(다른 `finishedAt`, 끝난 작업, 시도 중)는 `kubectl patch --local`로 확인했다(2026-10-27). 운영 Application에 적용한 결과는 아직 없다.

   하지 않는 것: `.operation`을 지우지 않는다(작업이 정상 종료되지 않고 `Running` 표시가 남을 수 있다). 컨트롤러 파드를 다시 시작하지 않는다(작업 상태는 `status`에 남아 이어진다). `retry` 설정을 바꿔도 이미 만든 작업에는 적용되지 않는다(작업에 복사되어 있다).

5. 새 자동 sync가 고친 값으로 시작하는지 본다.

   ```bash
   kubectl -n argocd get application "$APP" -o json | jq '{
     phase: .status.operationState.phase,
     startedAt: .status.operationState.startedAt,
     message: .status.operationState.message,
     sameSource: (.spec.source == .status.operationState.operation.sync.source),
     sync: .status.sync.status,
     health: .status.health.status
   }'
   ```

   - 기대: 몇 초 안에 `Terminating` → `Failed`("Operation terminated")가 되고, 이어 `startedAt`이 4단계의 `$STARTED`보다 뒤인 새 작업이 `sameSource: true`로 돈다. 끝에 `phase: "Succeeded"`, Synced/Healthy다.
   - `phase`가 같은 `startedAt`으로 `Running`에 돌아갔으면 컨트롤러의 쓰기가 패치를 덮은 것이다. 3단계부터 다시 한다.
   - `Failed`("Operation terminated")에서 2분 넘게 새 작업이 없으면 멈추고 원인을 본다. 자동 sync는 마지막 시도와 source가 같으면 다시 하지 않는다(`alreadyAttemptedSync`, `appcontroller.go:2568-2600`). 2단계에서 spec이 바뀐 것을 봤다면 여기에 해당하지 않아야 한다.
   - 반영은 리소스 상태로 확인한다(설계 B.8 E7): 되돌린 것이 ExternalSecret이면 `Ready=True`, 이미지면 파드 imageID가 `image.yaml`의 digest와 같은지.
