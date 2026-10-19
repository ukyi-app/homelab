# T07 부트스트랩: main 교체·k3s·Argo CD

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 진행 중 (2026-10-19 착수. 할 일 0 시작 조건: T06 재부팅 뒤 `verify-t06.sh` 14:59 PASS 49 / FAIL 0, k3s 부재 V01(티켓의 시작 조건 명령과 같음)·V02와 데이터 경로 V23~V27 포함(sudo 판정). 할 일 1 완료: 커밋 `77029eb`, 독립 리뷰 P0·P1 0개, P2 3개·P3 4개 반영. 설계 결정 3개(사용자 2026-10-19): 비Helm 구성 요소의 클러스터 값은 A안(작은 로컬 차트), root는 `default` 프로젝트, Argo CD `owner` 비밀번호는 T09. 할 일 2 완료: PR #754 squash 병합(2026-10-19 17:32, main `c72757b`, Codex 리뷰 지적 0개). 할 일 3 완료(17:34, `verify.sh` 통과). 할 일 4 완료(17:35, `argocd`·`namespaces`·`root-prod` Synced·Healthy, 폴링 `60s 0`). 할 일 6 완료(17:37, Actions `selected`, 사용자 승인으로 5보다 먼저: bootstrap PR에서 `ci`가 처음 돌게). 할 일 5 PR 중. 남은 것: 할 일 7 `ci` ruleset, 시나리오 12 재부팅 확인)
- 명세: [../spec.md](../spec.md)
- 설계: [../platform/design.md](../platform/design.md) E.1 E2, E.2 E2 행, C.3.2, C.3.3, B.8 "E2 호스트·k3s·Argo CD", F D-25·D-26
- Blocked by: T01, T02, T06
- 선행 결정: D-03 (확정: 히스토리 유지), D-12 (확정(사용자 2026-10-18, T05): OS 유지. H4·H5 drop-in은 남아 있고 이 티켓이 같은 이름으로 덮어씀), D-25 (확정(사용자 2026-10-18, T05): rebuild → main은 squash 병합), D-26 (확정(사용자 2026-10-18, T05): Codex Connector 유지, 조건 넷), D-28 (확정(사용자 2026-10-18): 이 티켓의 GitHub 설정 변경은 `gh api`, T10에서 import), Argo CD 공개 webhook (확정(사용자 2026-10-18, T05): 두지 않음, 60초 폴링(`timeout.reconciliation` 60s, jitter 0))
- 연결 AC: AC-P1, AC-P5
- 수행: 에이전트 (구성 작성) + 사람 (sudo 설치, main 병합 승인, Actions 재활성화 승인, `ci` ruleset 적용 승인)

## 목표

main을 새 구조로 바꾸고, 새 클러스터의 바닥을 세운다.

산출물(설계 E2 "만들 것"):

- `host/`(설계 C.3.2). 클러스터별 값은 `host/clusters/prod.env`. `vm.env`는 같은 모양으로 두고 값은 T13의 VM 준비 때 채운다(`TAILNET_JOIN=false`). MagicDNS 이름은 env 파일에 두지 않는다. tailnet 이름이 들어가기 때문이다. install.sh가 실행 때 `tailscale status --json`으로 얻는다.
- `platform/argocd`, `platform/root`, `platform/namespaces`(설계 C.3.3). `platform/root`는 Helm 차트다. 운영 root `root-prod.yaml`, 같은 모양의 VM root `root-vm.yaml`(운영에는 apply하지 않고, 운영 root가 자식으로 렌더하지 않음), 클러스터 값 파일 `values-prod.yaml`을 차트 루트에 두고 자식 Application은 `templates/`에만 둔다. root가 `helm.valueFiles`로 읽은 값을 구성 요소 Application의 Helm values로 넘긴다. Helm 차트가 아닌 구성 요소에 값을 넘기는 방식은 이 티켓에서 정한다(설계 E8 VM 격리 1번). `values-vm.yaml`은 T13 전에 채운다.
- 루트 파일: `README.md`, `AGENTS.md`, `CLAUDE.md`, `.gitignore`, `.gitleaks.toml`, `.pre-commit-config.yaml`, `.tool-versions`, `CODEOWNERS`.
- 최소 `.github/workflows/ci.yaml`(gitleaks, actionlint, kustomize build).
- `docs/runbooks-public/bootstrap.md`.
- 필수 검사 `ci` ruleset(할 일 7).

## 할 일

0. 시작 조건. T06 검증 명령을 다시 실행해 통과하는지 확인하고, 결과를 작업 기록에 남긴다. 옛 datastore나 PV 데이터 위에 새 k3s를 설치하면 옛 클러스터가 되살아날 수 있다.
   - 명령: `test ! -e /usr/local/bin/k3s && ! systemctl cat k3s.service >/dev/null 2>&1 && sudo test ! -e /var/lib/rancher/k3s && sudo test ! -e /var/lib/rancher/k3s-storage`
1. main 교체 PR에 들어갈 새 구조를 `rebuild`에 먼저 커밋한다. push는 사람 승인 뒤에 한다.
   - Argo CD 루트 앱 목록(`platform/root`)에 T08a·T08b·T09·T10·T11의 자리를 미리 만든다. 이후 티켓이 같은 파일을 동시에 고치지 않게 하기 위해서다.
   - 새 저장소 루트에 `README.md`와 `AGENTS.md`를 만든다. 둘 다 문서 지도(`docs/plans/2026-10-17-homelab-rebuild/README.md`)와 계획 명세를 가리킨다.
   - 위 산출물 중 `bootstrap.md`와 `ci` ruleset을 뺀 나머지도 이때 넣는다. 최소 `ci.yaml`이 main 교체 PR에 들어가야 main 교체 직후부터 시크릿 유출 검사가 돈다.
2. `rebuild` → main PR을 열고 병합한다(사람 승인, [approvals.md](../approvals.md)에 기록). `rebuild`는 main에서 분기했으므로 force push가 필요 없다(D-03).
   - 병합 전에 rebuild 작업 트리에서 자기 저장소 참조 revision이 모두 `main`인지 손으로 확인한다(아래 "검증"의 명령). 브랜치 이름이 남은 채 병합하면 Argo CD가 죽은 브랜치를 따라간다. 자동 검사(L31)는 T10의 전체 `ci`에 생기고, 이 병합 때는 Actions가 꺼져 있다.
   - Codex Connector가 PR을 열 때 코드·보안 리뷰를 자동으로 단다. 옛 파일 약 929개를 지우는 diff라 리뷰가 사용자 구독 사용량을 쓴다. D-26(유지)대로 리뷰를 받아들이거나 PR을 Draft로 연다. Draft로 열면 자동 리뷰를 피한다는 것은 확인하지 않았다(추측).
   - 병합 방식은 D-25(확정)대로 squash다. 저장소는 squash 병합만 허용하고, 병합 뒤 head 브랜치를 자동으로 지운다. 그래서 병합하면 `rebuild` 브랜치가 사라진다. 옛 main은 새 main의 조상으로 남고(D-03 히스토리 유지), rebuild의 중간 커밋은 PR 기록에 남는다.
   - 필수 검사 `gate`는 T06에서 해제됐다. 옛 Argo CD도 T06에서 이미 없으므로 병합을 먼저 해도 안전하다.
   - main에는 T06의 임시 ruleset `main-interim`(PR 필수, 승인 1)이 걸려 있고 자기 PR은 승인할 수 없다. 그래서 검토한 SHA를 적어 둔 뒤 owner가 관리자 bypass로 병합한다: `gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`. 검토 뒤 새 커밋이 들어오면 이 명령이 거부한다(설계 C.4.7).
   - 병합 뒤 로컬 작업 사본을 main으로 옮긴다: `git -C /home/ukyi/homelab fetch --no-tags origin main` 뒤 `git -C /home/ukyi/homelab diff --quiet rebuild origin/main`으로 트리가 같은지 확인하고 `git -C /home/ukyi/homelab switch -C main origin/main`. 이 시점부터 T02의 switch 금지는 풀린다.
   - 병합 뒤 이후 티켓의 문서 변경은 PR로 main에 병합한다(명세 AC-X1, §12). 관리자 직접 push는 쓰지 않는다. 새 Argo CD가 main을 보기 시작하면 직접 push가 곧바로 배포된다.
3. 설계 문서대로 호스트 설정을 Git에서 적용하고, 버전을 고정해 k3s를 설치한다. 순서는 설계 C.3.2다: `host/preflight.sh --cluster prod --before` → `sudo host/install.sh --cluster prod --host-config` → `host/preflight.sh --cluster prod --after` → `sudo host/install.sh --cluster prod --k3s` → `host/verify.sh --cluster prod`.
   - D-12가 OS 유지라 T06이 남긴 H4·H5 drop-in이 있다. `host/etc/`의 같은 이름 파일이 덮어쓴다. 노드 DNS는 공용 DNS 직접이고 `tailscale set --accept-dns=false`를 유지한다.
   - OS를 다시 설치했다면(D-12에서는 보통 해당 없음) `tailscale up` 전에 Tailscale 콘솔에서 옛 NUC 기기를 지우고 다시 등록한다. 이름의 첫 라벨이 `prod.env`의 `NODE_NAME`과 같은지 확인한 뒤 키 만료를 해제한다(설계 C.3.2의 0).
4. Argo CD를 설치하고 `targetRevision: main`으로 자기 관리(self-manage)로 넘긴다. 병합 전에 main을 동기화하면 옛 트리가 새 클러스터에 깔릴 수 있어서 병합 뒤에 한다.
   - 설치 순서는 설계 C.3.3의 bootstrap 예시다. 이 티켓에서는 ESO 부트스트랩 Secret 단계(2번)를 건너뛴다. 그때 root에는 `argocd`·`namespaces`만 있고, ESO·Store와 부트스트랩 Secret은 T09가 더한다.
   - 공개 webhook은 두지 않는다. `argocd-cm`에 `timeout.reconciliation: 60s`와 `timeout.reconciliation.jitter: 0`을 둔다(확정(사용자 2026-10-18, T05)). jitter 기본값 1분이 남으면 실제 간격이 60~120초가 된다(설계 B.8 "E2").
   - `argocd-cm`·`argocd-rbac-cm`의 나머지 patch는 설계 C.3.3 표대로 한다. ExternalSecret health 덮어쓰기 자리도 이때 `argocd-cm`에 둔다. T09의 시험이 이것을 쓴다.
5. 부트스트랩 절차를 `docs/runbooks-public/bootstrap.md`로 남긴다. 시나리오 13의 입력이다. PR로 main에 병합한다.
6. main에 옛 워크플로가 없음을 확인하고, 저장소 Actions를 다시 켠다(사람 승인, [approvals.md](../approvals.md)에 기록). 값은 `enabled=true`, `allowed_actions=selected`이고 허용 목록은 설계 C.4.10 값을 바로 쓴다. 옛 값은 `enabled=true`, `allowed_actions=all`이었다. C-06 동결은 여기서 끝난다. T10의 새 CI/CD 시험은 이 뒤에 가능하다.
7. main에서 `ci`가 한 번 초록인 것을 본 다음, 필수 검사 `ci` ruleset을 `gh api`로 건다(사람 승인, [approvals.md](../approvals.md)에 기록). bypass는 없고, T10의 ruleset A와 같은 모양이다. 그러면 main에 T06의 `main-interim`과 `ci`가 함께 걸린다. rebuild → main 병합 때는 Actions가 꺼져 `ci`가 돌지 않으므로 이 ruleset은 병합 뒤에 건다. T10이 import하면서 제자리에서 `main-checks`로 이름을 바꾼다(D-28).
8. 봇용 Argo CD 읽기 전용 계정(AC-P12)은 이 티켓에서 빼고 T08b로 옮겼다(T05 재분해 2026-10-18, 설계 E.3). Kubernetes·관측 읽기 전용 계정과 한 단계에서 함께 확인하기 위해서다.

## 필요한 자격

- GitHub owner 계정(관리자): main 교체 PR의 관리자 bypass 병합, Actions 재활성화, `ci` ruleset. 기존 계정이다.
- NUC sudo: 호스트 설정, k3s 설치.
- Tailscale 콘솔 로그인: OS를 다시 설치했을 때만(옛 기기 삭제, 키 만료 해제).
- 새 외부 자격은 없다. 그래서 이 티켓을 위해 자격을 준비하는 앞 티켓이 없다.

## 제약

- 옛 `legacy` 태그와 옛 브랜치는 건드리지 않는다.
- 이 티켓의 GitHub 설정 변경(main 교체 뒤 필수 검사 `ci` ruleset 등, T05 할 일 11)은 `gh api`로 한다. Terraform github root(D-28)는 T10에서 생기고, 그때 import하면서 `ci` ruleset의 이름을 제자리에서 `main-checks`로 바꾼다.
- rebuild → main squash 병합 커밋은 GitHub에서 만들어져 작성자 이메일이 GitHub 계정 설정을 따른다. 여기에 개인 이메일이 들어가는 것은 사용자가 받아들였다(2026-10-18, 명세 §10 22항). 작업 사본의 커밋도 개인 이메일이다(로컬 noreply 설정은 2026-10-18에 지움).
- Codex Connector는 어떤 ruleset bypass에도 넣지 않는다(D-26 조건 (1)).
- 옛 저장소 교훈(설계 E2 "옛 저장소에서 가져올 것")과 설계 B.8 "E2 호스트·k3s·Argo CD" 함정은 해당 설정 옆 주석으로 옮긴다.

## 완료 조건

- main이 새 구조이고, Argo CD가 main을 동기화한다. `argocd`·`namespaces` Application이 Synced·Healthy다.
- Argo CD가 공개 webhook 없이 60초 폴링(jitter 0)으로 main을 본다.
- k3s가 고정 버전이고, 노드 DNS가 공용 DNS 직접이다.
- NUC 재부팅 뒤 k3s와 Argo CD가 준비 상태로 돌아온다(시나리오 12의 이 범위).
- `bootstrap.md` 밖의 수동 단계가 없었다.
- 저장소 Actions가 켜져 있고 새 워크플로만 있다.
- main에 임시 ruleset `main-interim`과 필수 검사 `ci`가 함께 걸려 있다.

## 검증

- 시작 조건(할 일 0)의 확인 결과가 작업 기록에 있다.
- `host/verify.sh --cluster prod`. `kubectl -n argocd get applications`.
- `kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation} {.data.timeout\.reconciliation\.jitter}'` → `60s 0`.
- `resolvectl status`에 `1.1.1.1 9.9.9.9`. `tailscale dns status` → "Tailscale DNS: disabled".
- 시나리오 12를 k3s·Argo CD 범위로 실행한다: `sudo reboot` 뒤 위 확인을 다시 한다.
- `gh api repos/ukyi-app/homelab/actions/permissions` → `enabled:true`, `allowed_actions:selected`.
- `gh api repos/ukyi-app/homelab/rules/branches/main --jq '[.[].type]'` → `pull_request`, `required_status_checks` 포함.
- 자기 저장소 참조 revision 손 확인(L31의 내용). 병합 전 rebuild 작업 트리와 병합 뒤 main에서 아래 명령의 결과가 한 줄 `<N> main`이다(N은 1 이상. 다른 값이 한 줄이라도 있거나 0줄이면 실패, L40). `repoURL`을 가진 모든 맵을 훑어 Application 단일·다중 소스와 ApplicationSet git 생성기의 `revision`을 함께 잡고, `.git` 접미사와 대소문자 차이도 같은 저장소로 본다(옛 함정, `2d2054a:scripts/check-argocd-revision.sh:6-10`, `:20-29`).

  ```bash
  { helm template root platform/root -f platform/root/values-prod.yaml; for f in $(git ls-files 'platform/*.yaml' | grep -vE '/templates/|/values[^/]*\.yaml$'); do echo ---; cat "$f"; done; } | yq -N '.. | select(tag == "!!map") | select(has("repoURL")) | select(.repoURL | test("(?i)ukyi-app/homelab(\\.git)?/?$")) | (.targetRevision // .revision // "없음")' | sort | uniq -c
  ```

- 운영 root 렌더 결과에 `root-prod`·`root-vm` Application이 없다: `helm template root platform/root -f platform/root/values-prod.yaml | yq -N 'select(.kind == "Application") | .metadata.name'`.
- 부트스트랩 문서가 있고, 문서 밖 수동 단계가 없었는지 작업 기록과 대조한다.

## 되돌리는 방법

- 새 Argo CD가 main을 보기 전(할 일 4 전)이면 revert PR로 되돌린다.
- 본 뒤라면 새 Argo CD의 자동 동기화를 먼저 멈추고 revert한다. 그대로 revert하면 옛 트리가 새 클러스터에 배포된다.
- Actions를 다시 켠 뒤라면 revert 전에 Actions를 먼저 끈다. revert는 옛 워크플로 파일도 되살린다.
- Actions 재활성화 롤백: `gh api -X PUT repos/ukyi-app/homelab/actions/permissions -F enabled=false`.
- k3s 재시도는 `k3s-uninstall.sh`로 지우고 잔여 경로가 없는지 확인한 뒤 다시 설치한다.
- 되돌리기 실행도 [approvals.md](../approvals.md)에 기록한다.
