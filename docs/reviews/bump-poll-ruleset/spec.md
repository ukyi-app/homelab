# Spec — bump-poll/** writer-App 예약 ruleset (F-0)

status: ready-for-agent
slug: bump-poll-ruleset
branch: feat/bump-poll-ruleset
origin: `docs/bugfixes/bump-poll-duplicate-pr.md` Follow-up backlog F-0 · handoff `/tmp/handoff-bump-poll-followups-2026-07-21.md`
revised: plan-r1 triage(R-1 R-46 정직화 · R-2 deletion 축소) 반영

## Problem Statement

bump-poll 중복 PR 버그픽스(PR #364)를 랜딩하면서, owner는 그 픽스가 **도구 계층에서 원리적으로 닫을 수 없는
잔여**를 남긴다는 것을 리뷰어 소견으로 확인했다. `tools/ensure-bump-pr.ts`는 force-push 직전에 원격 head 커밋의
소유권(author/committer = writer App 봇 + 결정적 bump 메시지)을 검증하지만, 이는 **안전 인터록이지 인증이 아니다**:
워크플로의 `git commit`은 서명되지 않으므로(GitHub은 API로 만든 커밋만 서명한다) git author/committer/메시지는
자유 텍스트이고, `contents:write` 자격을 가진 적대적 행위자(탈취된 owner PAT, 제2 봇, 협업자)는 그 신원을
**위조**할 수 있다.

또한 R-46 잔여 TOCTOU가 있다: 실행기가 결정적 head를 초기 스캔에서 계산한 뒤 force-push하기까지의 창에서,
남이 그 head로 다른 base의 동일-레포 PR을 열 수 있다. PR 생성은 git ref를 움직이지 않으므로 `--force-with-lease`
(OID만 본다)는 여전히 성공하고, 이어지는 writer App의 허용된 force-push가 **그 PR의 공유 head·리뷰 상태를
재작성**한다 — **git ref lease는 동시 PR 생성을 원리적으로 막을 수 없다**(리뷰어 확인). 도구는 force-push 직전
재조회(③-b2)로 창을 마이크로초로 좁혔을 뿐이다.

owner가 원하는 것: **강제 가능한 서버측 불변식**으로 방어를 두텁게 하는 것. GitHub이 제공하는 유일한 강제 수단은
`bump-poll/**` ref 네임스페이스를 writer App 전용으로 예약하는 **repository ruleset**이다. 단, 이 룰셋도 R-46
자체(동시 PR 생성)를 없애지는 못한다 — 아래 불변식이 그 경계를 정직하게 서술한다.

## Solution

`infra/github` terraform 루트(신뢰 앵커)에 GitHub repository ruleset을 추가한다. 이 ruleset은 `refs/heads/bump-poll/**`
패턴의 브랜치에 대해 **생성(creation)·갱신(update)을 writer App(`ukyi-homelab-writer`)에게만 허용**하고, 그 외 모든
행위자(owner PAT 포함)를 거부한다. writer App의 App ID는 slug로 해석하는 data source로 얻어 하드코딩을 피한다.

이 루트는 신뢰 앵커라 **owner-local apply 전용**이다(CI 무인 apply 금지 — 광범위 admin PAT를 CI에 저장하지
않는 보안 모델). 따라서 이 작업의 산출물은 두 갈래다:

- **머지 가능분(이 브랜치)**: terraform 리소스 + 데이터 소스 + 변수 + CI 구조 테스트(약화 회귀 가드) + 문서.
- **owner-local 후속(apply 후)**: `terraform apply` + 적대 라이브 검증(non-writer 거부·writer 성공 실측).

### 정직한 불변식 (과대주장 금지 — R-1 triage 반영)

이 ruleset은 `bump-poll/**`를 *ref 생성·push*에 한해 writer App 전용으로 만든다.

- **닫는 것**: 비-writer 자격의 bump-poll/* 브랜치 **생성**과 기존 브랜치로의 **push**. 즉 R-19(남의 커밋 덮어쓰기)를
  서버가 강제하고, rogue ref를 심는 벡터를 차단한다(브랜치를 못 만들면 그 head로 동일-레포 PR도 못 연다).
- **닫지 못하는 것 — R-46은 좁혀졌으나 원천 차단되지 않은, 명시적으로 수용된 잔여다**: 이미 존재하는 writer-생성
  head에 다른 base PR을 **여는 행위 자체**를 ruleset은 막지 못한다(PR 생성을 head 네임스페이스로 게이트하는 규칙이
  없다). 그 뒤 writer App의 허용된 force-push가 그 PR의 공유 head·리뷰를 재작성할 수 있다. **main 분기보호는 다른
  base를 보호하지도 이 head 재작성을 막지도 못하므로 이 잔여를 제거하지 않는다.** 도구의 ③-b2 재조회가 창을
  마이크로초로 좁힐 뿐이며, 완전 제거는 공유 가변 head를 force-push하지 않는 아키텍처 재설계를 요구한다(범위 밖).
  → **R-46은 이 작업으로 "닫힌다/중화된다"가 아니라 "좁혀진 채 명시적으로 수용된다".**
- **이번 increment에서 제외한 것 — deletion**: 삭제 제약(non-writer의 bump-poll/* 삭제 차단)은 이번에 걸지 않는다
  (R-2 triage). 근거는 아래 Out of Scope 참조 — 요약하면 삭제 제약이 `delete_branch_on_merge`를 깨 고아 브랜치를
  남길 수 있고(GitHub 문서 명시), 안전한 롤아웃은 멱등 writer-App 정리 경로 설계를 선행해야 하기 때문이다. 삭제는
  세 규칙 중 가장 덜 load-bearing(비-writer가 진행 중 브랜치를 지우는 nuisance/DoS만 막음 — 실행기가 다음 주기에
  재생성)이라 이번 제외의 보안 손실이 작다.

## User Stories

1. homelab owner로서, `bump-poll/*` 브랜치가 writer App으로만 생성되기를 원한다 — 탈취된 owner PAT나 제2 봇이
   그 네임스페이스에 rogue 브랜치를 심지 못하게 하기 위해.
2. homelab owner로서, 기존 `bump-poll/*` 브랜치에 대한 push가 writer App으로만 제한되기를 원한다 — 다른 자격이
   실행기의 bump 커밋을 덮어쓰지 못하도록 서버가 강제(R-19)하기 위해.
3. bump 실행기(writer App)로서, `bump-poll/*` 브랜치를 계속 생성·force-push·삭제할 수 있기를 원한다 — 기존 멱등
   상태 기계(create/adopt/rebuild/skip)가 변경 없이 동작하도록.
4. homelab owner로서, App ID가 하드코딩된 매직 넘버가 아니라 App slug로 해석되기를 원한다 — 설정이 자기설명적이고
   App 재생성에도 살아남도록.
5. homelab owner로서, 이 ruleset이 내 로컬 머신에서만 apply되기를 원한다(CI 무인 apply 절대 없음) — 신뢰 앵커
   보안 모델(광범위 admin PAT를 CI에 두지 않음)을 보존하기 위해.
6. 리뷰어로서, 스펙이 이 ruleset이 *닫는* 것과 *좁혀진 채 수용하는* 잔여(R-46)를 정직하게 구분하기를 원한다 —
   R-46 동시-PR TOCTOU가 닫히거나 중화된다고 오인하지 않도록.
7. homelab owner로서, ruleset이 약화되면(패턴 확대·creation/update 규칙 제거·bypass 확대·enforcement 강등) 실패하는
   CI 구조 테스트를 원한다 — 무인 편집이 불변식을 조용히 침식하지 못하도록.
8. homelab owner로서, 신규 리소스가 있어도 github 루트의 `terraform validate`가 통과하기를 원한다 — 기존 gate가
   green을 유지하도록.
9. homelab owner로서, apply 후 적대 라이브 검증 절차(생성/push 거부 실측)를 원한다 — ruleset이 실제로 강제하는지
   신뢰 전에 확인하기 위해.
10. homelab owner로서, 이번 increment가 `delete_branch_on_merge`(머지 후 head 자동 삭제)를 건드리지 않기를 원한다 —
    creation/update만 제약하므로 브랜치 자동 정리가 그대로 동작해 고아 브랜치 위험이 0이도록.
11. homelab owner로서, 삭제 제약(deletion)이 멱등 writer-App 정리 경로가 설계·검증될 때까지 연기되기를 원한다 —
    삭제 제약 추가가 auto-delete-on-merge를 깨 고아 브랜치를 누적시키는 일이 절대 없도록.
12. 미래 유지보수자로서, ruleset의 근거(인터록≠인증·미서명 커밋·R-46 수용 잔여)가 리소스 곁과 traps 원장에
    문서화되기를 원한다 — "왜"가 살아남도록.
13. homelab owner로서, tf-reconcile 드리프트 잡이 ruleset이 적용 상태에서 벗어날 때 알려주기를 원한다 — 수동 UI
    변경이나 미적용 편집이 드러나도록.
14. homelab owner로서, 이 ruleset이 기존 main 분기보호와 공존하기를 원한다 — 어느 쪽도 서로를 약화시키지 않도록.
15. contents:write를 가진 적대적 행위자(탈취된 비-writer 자격)로서, bump-poll ref를 심거나(생성) 실행기 커밋을
    덮어쓰려(push) 하고 이것이 **실패**하기를 원한다(네거티브/위협모델 스토리) — 네임스페이스가 생성·push에 한해
    머신 전용으로 유지되도록.
16. homelab owner로서, apply 시 data source가 반환한 App ID가 Integration bypass actor로 실제 동작함을 확인하기를
    원한다 — provider의 App-능력 가정이 실측으로만 확증되도록(fine-grained App 능력은 실제 시도로만 검증).
17. homelab owner로서, ruleset의 bypass가 writer App 하나로 국한되고 광범위 역할(RepositoryRole admin·
    OrganizationAdmin)을 포함하지 않기를 원한다 — 네임스페이스 전용성이 우발적으로 넓어지지 않도록.
18. 미래 유지보수자로서, 코드베이스의 R-46 관련 서술이 정정된 불변식과 일치하기를 원한다 — 실행기 주석이 "진짜
    닫힘은 F-0"처럼 잔여를 은퇴시키는 과대주장을 남기지 않도록.

## Implementation Decisions

- **모듈**: `infra/github` terraform 루트에 신규 리소스와 데이터 소스를 추가한다. 기존 `github_branch_protection.main`
  과 **공존**한다(다른 ref — main vs `bump-poll/**` — 서로 무간섭). 리소스 배치는 신규 파일로 분리해 repo.tf의
  분기보호와 성격을 구분한다.
- **리소스 종류**: `github_repository_ruleset` (target=`branch`, enforcement=`active`) + `github_app` data source
  (App slug→App ID 해석). App slug는 terraform 변수(기본값 `ukyi-homelab-writer`)로 노출한다 — 시크릿 아님.
- **규칙 조합(R-2 반영)**: `creation=true` + `update=true` **둘만** restrict. `deletion`은 이번 increment에서
  설정하지 않는다(연기 — Out of Scope 참조). `non_fast_forward`도 설정하지 않는다(실행기가 rebuild/adopt에서
  합법적으로 force-push하며, bypass actor는 어차피 전 규칙 면제).
- **ref 조건**: `conditions.ref_name.include = ["refs/heads/bump-poll/**"]`, `exclude = []`.
- **bypass actor**: writer App **하나**. `actor_type="Integration"`, `bypass_mode="always"`. actor_id는 data
  source가 준 App ID. 이 단일 actor로 100% 커버됨이 확인됨 — bump-poll/* ref를 push하는 유일한 합법 주체는 writer
  App이다(bump-poll.yaml이 writer 토큰으로 push; pr-sweeper.yaml은 `bump-poll/`를 명시적으로 제외한다 — R-25).
- **타입 정합**: `github_app` data source의 `id`는 문자열이고 `bypass_actors.actor_id`는 숫자다. 명시적
  `tonumber(...)` 변환으로 validate/plan 타입 오류를 피한다(자동 변환에 의존하지 않는다).
- **코드 서술 정정(R-1 반영)**: `tools/ensure-bump-pr.ts`의 R-46 주석("진짜 닫힘은 F-0")을 정정된 불변식과
  일치하도록 완화한다(주석 한정 변경 — F-0은 생성/push 벡터를 닫아 창을 좁힐 뿐, R-46 동시 PR 생성 자체는 못 막는
  수용 잔여). 랜딩된 역사 기록(`docs/bugfixes/bump-poll-duplicate-pr.md`·그 verification.md)은 수정하지 않는다.
- **apply 경계**: 이 루트는 신뢰 앵커라 **owner-local apply 전용**. CI는 `terraform validate`(init -backend=false)만
  돌리고, tf-reconcile은 github 루트를 plan-only 드리프트 알림으로만 다룬다(무인 apply 금지). 신규 리소스는 적용
  전까지 tf-reconcile 드리프트 잡에서 "생성 대기"로 표시된다 — 이는 owner에게 apply를 촉구하는 의도된 신호다.
- **결정을 정확히 인코딩하는 스케치**(프로토타입 아님 — 계약 형태):

  ```hcl
  data "github_app" "writer" { slug = var.writer_app_slug }   # default "ukyi-homelab-writer"

  resource "github_repository_ruleset" "bump_poll_writer_only" {
    name        = "bump-poll-writer-only"
    repository  = github_repository.homelab.name
    target      = "branch"
    enforcement = "active"
    conditions { ref_name { include = ["refs/heads/bump-poll/**"]; exclude = [] } }
    rules { creation = true; update = true }   # deletion은 후속 increment로 연기(R-2)
    bypass_actors {
      actor_id    = tonumber(data.github_app.writer.id)
      actor_type  = "Integration"
      bypass_mode = "always"
    }
  }
  ```

## Testing Decisions

좋은 테스트는 **외부 행동만** 검증하고 구현 세부에 결합하지 않는다. 이 변경의 "외부 행동"은 두 층으로 나뉘고,
그중 하나만 CI에서 관측 가능하다:

- **Seam A — `terraform validate` (기존 seam 재사용, CI gate)**: 신규 리소스·데이터 소스가 유효한 HCL이고 github
  루트가 계속 검증됨을 보장. 기존 `infra/_tests/test_tf_validate.bats`("github: validated")가 이미 이 seam을
  소유한다 — 별도 테스트 불요, 리소스가 통과하기만 하면 된다.
- **Seam B — 구조 회귀 가드 bats (신규 seam 1개, CI gate)**: `tests/gates/test_branch_protection.bats`를 본보기로,
  ruleset .tf 파일에 대한 grep 단언으로 **불변식이 약화되지 못하게** 잠근다. 단언: (1) `refs/heads/bump-poll/**`
  타깃, (2) `creation`·`update` 둘 다 true, (3) bypass가 `github_app`(writer) data source로 배선되고
  actor_type=`Integration`, (4) enforcement=`active`(disabled/evaluate로 강등되지 않음), (5) bypass에 광범위
  역할(RepositoryRole/OrganizationAdmin)이 추가되지 않음, (6) 패턴이 넓어지지 않음(`**`가 전 브랜치를 삼키는
  형태로 변형되지 않음). 이 테스트는 라이브 API를 호출하지 않고 파일 구조만 본다 — CI-safe. `bats` `@test` 이름은
  영어(디렉토리 단위 실행 시 한글 인코딩 버그 회피). deletion은 이번 increment에 없으므로 단언하지 않는다(후속
  increment가 deletion+정리 경로를 추가할 때 그 테스트를 함께 넣는다).
- **Seam C — 적대 라이브 검증 (owner-local, CI seam 아님)**: 실제 강제 동작은 아키텍처상 CI에서 관측 불가하다
  (신뢰 앵커 — CI에 admin PAT를 두지 않는다). 대신 owner-local 절차 + 캡처된 증거로 분리한다. 검증 항목:
  ①non-writer(owner PAT)로 `bump-poll/probe-*` push→거부(creation) ②writer App 토큰으로 동일 push→성공(bypass)
  ③기존 bump-poll 브랜치에 non-writer force-push→거부(update) ④apply가 성공하고 룰셋에 writer App이 bypass로
  표시(data source id가 Integration actor로 유효) ⑤실제 bump PR auto-merge 후 head 브랜치 자동 삭제가 **평소대로**
  동작(creation/update만 제약하므로 영향 없음을 확인 — 회귀 가드). 증거는 `docs/reviews/bump-poll-ruleset/
  verification.md`에 명령·결과·SHA로 기록한다.

**Prior art**: `tests/gates/test_branch_protection.bats`(github 루트 불변식 grep 가드), `infra/_tests/test_tf_validate.bats`
(루트 validate), `infra/_tests/test_tf_reconcile.bats`(plan-only 불변식 가드).

## Out of Scope

- **실제 `terraform apply`와 라이브 강제**: owner-local 전용. 이 브랜치는 코드·테스트·문서만 랜딩한다.
- **`deletion=true` 규칙(R-2 triage로 연기)**: 삭제 제약은 이번 increment에서 제외한다. 이유: GitHub은 repository
  rules가 자동 브랜치 삭제(`delete_branch_on_merge`)를 막을 수 있다고 명시적으로 문서화하며, 현재 실행기에는 명시적
  브랜치 삭제 경로가 없다. 따라서 삭제 제약을 지금 걸면 auto-delete-on-merge가 깨져 고아 head가 누적될 위험이 있다.
  안전한 도입은 **멱등 writer-App 브랜치 정리 경로를 먼저 설계·검증**(재시도·인가 포함)한 뒤 별도 increment로 한다.
  그때 사전-활성화 프로브(삭제가 실제로 어떻게 귀속되는지)와 정확한 롤백/고아 정리 절차를 스펙에 포함한다.
- **F-1(worktree-격리 항목 러너)·F-2(형제 PR 자동 close)**: 별도 파이프라인(핸드오프 참조).
- **main 분기보호를 ruleset으로 이관**: 현행 `github_branch_protection.main` 유지. 이 작업은 bump-poll 네임스페이스만
  다룬다(분기보호 리팩터는 별건).
- **다른 봇/자동화에 대한 bypass 확대**: 현재 bump-poll/* ref를 만지는 유일 합법 주체는 writer App뿐이므로 단일
  actor로 족하다. 신규 자동화가 이 네임스페이스를 쓰게 되면 그때 bypass를 확장한다(현재 불필요).
- **R-46 완전 제거(아키텍처 재설계)**: 공유 가변 head를 force-push하지 않는 content-addressed head 재설계는 과도한
  범위다. 이번 작업은 R-46을 좁혀진 채 명시적으로 수용하고, 도구의 ③-b2 재조회를 보존한다.
- **랜딩된 역사 문서의 R-46 서술 정정**: `docs/bugfixes/bump-poll-duplicate-pr.md`와 그 verification.md는 과거
  추론의 스냅샷이므로 손대지 않는다. 현재 권위 서술은 이 스펙과 정정된 실행기 주석이다.

## Further Notes

- **왜 provider 능력을 실측했나**: fine-grained PAT/App 능력은 실제 시도로만 확인된다(traps-detail.md). provider
  v6.12.1 스키마를 백엔드 없이 덤프해 `github_repository_ruleset`·`github_app` data source·bypass_actors 형태를
  확인했다. data source id가 Integration actor로 실제 동작하는지는 owner-local apply의 실측 항목(Seam C ④)이다.
- **creation/update만 걸면 삭제 경로 무영향**: 이번 규칙 조합은 삭제를 제약하지 않으므로 `delete_branch_on_merge`가
  그대로 동작한다 — bump PR auto-merge 후 head 브랜치 자동 정리가 유지되고 고아 위험이 0이다(R-2 해소의 핵심).
- **드리프트 신호**: 적용 전까지 tf-reconcile github 드리프트 잡(plan-only, TF_GITHUB_TOKEN 설정 시)이 "생성 대기"를
  텔레그램으로 알린다 — owner apply 촉구의 의도된 동작. 적용 후엔 수동 UI 변경 시 드리프트로 표면화된다.
- **traps 원장**: 이 항목(인터록≠인증·미서명 커밋·bump-poll 예약·R-46 수용 잔여)을 `docs/traps.md`/
  `docs/traps-detail.md` 원장에 추가하고 AGENTS.md 한줄 인덱스에 반영할지 구현 단계에서 결정한다(신규 enforced
  가드이므로 원장 등재가 자연스럽다).
- **R-46은 수용된 잔여**: 이 작업의 랜딩은 R-46을 닫지 않는다. 실행기의 마지막-순간 재조회(③-b2)가 창을 좁히고,
  네임스페이스 예약이 생성/push 벡터를 닫을 뿐이다. 동시 PR 생성 자체는 서버측 수단으로도 막을 수 없다.
