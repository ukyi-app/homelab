# 설계: 시크릿 관리 하이브리드 명료화 (Hybrid Clarification)

- 날짜: 2026-06-15
- 상태: 승인됨 (brainstorming Phase A 완료)
- 후속: writing-plans → codex 적대적 리뷰(hardened-planning Phase C)

## 1. 배경과 원래 요청

원래 요청은 **"SealedSecrets로 통일하고 싶어"** — SOPS/KSOPS와 SealedSecrets로 이원화된
시크릿 관리를 SealedSecrets 하나로 통일하는 것이었다. 통일 방향(복구 모델·컷오버·폐기 범위)에
대한 결정까지 받은 뒤("age 콜드 보관 유지 / 컴포넌트단위 점진 전환 / 전면 스윗"), **"이 방법이
최선이야?"** 라는 질문에 따라 진행 중 plan을 방어하지 않고 후보 접근법을 독립·적대적으로
재평가했다.

## 2. 결정: 통일 폐기, 하이브리드 유지 + 명료화

독립 판정단(6 에이전트)이 네 후보를 이 홈랩의 실제 제약에 근거해 평가한 결과:

| 후보 | 점수 | 판정 |
|---|---|---|
| A. SealedSecrets 통일 (원래 요청) | 3/10 | avoid |
| B. SOPS/KSOPS 통일 (반대 방향) | 3/10 | avoid |
| **C. 하이브리드 유지 (현상)** | **8/10** | **recommend** |
| D. ESO + 외부 시크릿 저장소 | 3/10 | avoid |

**A(SealedSecrets 통일)가 가장 불리한 거래인 이유:**

1. 이 홈랩의 가장 검증된 DR 자산("`git + R2 + age 키 한 장`으로 컨트롤러 없이 전 스택 오프라인
   복구", dr-drill PASS)을 코어 7개 시크릿에서 폐기하고, 단일 컨트롤러 + 봉인키 선복구 순서
   제약으로 후퇴시킨다. 이는 SOPS에 없는 실패 모드(봉인키 복구 전 컨트롤러가 새 키 생성 → 전
   시크릿 영구 복호 불능)를 코어 경로에 들인다.
2. PR #9(`9a73bfa`, 봉인 cert 재동기화)이 이미 SealedSecrets 복구 경로가 더 취약하다는 라이브
   증거다. 특히 `r2-creds`가 SealedSecret이면 자기참조 위험 — DR이 R2에서 백업을 끌어오는데 그
   R2 자격 복호화가 "봉인키 먼저 복구 + 컨트롤러 가동"에 걸린다.
3. 통일이 보호한다는 "정합성"의 대상(커밋된 `*.sealed.yaml`)이 현재 **0개**, 프로비저닝 DB도
   **0개**. 즉 0건의 동적 자산과의 정합성을 위해 7건의 검증된 코어 자산의 DR 등급을 내리는
   비대칭 거래.
4. "age 콜드 보관" 절충은 dr-drill이 평소 운동시키는 경로(age)를 평시에서 빼 첫 위기 때 처음
   실행하는 미검증 절차로 만든다 — 운동되지 않는 백업은 신뢰 자산이 아니다.

적대적 검토에서 A를 무너뜨리는 논증은 `changesRecommendation: true`(권고를 뒤집을 만큼 강함,
severity=serious)로 살아남았고, C를 무너뜨리려는 통일론은 `changesRecommendation: false`
(미발화·증가율 통제되는 부채일 뿐, severity=minor)로 기각됐다.

**따라서 통일하지 않는다.** 대신 사용자의 진짜 동기(두 시스템의 정합성/명료성 불편)를 **DR 강자산
훼손 없이** 해소하는 저비용 정리만 수행한다.

## 3. 현재 아키텍처 (보존 대상)

이원화는 의도적이며 각 시스템을 강점 영역에 배치한 구조다:

- **platform 정적 7개 = SOPS/KSOPS (age, 렌더타임 복호화):** cloudflared tunnel, tailscale
  operator-oauth, traefik cloudflare-api-token, cnpg app-credentials/r2-creds/restore-drill-alerting,
  victoria-stack alerting. ArgoCD repo-server가 렌더 시점에 KSOPS exec 플러그인 + 마운트된 age
  키로 복호화. 인-클러스터 컨트롤러 무의존, 오프라인 2-recipient(cluster+recovery) 복구.
- **동적 app/data = SealedSecrets (공개 cert, 인-클러스터 컨트롤러):** create-app(앱 시크릿),
  provision-db/cache(연결 핸들). kubeseal + 커밋된 공개 cert(`tools/sealed-secrets-cert.pem`)만으로
  CI/PR에서 봉인 — 러너에 개인키 0(멀티레포 보안 불변식). 현재 커밋된 소비자 0개(머신만 존재).

이 경계(정적 platform=SOPS / 동적 app·data=SealedSecrets)는 SOPS가 CI 봉인에 개인키를 요구하기
때문에 **구조적으로 강제**된다 — 자의적 이원화가 아니다.

## 4. 작업 항목

### 작업 1 — 앱-시크릿 경로 일관화 (저비용)

문제: `platform/argocd/root/appset.yaml` source #3 주석이 앱 시크릿을 KSOPS `*.enc.yaml`
secret-generator로 기술하나, 현 표준 create-app(v2)은 SealedSecret(`<app>-secrets.sealed.yaml`을
`resources:`에)을 쓴다. onboard-app(v1)은 아직 KSOPS 경로를 가진다(이중 모델).

- appset.yaml source #3 주석을 현실(v2 SealedSecret)에 맞게 수정. 렌더 동작은 불변(주석만).
- onboard-app.mjs의 KSOPS 앱-시크릿 경로에 deprecation 포인터 1줄(표준 = create-app v2 +
  SealedSecret). **v1 온보딩 워크플로 전면 폐기는 범위 밖**.

### 작업 2 — sealing-key DR 경로 fail-closed 게이트 (핵심)

문제: dr-drill.sh가 sealing-key 복구를 전혀 운동시키지 않는다(age/SOPS 경로만). 현재 sealed
소비자 0개라 무해하나, 첫 소비자가 생기면 미검증 경로가 DR 크리티컬 패스로 진입한다.

- dr-drill.sh에 트리거 게이트 추가:
  - **검출:** 레포에 커밋된 `*.sealed.yaml` 소비자가 존재하는가(glob + 라이브 SealedSecret 카운트).
  - **0개 → dormant 로그 + skip**(명시적, 침묵 아님).
  - **≥1개 → sealing-key 경로 강제 운동:** `backup-sealed-secrets-key.sh --verify`(백업 신선도)
    → 재구축 클러스터에 백업 키 Secret 복원 → 컨트롤러 재시작 → 커밋된 SealedSecret이 실제
    unseal되는지 검증. 미충족 시 `DR DRILL FAIL`.
- 복구 메커니즘: sealed-secrets 컨트롤러는 라벨드 키 **전부**로 복호 가능하므로, 백업 키 Secret을
  복원하고 컨트롤러를 재시작하면 충분하다(컨트롤러가 먼저 새 키를 생성했어도 무해 — 과거 키로 복호).
- restore.md(로컬 전용 런북)에 복구 절차 명문화(복원 → 재시작 → unseal 검증 순서).

### 작업 3 — KSOPS 핀/alpha 리스크 명문화 (저비용)

`platform/argocd/bootstrap-values.yaml` 인라인 주석 추가:
- `install-ksops` initContainer가 repo-server의 kustomize 바이너리도 공급한다 — 제거 시 kustomize
  대체가 필수(미래 footgun 경고).
- `--enable-exec`는 alpha — ArgoCD/kustomize가 exec 플러그인을 폐기하면 깨진다. 관측되면 그때 대응.

## 5. 위험 등록부

| # | 위험 | 완화 |
|---|---|---|
| R1 | 작업 2 복구 순서 — 컨트롤러가 백업 복원 전 새 키 생성 시 unseal 불능 우려 | sealed-secrets는 라벨드 키 전부로 복호 → 백업 키 복원 + 재시작이면 충분(새 키 무해). bats canary로 검증 |
| R2 | sealed 소비자 0개라 작업 2 복구 경로가 라이브 미실행 → 또 미검증 | bats에서 canary SealedSecret으로 봉인→복원→재시작→unseal 라운드트립 검증(라이브 소비자 불요). 게이트의 0개 dormant 분기도 단언 |
| R3 | dr-drill 게이트 false-negative(소비자 있는데 0으로 오판) | 검출을 보수적으로(`*.sealed.yaml` glob + 라이브 카운트 양쪽), 단언 실패는 fail-closed |
| R4 | 작업 1 주석이 onboard v1 실제 동작과 또 어긋남 | v1은 deprecation 포인터만, appset 주석은 v2(현 표준) 기준으로 단일 진실 정렬 |
| R5 | 범위 크리프(통일로 회귀) | 명시 비목표(§7) — SOPS/KSOPS·enc.yaml·age 모델 무변경 |

## 6. 테스트 전략 (TDD)

- 작업 2: `tests/sealed-secrets-restore.bats` 확장 — canary SealedSecret 봉인→복원→재시작→unseal
  라운드트립. dr-drill 게이트 검출 분기(0개 dormant / ≥1개 강제)를 bats로 단언. 중간 단언은
  `[ ]`(단순 명령) — bash 3.2에서 `[[ ]]` 침묵 통과 함정 회피. `@test` 이름은 영어.
- 작업 1: appset `kustomize build` 렌더 무변경 골든(주석은 렌더에 무영향).
- 회귀: `make verify` + `make chart-test` green 유지 — SOPS 게이트(sops-roundtrip.bats 등)는
  제거하지 않고 그대로 둔다.

## 7. 비목표 (명시)

- SOPS/KSOPS 제거 ✗
- 7개 `*.enc.yaml` 재봉인/이동 ✗
- ArgoCD repo-server KSOPS 배선(initContainer·sops-age·`--enable-exec`) 제거 ✗
- age 2-recipient 복구 모델 변경 ✗
- onboard v1 온보딩 워크플로 전면 폐기 ✗
- 7개 platform 시크릿을 SealedSecrets로 전환 ✗ (통일 폐기)

## 8. 해소된 결정 사항 (의사결정 기록)

1. 복구 모델: age 키 콜드 보관 유지 — **통일 폐기로 무의미해짐**(age는 평시 라이브 경로로 유지).
2. 컷오버: 컴포넌트단위 점진 전환 — **통일 폐기로 무의미해짐**.
3. 폐기 범위: 전면 스윗 — **통일 폐기로 무의미해짐**(SOPS 자산 보존).
4. 방향: "이 방법이 최선?" → 독립 판정단 결과 **하이브리드 유지 + 저비용 정리**로 선회(사용자 승인).
