# T04 플랫폼 설계 실행

- 단계: P1 플랫폼 설계
- 상태: 준비됨 (T02 완료, 2026-10-17)
- 명세: [../spec.md](../spec.md)
- Blocked by: T02의 로컬 단계(할 일 1~7), T03 (완료). T02가 먼저인 이유: 산출물이 T02의 작업 사본 안에 생기므로, 작업 사본과 첫 커밋이 먼저 있어야 한다. T02의 push는 기다리지 않는다.
- 연결 AC: AC-P2, AC-P12, AC-X1
- 수행: 에이전트 (Claude Code 추천, 아래 "수행 방식". 읽기 전용 조사 + 문서 작성). 사람은 결과 검토와 push 승인

## 목표

[../platform/design-prompt.md](../platform/design-prompt.md)를 프롬프트로 실행해 새 플랫폼 설계 문서를 만든다.

## 입력

- 플랫폼 프롬프트 전체.
- 이 명세 §1, §4.5, §5, §7(AC-P2, AC-P8, AC-P12), §10.
- 옛 저장소: 커밋 `2d2054a`(`2d2054aa294b3862de1b1af6eada88fb15e656e6`)를 고정해 읽는다. `legacy` 태그가 생겼으면 같은 커밋인지 확인한다(`git ls-remote https://github.com/ukyi-app/homelab "refs/tags/legacy^{}"`). T02 뒤에는 `/home/ukyi/homelab`에도 이 커밋이 있다(`git -C /home/ukyi/homelab show 2d2054a:<경로>`). 옛 사본 `~/workspace/homelab`의 작업 트리는 옛 작업 브랜치라 읽지 않고, 옛 사본에서 fetch하지 않는다(T01).
- NUC 로컬 전용 자료(옛 런북, `~/workspace/homelab-infra/`)는 읽지 않는다 (D-27 추천).

## 수행 방식 (추천)

**Claude Code로 한다.** gh 인증과 웹 조회가 되고, 조사를 병렬 서브에이전트로 나눌 수 있다. Codex 기본 샌드박스는 네트워크가 막혀 `gh api`와 공식 문서 조회가 실패한다.

세 단으로 나눈다.

1. **조사 (병렬).** 조사 메모는 저장소 밖에 둔다.
   - §1 상태와 GitHub·org 실측. 플랫폼 프롬프트 §1의 확인 경로(허용·금지)만 쓴다.
   - §3 교훈 표. 디렉터리 묶음 셋으로 나눈다: `infra`+`platform`+`apps`+`ops` / `tools`+`scripts`+`tests`+`policy` / `docs`+`.github`+루트+`.claude`+호스트.
   - 공식 문서 조사: ESO와 Infisical Operator, Infisical 요금제, CNPG, Valkey, Image Updater, Tailscale, k3s·Argo CD 버전.
2. **설계 (한 세션).** §4~§8과 산출물 전체를 쓴다. 맥락 전체가 필요하므로 쪼개지 않는다.
3. **독립 검토.** 다른 세션이 아래 완료 조건, AC-P2, AC-P12 체크리스트로 검토하고, B를 `git ls-tree 2d2054a <dir>/` 1단계 항목과 대조한다.

사람이 결과를 검토한 뒤, 이 티켓을 실행한 세션이 design.md를 `rebuild`에 로컬 커밋한다. 설계 에이전트 자신은 저장소를 바꾸지 않는다(플랫폼 프롬프트 머리말). push는 별도 승인이다.

## 산출물

[../platform/design.md](../platform/design.md) (`/home/ukyi/homelab/docs/plans/2026-10-17-homelab-rebuild/platform/design.md`). 구성은 플랫폼 프롬프트 §10을 따른다.

- **0절:** §1 상태표.
- **A~F.**
- **G절:** 검증 시나리오 1~17마다 기대 결과, 검증 방법, 담당 구축 단계, "실제 검증 완료 / 설계상 기대" 구분.

B 교훈 표의 행 단위는 플랫폼 프롬프트 §3 완료 기준을 따른다. 나열한 디렉터리의 1단계 항목이 한 행이고, 묶음 행은 포함 경로를 glob으로 적는다.

## 제약

- 플랫폼 프롬프트 머리말의 "작업 범위"와 §1의 확인 경로(허용·금지)를 따른다.
- design.md는 공개된다(D-23, 확정: public 유지). 시크릿 값과 운영 민감 정보(복구 자산 세부, 토큰 목록)를 쓰지 않는다.

## 완료 조건

- 0절에 플랫폼 프롬프트 §1 상태표가 있다.
- B가 §3 완료 기준의 범위를 모두 덮는다.
- A~F가 모두 있다.
- G절에 검증 시나리오 1~17마다 검증 방법이 있다.
- 플랫폼 프롬프트 §2 "봇을 위한 여지"의 자리마다 위치, 권한 범위, 준비 확인 방법이 있다(AC-P12).
- design.md가 `rebuild`에 커밋돼 있다. push는 사람 승인 뒤에 한다(spec §12).

## 검증

- 독립 검토와 사람이 위 완료 조건을 체크리스트로 검토한다.
- 교훈 표 커버리지는 `git ls-tree 2d2054a <dir>/`의 1단계 항목과 §3 완료 기준 범위로 대조한다. 묶음 행은 glob으로 대조한다.
