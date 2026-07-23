# Triage 결정 — bump-poll-ruleset (F-0)

### plan r1

R-1 accept — R-46 is neither blocked nor neutralized; spec의 "중화(neutralize)" 표현 제거, "F-0은 비-writer의 ref 생성/push/삭제만 닫고 R-46은 좁혀졌으나 원천 차단 안 된 명시적 수용 잔여"로 정정; 실행기 재조회 보존; `tools/ensure-bump-pr.ts` R-46 주석은 Stage 4에서 완화; 랜딩된 `docs/bugfixes/bump-poll-duplicate-pr.md`(역사 기록)는 미수정.
R-2 accept — rollout has no safe deletion fallback; 해소 경로 (b): 이번 increment는 creation+update만 배포, deletion=true는 멱등 writer-App 정리 경로 설계·검증 후 후속 increment로 연기.

### structure r1

S-1 accept — regression gate stays green when boundary disabled/widened; 구조 bats를 파일 전역 토큰 검색 → SSOT 가드 함수(정확·앵커·카운트: 리소스/bypass/actor_id 각 1개·target=branch·include 단일원소·exclude=[]·enforcement active·actor_id=tonumber(data.github_app.writer.id)·Integration·always·broad-role 금지)로 재작성 + 뮤테이션 증인(target→tag·include 확대·2번째 bypass·enforcement 주석처리·actor_id 하드코딩·broad-role)이 가드 실패를 증명. deletion 단언은 계속 제외(spec R-2).

### structure r1 — S-1 fix 심화 (red-team)

S-1 fix 후 8각도 red-team(workflow, opus)이 강화된 grep 가드도 8/8 우회(간접화+decoy·meta-arg count/for_each·주석 2차 bypass·identity redirect via decoy data source·cross-file slug redirect·decoy-locals include/exclude). 근본 교훈: 정적 텍스트 가드는 HCL resolved 의미 검증 불가. → 가드를 **canonical-form freeze**(3 보안블록 추출→주석제거→공백정규화→핀된 canonical 정확일치)로 재설계. 10 뮤테이션 증인+대조군으로 8 클래스 전부 차단 실측. spec Seam B/C를 정직한 한계(변경 감지기 vs Seam C 권위 검증)로 동기화.

### structure r2

S-2 accept — canonical extraction ignores HCL module context: (a) 리소스를 /* */로 감싸면 canonical 일치인데 terraform은 주석처리로 봄, (b) 추적 *_override.tf가 count=0/enforcement disable로 병합. 둘 다 실측 확인. → 가드를 3층(canonical freeze + no-block-comments(문자열 blank 후 /* 금지) + no-override(추적 override 파일 0 + .gitignore *_override.tf)}로 확장, 두 클래스 증인 추가(16/16 green). spec Seam B/C를 3층+정직한 잔여(removed/plan/tfvars → CI 검증 불가, Seam C가 완전 보증)로 갱신.
WAIVED by user: structure re-review(round 3) 면제. 근거 = 정적 CI 가드의 완전성은 신뢰 앵커 root에서 원리적으로 불가(완전 검증=terraform plan=CI에서 배제된 자격 필요). 추가 라운드는 무한 static hole만 더 찾을 뿐이며, resolved 의미의 권위·필수 검증은 owner-local Seam C다. 찾은 전 클래스는 3층+증인으로 차단.

### release r1

RL-1 accept (high) — Seam C 프로브가 auth 실패를 ruleset 거부로 오인 가능 + 토큰 argv/history 유출. verification.md B2-B4를 안전 인증(GIT_ASKPASS+env·GIT_TERMINAL_PROMPT=0·credential.helper 비활성)으로 재작성 + 실패가 ruleset 위반(GH006/repository rule)임을 명시 검증(is_ruleset_reject) + writer ref B4 재사용/정리.
RL-2 accept (medium) — writer_app_slug 리네임-override가 실행기 신원(bump-poll.yaml git 신원·ensure-bump-pr DEFAULT_WRITER)과 분리돼 end-to-end 미배선. 3곳 배선은 범위 밖 → tfvars.example·variables.tf 주석에서 standalone override 광고 제거, 리네임은 3곳 동시 갱신 필요(아니면 fail-closed)로 정정.
RL-3 accept (low) — tools/README.md가 여전히 "잔여는 F-0"로 과대주장(현행 운영 문서). ensure-bump-pr.ts와 동일 표현("F-0는 노출을 좁힐 뿐 동시 PR 생성은 수용된 R-46 잔여")으로 정정.

### release r2

RL-2·RL-3 fixed 확인(retain). RL-1은 두 갈래로 여전히 열림 — 둘 다 accept:
RL-1a accept (high) — 헬퍼가 토큰을 $1로 받아 operator가 리터럴 토큰을 타이핑 → shell history 유출(GIT_ASKPASS는 git URL/argv에서만 뺌). 수정: `read -s`로 env(OWNER_PAT/WRITER_TOKEN) 로드, gpush는 역할 이름만 받아 env 해석(시크릿-값 인자 0), 끝에 unset. 명령엔 이름만.
RL-1b accept (high) — B3(writer 생성) 실패 시 B4가 없는 ref를 타깃해 creation을 재시험, 범용 매처가 그걸 update 성공으로 오인(거짓 인증). 수정: B3 실패 시 즉시 중단 + B4 전 `git ls-remote`로 ref 실재 확인 + commit-tree로 다른 OID force-push(진짜 update) + nonzero AND ruleset 위반 둘 다여야 성공 기록.
자체 dry-run: 함수 구문 OK·commit-tree≠HEAD·is_ruleset_reject가 ruleset 3종 매치/auth 2종 미매치.
★ round 3 승인(사용자 옵션 a) — S-2 waiver와 달리 완전 닫히는 절차 버그라 독립 재검증 유의미.

### release r3

RL-1a fixed 확인(닫힘). RL-1b는 재적발 — accept:
RL-1b (high, 재적발) — `return 1`을 최상위 bash 스니펫에 써서 abort 안 됨(최상위 return 무효 → 계속 실행 → B3 실패 후 성공 출력·ls-remote 빈 결과 후 owner push로 creation 재시험→update 오검증). 수정: B2–B4를 함수 `probe_enforcement()`로 감싸 return이 실제 종료하게 함.
★ 실행 가능 dry-run 증명(문서 함수 그대로 추출, gpush/git mock): ①B3 실패 rc=1·commit-tree 0·owner-force 0·거짓성공 0 ②ls-remote 빈 rc=1·commit-tree 0·owner-force 0·거짓성공 0 ③정상 rc=0·통과. → B3 실패·ref 부재가 commit-tree/owner-push/성공에 도달 못 함을 실증(리뷰어 요청 충족).
WAIVED by user: release round 4 면제. 근거 = RL-1b가 판단이 아니라 실행 증거로 닫힘(dry-run이 abort 실증). RL-1a 닫힘·RL-2/RL-3 fixed. 정적 검증은 여기까지, resolved 강제는 owner-local Seam C(이제 안전·정확).

### structure r1 (chore/pin-writer-app-id — App ID 하드코딩)

R-1 accept (as proposed·부분 조정) — Authoritative Seam C still depends on the removed slug resolver. verification.md는 살아있는 owner-local 기록이라 리터럴-ID 설계로 갱신(data source 제거→classic 오버라이드 불요, fine-grained 404 근거는 역사적, id=19598965 apply 보존 + fine-grained·classic No changes 실측·App ID 4043080 신원 추가). spec.md는 F-0 원안 point-in-time 아카이브라 전면 재작성 대신 forward-pointer 노트(재도입 방지)만 추가.

### structure r2 (재검증 — cold)
verdict=approve · findings=0. R-1(verification/spec 갱신) resolved 확인 · fix 신규 결함 0. 게이트 통과.
