# T07 부트스트랩: main 교체·k3s·Argo CD

- 단계: P2 플랫폼 구축 (잠정)
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T01, T02, T06
- 선행 결정: D-03 (확정: 히스토리 유지), D-12, D-25 (병합 방식), D-26 (Codex Connector), D-28 (확정(사용자 2026-10-18): 이 티켓의 GitHub 설정 변경은 `gh api`, T10에서 import)
- 연결 AC: AC-P1, AC-P5, AC-P12
- 수행: 에이전트 (구성 작성) + 사람 (sudo 설치, main 병합 승인, Actions 재활성화 승인)

## 목표

main을 새 구조로 바꾸고, 새 클러스터의 바닥을 세운다.

## 할 일

0. 시작 조건. T06 검증 명령을 다시 실행해 통과하는지 확인하고, 결과를 작업 기록에 남긴다. 옛 datastore나 PV 데이터 위에 새 k3s를 설치하면 옛 클러스터가 되살아날 수 있다.
   - 명령: `test ! -e /usr/local/bin/k3s && ! systemctl cat k3s.service >/dev/null 2>&1 && sudo test ! -e /var/lib/rancher/k3s && sudo test ! -e /var/lib/rancher/k3s-storage`
1. Argo CD 루트 앱 목록에 T08~T11의 자리를 미리 만들고, 새 저장소 루트에 `README.md`와 `AGENTS.md`를 만든다. 둘 다 `rebuild`에 먼저 커밋한다. push는 사람 승인 뒤에 한다.
   - 루트 앱 자리는 이후 티켓이 같은 파일을 동시에 고치지 않게 하기 위해서다.
   - `README.md`와 `AGENTS.md`는 문서 지도(`docs/plans/2026-10-17-homelab-rebuild/README.md`)와 계획 명세를 가리킨다.
2. `rebuild` → main PR을 열고 병합한다(사람 승인, [approvals.md](../approvals.md)에 기록). `rebuild`는 main에서 분기했으므로 force push가 필요 없다(D-03).
   - Codex Connector가 PR을 열 때 코드·보안 리뷰를 자동으로 단다. 옛 파일 약 929개를 지우는 diff라 리뷰가 사용자 구독 사용량을 쓴다. D-26대로 리뷰를 받아들이거나 PR을 Draft로 연다. Draft로 열면 자동 리뷰를 피한다는 것은 확인하지 않았다(추측).
   - 병합 방식은 D-25를 따른다(추천 squash). 저장소는 squash 병합만 허용하고, 병합 뒤 head 브랜치를 자동으로 지운다. 그래서 병합하면 `rebuild` 브랜치가 사라진다. 옛 main은 새 main의 조상으로 남고, rebuild의 중간 커밋은 PR 기록에 남는다.
   - D-25가 merge commit을 고르면 이 병합 때만 허용했다가 되돌린다(사람 승인).
   - 필수 검사 `gate`는 T06에서 해제됐다. 옛 Argo CD도 T06에서 이미 없으므로 병합을 먼저 해도 안전하다.
   - main에는 T06의 임시 ruleset `main-interim`(PR 필수, 승인 1)이 걸려 있고 자기 PR은 승인할 수 없다. 그래서 검토한 SHA를 적어 둔 뒤 owner가 관리자 bypass로 병합한다: `gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`. 검토 뒤 새 커밋이 들어오면 이 명령이 거부한다(설계 C.4.7).
   - 병합 뒤 로컬 작업 사본을 main으로 옮긴다: `git -C /home/ukyi/homelab fetch --no-tags origin main` 뒤 `git -C /home/ukyi/homelab diff --quiet rebuild origin/main`으로 트리가 같은지 확인하고 `git -C /home/ukyi/homelab switch -C main origin/main`. 이 시점부터 T02의 switch 금지는 풀린다.
   - 병합 뒤 이후 티켓의 문서 변경은 PR로 main에 병합한다(명세 AC-X1, §12). 관리자 직접 push는 쓰지 않는다. 새 Argo CD가 main을 보기 시작하면 직접 push가 곧바로 배포된다.
3. 설계 문서대로 호스트 설정을 Git에서 적용하고, 버전을 고정해 k3s를 설치한다.
4. Argo CD를 설치하고 `targetRevision: main`으로 자기 관리(self-manage)로 넘긴다. 병합 전에 main을 동기화하면 옛 트리가 새 클러스터에 깔릴 수 있어서 병합 뒤에 한다.
5. 부트스트랩 절차를 문서로 남긴다. 시나리오 13의 입력이다. 위치는 설계 문서 E가 정한 경로이고, PR로 main에 병합한다.
6. main에 옛 워크플로가 없음을 확인하고, 저장소 Actions를 다시 켠다(사람 승인, [approvals.md](../approvals.md)에 기록). 값은 T10 설계를 따른다. 옛 값은 `enabled=true`, `allowed_actions=all`이었다. C-06 동결은 여기서 끝난다. T10의 새 CI/CD 시험은 이 뒤에 가능하다.
7. (잠정, T05에서 확정) 봇을 위한 Argo CD 읽기 전용 계정 자리를 만든다(AC-P12). Kubernetes·관측 읽기 전용 계정은 T08이 맡는다.

## 되돌리기

- 새 Argo CD가 main을 보기 전(할 일 4 전)이면 revert PR로 되돌린다.
- 본 뒤라면 새 Argo CD의 자동 동기화를 먼저 멈추고 revert한다. 그대로 revert하면 옛 트리가 새 클러스터에 배포된다.
- Actions를 다시 켠 뒤라면 revert 전에 Actions를 먼저 끈다. revert는 옛 워크플로 파일도 되살린다.
- Actions 재활성화 롤백: `gh api -X PUT repos/ukyi-app/homelab/actions/permissions -F enabled=false`.
- 되돌리기 실행도 [approvals.md](../approvals.md)에 기록한다.

## 제약

- 옛 `legacy` 태그와 옛 브랜치는 건드리지 않는다.
- 이 티켓의 GitHub 설정 변경(main 교체 뒤 필수 검사 `ci` ruleset 등, T05 할 일 11)은 `gh api`로 한다. Terraform github root(D-28)는 T10에서 생기고, 그때 import하면서 `ci` ruleset의 이름을 제자리에서 `main-checks`로 바꾼다.
- rebuild → main squash 병합 커밋은 GitHub에서 만들어져 작성자 이메일이 GitHub 계정 설정을 따른다. 여기에 개인 이메일이 들어가는 것은 사용자가 받아들였다(2026-10-18, 명세 §10 22항). 작업 사본의 로컬 git 설정은 2026-10-18에 noreply로 바꿨다.

## 완료 조건

- main이 새 구조이고, Argo CD가 main을 동기화한다.
- NUC 재부팅 뒤 k3s와 Argo CD가 준비 상태로 돌아온다.

## 검증

- 시작 조건(할 일 0)의 확인 결과가 작업 기록에 있다.
- 시나리오 12를 k3s·Argo CD 범위로 실행한다.
- 부트스트랩 문서가 있고, 문서 밖 수동 단계가 없었는지 작업 기록과 대조한다.
