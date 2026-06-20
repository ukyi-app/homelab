# 테마8 설계: AGENTS.md/문서 SSOT 개편

- 날짜: 2026-06-20
- 상태: 설계 승인됨(사용자 확정 2026-06-20) — Phase B(writing-plans) 진입 대상
- 워크트리: `.claude/worktrees/feat+docs-ssot-refactor` (브랜치 `worktree-feat+docs-ssot-refactor`, origin/main `37e4d19` 분기)
- 출처: 2026-06-19 홈랩 10차원 심층 감사 8테마 로드맵의 테마8 ("AGENTS.md/문서 SSOT 개편", 중/저·M)

## 1. 배경 / 문제 (4발견, 전부 라이브 grounding) — 전부 CI/문서(라이브 클러스터 무관)

| # | 발견 | 라이브 근거 |
|---|---|---|
| 1 | AGENTS.md **19KB/210줄**, '라이브에서 검증된 함정'절(L52-161, **41항목 ≈52%**) — `@AGENTS.md`로 **매 세션 1차 컨텍스트** 비용·단조증가 | `wc -c AGENTS.md`=19240, 섹션 경계, 불릿 41 |
| 2 | AGENTS.md 디렉토리 지도 `platform/` 인라인 열거에 **homepage 누락**(드리프트) — README는 `check-skeleton.sh:26-32`가 전수강제하나 AGENTS map은 **무가드 단일앵커** | L12(homepage 없음) vs README(있음, 가드됨) |
| 3 | 런북 인덱스(L194-210, 12개) ↔ 로컬 `docs/runbooks/`(gitignored) 드리프트 가드 부재(현재는 일치) | 인덱스 12 = 로컬 12 |
| 4 | 트랩 SSOT ↔ `docs/traps.md` 원장 **내용 드리프트 무가드** — `verify-traps.sh`는 guard 경로 **실재만** 검사(내용 동기화 X) | `traps.md`("AGENTS.md가 SSOT")·`verify-traps.sh` |

## 2. 목표 / 비목표

### 목표
- 트랩 prose를 **`docs/traps-detail.md`(새 SSOT, tracked)** 로 분리(progressive disclosure) — AGENTS.md는 **한줄/함정 인덱스 + 포인터**만(매 세션 컨텍스트 ↓).
- 디렉토리 지도 드리프트 해소(**README 단일화**) + 트랩 인덱스·원장·런북 인덱스 **드리프트 가드** 신설.
- **무손실**: 41개 트랩 전량 보존(하드원 지식 0 유실).

### 비목표
- 트랩 내용 자체 수정/삭제(이전만, 무손실) · 새 트랩 추가.
- App Platform 플로우절(L162-193, 이미 "요약")·컨벤션절 이동 — 트랩절만 대상.
- 트랩 ID 체계(D3=guard-path-tie 선택, ID 불요) · 런북 본문 공개(로컬 유지).

## 3. 설계: 4 수정

### 수정 1 — 트랩 prose → `docs/traps-detail.md` (SSOT) + AGENTS 인덱스 (D1)
- `docs/traps-detail.md`(신규, tracked): AGENTS L52-161의 41 트랩을 각 `### <헤드라인>` 섹션 + prose로 **무손실 이전**. 헤더에 "트랩 SSOT(AGENTS.md에서 이전)" 명시. **enforced 트랩**은 prose에 `> 가드: \`path\`` 주석(traps.md 원장의 guard 경로 — D3 guard-path-tie 결속).
- AGENTS.md L52-161 → **한줄/함정 인덱스(~41줄)**: 각 줄 = traps-detail.md 헤드라인(동일 텍스트) + 1행 요약. 절 상단에 "전문은 `docs/traps-detail.md` — 컴포넌트 작업 전 해당 항목 확인" 포인터.
- 참조 갱신: `traps.md`의 "AGENTS.md의 함정절이 SSOT" → "`docs/traps-detail.md`가 SSOT"(컬럼 헤더 `함정 (AGENTS.md)`→`(traps-detail.md)`). 기타 "AGENTS.md 라이브 함정" 포인터 grep→갱신.

### 수정 2 — 디렉토리 지도 README 단일화 (D2, 발견2)
- AGENTS.md `platform/` 행의 **인라인 컴포넌트 열거 제거** → "GitOps 컴포넌트 — 전체 목록은 README 지도(check-skeleton 강제)". homepage는 README에 이미 존재(가드됨)라 자동 정합·중복0·드리프트0.
- `tools/tests/test_dirmap.bats` 주석(L2 "README.md/AGENTS.md")에서 AGENTS.md 언급 제거(테스트는 이미 README만 검사 — 정합).

### 수정 3 — 런북 인덱스 드리프트 로컬 가드 (발견3)
- `make verify-runbooks`(또는 `scripts/verify-runbooks.sh`, **로컬 전용**): `docs/runbooks/`에 `.md`가 있으면 AGENTS.md 런북 인덱스 ↔ 실제 파일 일치 확인. 런북 gitignored라 **CI는 파일 부재로 skip**(verify-posture류 로컬 게이트 — required gate 아님, dead-green 회피).

### 수정 4 — 트랩 SSOT ↔ 원장 내용 드리프트 가드 (D3 guard-path-tie, 발견4)
- `scripts/verify-traps.sh` 확장: 기존(원장 guard 경로 **실재**) + **신규: 원장 guard 경로가 `traps-detail.md`에도 등장**(enforced 트랩이 SSOT에 부재=드리프트 차단). ID 불요 — 기존 guard 경로를 매칭 키로.
- `test_traps-sync.bats`(신규, gate): AGENTS 인덱스 ↔ traps-detail.md 헤드라인 **개수+존재 일치**(인덱스 드리프트 차단 — D1 인덱스가 새 표면이라).

## 4. 라이브 위험 / 검증

- **라이브 위험 없음** — 순수 문서/가드(ArgoCD 무관, 클러스터 무관).
- ★**핵심 리스크 = 트랩 무손실 이전**: 41항목 전량 보존(누락=하드원 지식 유실). 이전 후 **diff로 무손실 검증**(AGENTS 제거분 ⊆ traps-detail 추가분).
- **검증**: 정적 bats(`test_traps-sync`·`test_dirmap`)·`make verify-traps`(확장) — run-bats 게이트 / `make ci`. 런북 가드는 로컬(`make verify-runbooks`). homepage README 존재 확인.
- bats `@test` 영어·중간 단언 `[ ]`·bash 3.2 호환.

## 5. 결정사항

- **D1 (AGENTS 트랩 시그널)** → **한줄/함정 인덱스**(~41줄, 발견성 유지). 인덱스 드리프트는 `test_traps-sync`가 가드.
- **D2 (발견2 map 가드)** → **README 단일화**(AGENTS 인라인 열거 제거→README 포인터, 중복0·드리프트0). check-skeleton이 이미 README 강제.
- **D3 (발견4 내용드리프트)** → **guard-path-tie**(원장 guard 경로 ⊆ traps-detail.md, ID 불요). 발견3 런북은 로컬 가드.
- **A.5 생략**(문서 IA라 재작업 저비용, Phase C가 안전망).

## 6. 범위 밖 (명시)

- 트랩 내용 수정/추가 · App Platform·컨벤션절 이동 · 트랩 ID 체계 · 런북 본문 공개 · 새 critical 가드.
