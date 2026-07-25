# Design — 봉인 계약 커널 (sealed-wiring deepening)

slug: sealed-wiring
branch: deepen/sealed-wiring (main 기반)
origin: `/deepen` 아키텍처 패스 2026-07-24 — 6영역 Explore 탐사 24후보 중 적대 검증 생존 3건의 하나
성격: **행동 보존 구조 심화(PR-B) + 게이트 신설(PR-A)** — codebase-design: 복제된 정책 → deep module

## Problem — 같은 정책이 두 콜사이트에 통째로

`apps/<app>/deploy/prod`의 봉인본을 배포에 편입하는 절차가 `tools/create-app.ts`(최초 배선)와
`tools/update-secrets.ts`(재배선)에 **각각 통째로** 구현돼 있다. 실측한 복제:

| 조각 | create-app.ts | update-secrets.ts | 성질 |
|---|---|---|---|
| 봉인 계약 5검증 | `:144-150` | `:49-56` | **에러 문구까지 바이트 동일** (4문구) |
| checksum 식 | `:172` | `:58` | 동일 — `sha256(raw).slice(0,16)` |
| 이름 규약 | `:146`,`:198` | `:51`,`:59-60` | `<app>-secrets` / `<app>-secrets.sealed.yaml` |
| 디스크 기록 | `:200` `writeFileSync(sealedRaw)` | `:77` `copyFileSync(src,dst)` | **서로 다른 기전** |
| envFrom 배선 | `:159-160` 신규 생성 | `:64-68` 멱등 push | 모드가 다름(정당) |
| kustomization | `:195-199` `toYaml` 신규 작성 | `:74` `addResource` 주석 보존 편집 | 구조가 다름(정당) |

### 이 복제가 실제로 터진 이력

- **#299(`6dde56c`)** — 그 이전 create-app은 `toYaml(sealedDoc)`(**재직렬화본**)을 해시하고 디스크에도
  재직렬화본을 썼고, update-secrets는 원본 바이트를 썼다. 같은 봉인본에 **다른 checksum + 다른 파일 바이트**.
  파일 생성(2026-06-28)부터 2026-07-06까지 **약 2개월 존속**. 깨진 것은
  **`checksum/secrets` ≡ `sha256(디스크에 있는 바이트)`** 불변식이다.
- 이 불변식을 지금 지키는 것은 **사후 셸 게이트뿐**이다 — `scripts/check-app-deploy.sh:28-42`가
  커밋된 파일에서 checksum을 **재산출해 대조**한다. 즉 정합은 코드 구조가 아니라 외부 오라클이 떠받친다.

> 정정(중요): `check-app-deploy.sh` 헤더의 "#277 재발 방지"를 이 복제의 증거로 삼으면 **오귀속**이다.
> `ad9df64`(#282) 실측 — #277의 근본원인은 **두 툴을 모두 우회한 수작업 재봉인**이다. 그 게이트는
> 3번째 경로(사람 손)를 겨냥한 독립 오라클이며, 이 deepening으로 #277이 막히지는 않는다.
> 이 설계의 근거는 어디까지나 **#299**다.

### 테스트 표면이 잘못된 자리에 있다

같은 정책 단언이 **두 벌**이고, 각각 픽스처 레포를 통째로 조립해 **프로세스 경계 밖**에서 검증한다:

| 정책 단언 | create-app | update-secrets |
|---|---|---|
| `rejects invalid sealed key names` | `test_create-app.bats:184` | `test_update-secrets.bats:52` |
| `allows DATABASE_ADMIN_URL when already sealed` | `test_create-app.bats:198` | `test_update-secrets.bats:89` |

codebase-design: **"인터페이스를 지나쳐 테스트해야 한다면 모듈 모양이 틀렸다"**의 전형이다.

### 배선 축은 어떤 게이트도 보지 않는다

`check-app-deploy.sh`는 **checksum 축만** 본다. 다음 둘을 잡는 게이트는 레포에 **0개**다:

- 봉인본이 있는데 `values.envFrom`에 `<app>-secrets` secretRef가 **없다**
- 봉인본이 있는데 `kustomization.resources`에 **등재되지 않았다**

그리고 이 축은 **손편집 표면**이다 — `envFrom`은 공유 리스트로, 앱 자체 시크릿 외에 conn 시크릿이 함께 산다.
`provision-db.ts:110`·`provision-cache.ts:235`는 envFrom을 **쓰지 않고** "배선하라"는 체크리스트 문자열만 낸다.
`audit-orphans.ts:147`이 그 사고를 기록한다 — *"trip-mate 실재발(#211): conn이 봉인·커밋돼도 앱이 envFrom을
배선 안 하면 **어떤 게이트도 안 잡았다**"* (현재 대응은 **정보성·비차단** 리포트뿐).

### deletion test

`lib/sealed-contract.ts`를 가정하고 지우면 되살아나는 것은 **봉인 정책 지식**이다 — prod strict-scope,
`<app>-secrets` 이름 규약, UPPER_SNAKE 키 규약, sha256/16자 절단, 그리고 "해시 대상 = 디스크에 쓸 바이트".
정확히 2개 콜사이트로 재출현하고, **실제로 발산한 이력이 있다**(#299). pass-through 껍데기가 아니다 →
**concentrates**.

---

## Deepening — deep module `tools/lib/sealed-contract.ts`

### interface (seam) — 함수 1개

```ts
export type SealedFacts = {
  keys: string[];      // 정렬된 encryptedData 키(콜사이트 산출물 보고용)
  checksum: string;    // sha256(bytes) 앞 16자 — podAnnotations["checksum/secrets"]
  bytes: string;       // 디스크에 기록할 바로 그 바이트(봉인 원본 바이트)
  secretName: string;  // <app>-secrets
  sealedFile: string;  // <app>-secrets.sealed.yaml
};

export function readSealed(raw: string, app: string):
  | { ok: true; facts: SealedFacts }
  | { ok: false; why: string };
```

호출자가 배워야 하는 것은 **함수 하나와 판별 유니온 하나**다. 그 뒤에 봉인 계약 전부가 숨는다.

### 소유 경계

| | 소유 |
|---|---|
| **module** | 5검증 + **에러 문구** · checksum 식 · 이름 규약 · **디스크에 쓸 바이트** |
| **콜사이트** | 파일 읽기/쓰기 · exit 코드 · `::error::<tool>:` 접두 · optionality · envFrom 병합 모드 · kustomization 생성 vs 편집 |

### 핵심 불변식 — #299 클래스를 표현 불가능하게

`checksum`과 `bytes`가 **한 값에서 함께** 나오고, 두 콜사이트가 **반드시 `facts.bytes`를 쓴다**.

```ts
// 양쪽 콜사이트 공통
writeFileSync(dst, facts.bytes);
values.podAnnotations["checksum/secrets"] = facts.checksum;
```

→ "해시한 것"과 "디스크에 쓴 것"이 갈라질 수 있는 경로가 **구조적으로 없다**. 이것이 단순 중복 제거(dedup)와
depth를 가르는 선이다. 부수 효과로 `writeFileSync` vs `copyFileSync` 이중 기전도 하나로 접힌다.

### 규약 충돌과 그 해소 (명시적)

`tools/README.md:148`의 절 제목이 `lib/` 규약을 이렇게 못박는다:

> **공유 형식 커널 (lib/ — 콜사이트가 정책 소유)** … 순수 형식 판정과 왕복만 소유하고
> **파일 I/O·exit·에러 문구는 콜사이트가 소유한다**

이 설계는 **에러 문구를 module로 옮기므로 그 문장과 충돌한다**. 해소:

- `image-pin.ts`가 문구를 콜사이트에 남긴 이유는 **그쪽 정책이 형식 판정뿐이고 결과가 콜사이트마다 다르기**
  때문이다(폴링 skip vs 배포 거부). 여기는 **두 콜사이트가 같은 정책을 같은 문구로** 판정한다.
- codebase-design 기준으로 **에러 모드는 interface의 일부**다. 문구가 콜사이트에 남으면 바이트 동일 복제의
  절반(문구 4개)이 그대로 남고 드리프트 표면도 남는다.
- → `tools/README.md` 해당 문장에 **단서를 단다**: "정책이 콜사이트마다 갈리는 경우"로 한정하고,
  정책이 동일한 커널(`sealed-contract`)은 문구까지 소유한다고 명시.

### rule-of-two / ADR

- 제안 seam을 가로지르는 소비자 **n=2**(create-app 그린필드 구성 · update-secrets 제자리 병합) — 둘 다
  라이브 워크플로에서 실행된다. `docs/decisions/0004-golden-path-rule-of-two.md`의 최소선을 통과한다.
- ADR-0004는 **공유 Helm 차트 스키마 확장** 건이라 이 설계는 그 결정의 재론이 아니다.
- ADR-0001(시크릿 하이브리드)과도 무관 — 채널 선택이 아니라 배선 절차의 구조다.

### 봉인 계약과 scope — 정책 강화 (design-r1 R-2 Accept, PR-C)

> **개정** — 최초안은 `namespace === "prod"` 등호 검사를 **strict-scope**라 불렀다. 에러 문구도 문자 그대로
> `strict-scope`다. 그런데 **등호는 scope를 강제하지 않는다** — kubeseal은 어노테이션으로 scope를 넓힌다:
> `sealedsecrets.bitnami.com/namespace-wide: "true"` · `sealedsecrets.bitnami.com/cluster-wide: "true"`.
> 기대한 namespace·name을 그대로 두고 cluster-wide만 붙인 봉인본은 **5검증을 전부 통과**하면서 실제로는
> 아무 이름·아무 네임스페이스에서 복호화된다(암호문 재사용 가능) → 이름/네임스페이스 격리가 무너진다.
> 즉 interface가 **지키지 않는 것을 주장하고 있었다**.

`readSealed`가 scope 어노테이션을 **거부**한다 — `namespace-wide`·`cluster-wide` 및 호환 표기 전부.
scope를 **봉인 계약의 6번째 조항**으로 승격한다.

**born-green 실측** — 이 레포의 두 봉인 경로 모두 `--scope` 없이 kubeseal을 부르므로 strict 기본이고
어노테이션을 만들지 않는다:

- `tools/lib/seal.ts:7` — `kubeseal --cert <cert> --format yaml` (db/cache conn 봉인)
- `tools/seal-secret.mts:77` — 동일 인자 (앱 시크릿 봉인, 템플릿에도 동봉된 사본)
- 라이브 봉인본 scope 어노테이션 **0건**. (`sealedsecrets.bitnami.com/patch`는 argocd extras의 **다른**
  어노테이션 — patch 모드이지 scope가 아니다. 이 검사에 걸리면 안 된다.)

**성격 분류 — 행위 보존이 아니라 의도적 정책 강화.** 지금 통과하는 입력을 앞으로 거부하게 된다(라이브에는
그런 입력이 없어 green이지만, 성격은 명백히 tightening이다). 그래서 **PR-B에 넣지 않는다** — PR-B는 순수
행위 보존이어야 리뷰에서 "green이 당연한가"를 분리 판단할 수 있다. 별도 **PR-C**로 낸다.

---

## 게이트 — 배선 축 fail-closed (PR-A)

> **개정(design-r1 R-1 Accept)** — 최초안은 "봉인본이 **존재할 때만** 검사"라는 **단방향**이었다.
> 그러면 봉인본과 kustomization 항목만 지우고 `envFrom`·`checksum`을 남긴 부분 상태가 게이트를 **통과**한다.
> 그 상태에서 ArgoCD가 SealedSecret과 파생 Secret을 prune하면 기존 파드는 낡은 환경값을 들고 살아 있다가
> **다음 재시작에서 죽고**, 반대로 없는 파일을 가리키는 `resources` 항목은 kustomize 렌더를 깨뜨린다.
> → **쌍조건(all-or-none) 상태 모델**로 다시 쓴다.

`scripts/check-app-deploy.sh`가 앱 배포 디렉토리마다 다음 **네 사실**을 한 덩어리로 본다:

| 축 | 사실 |
|---|---|
| S | `<app>-secrets.sealed.yaml` 파일이 존재한다 |
| E | `values.yaml`의 `envFrom`에 `secretRef.name == <app>-secrets`가 있다 |
| K | `kustomization.yaml`의 `resources`에 `<app>-secrets.sealed.yaml`이 등재돼 있다 |
| C | `values.yaml`에 `podAnnotations["checksum/secrets"]`가 있고 `sha256(봉인본)` 앞 16자와 일치한다 |

> **재개정(design-r2 R-3 Accept)** — 직전 개정은 불변식을 `S ⟺ E ∧ K ∧ C`로 적었는데 **이건 all-or-none이
> 아니다**. 반례: `S=거짓 · E=참 · K=거짓 · C=거짓` → 좌변 거짓, 우변 거짓 → 쌍조건 **참** → 통과. 그런데
> 이 상태는 아래 픽스처 표가 FAIL이라 적은 바로 그 부분 삭제 상태다(봉인본은 지웠는데 `envFrom`이 남음).
> 수식을 따라 구현하면 R-1이 그대로 되살아난다. → **네 사실의 명시적 동치**로 다시 쓴다.

**C축 분해** — `C`는 두 사실을 뭉뚱그리고 있었다. ¬S 분기에는 해시할 봉인본이 없어 "일치"가 무의미하므로
상태 판정에는 존재 여부만 쓴다:

- `C_present` — `values.yaml`에 `podAnnotations["checksum/secrets"]`가 **있다**
- `C_match` — 그 값이 `sha256(봉인본)` 앞 16자와 **일치한다** (S가 참일 때만 의미가 있다)

**불변식(두 조항):**

```
① 상태 동치:  (S ∧ E ∧ K ∧ C_present) ∨ (¬S ∧ ¬E ∧ ¬K ∧ ¬C_present)
② 값 정합:    S → C_match
```

①은 네 사실의 진리표 **16상태 중 2개만** 허용하고 **혼합 14개를 전부 거부**한다. ②는 기존
`check-app-deploy.sh:28-42`의 재산출 대조를 그대로 흡수한다(현행 동작 보존). 위반 시 어느 축이 어긋났는지
이름으로 보고한다(예: `S=없음 E=있음` → "봉인본이 없는데 envFrom에 secretRef가 남아 있다").

- **정방향 위반**(S 참인데 E·K·C_present 중 결손): 배선 누락 — 봉인본이 클러스터에 뜨지만 앱이 소비하지 않는다.
- **역방향 위반**(S 거짓인데 E·K·C_present 중 잔존): 부분 삭제 — 위 개정 문단의 두 파손 경로.

**파일명 규약** — 앱 배포 디렉토리의 봉인본 이름은 `<app>-secrets.sealed.yaml` 하나뿐이다. 규약을 벗어난
`*.sealed.yaml`이 있으면 거부한다. (범위 최소화: 이 검사의 값은 kustomize 렌더가 죽기 **전에** CI에서 잡는
것이지 별도 설계 축이 아니다.)

**왜 module이 아니라 게이트인가** — 이 축의 실패 경로는 손편집이다(#211/#277 클래스). module은 툴을 통과하는
경로만 덮고 사람이 파일을 직접 고치는 경로를 **구조적으로 덮을 수 없다**. 게이트가 옳은 adapter다.

### scope 거부 — 게이트 쪽 절반 (design-r1 R-2 Accept)

같은 게이트가 봉인본의 **scope 어노테이션**도 거부한다 — 아래 "봉인 계약과 scope" 참고. 게이트는 커밋된
레포 상태를 보고, `readSealed`(PR-C)는 툴 경로를 본다. 두 adapter가 같은 정책을 양쪽에서 닫는다.

**born-green 실측** — 현행 앱 2개 모두 정합(검증 완료):

| 앱 | sealed | envFrom `<app>-secrets` | kustomization.resources | checksum |
|---|---|---|---|---|
| page | 있음 | 있음 | 있음 | 있음 |
| trip-mate-api | 있음 | 있음 | 있음 | 있음 |

**주의** — `envFrom`은 **공유 리스트**다(trip-mate-api는 `db-trip-mate-conn`·`cache-trip-mate-conn`도 보유).
단언은 "**아무** secretRef가 있는가"가 아니라 "**`<app>-secrets`가 그 중에 있는가"여야 한다.

**범위 밖** — conn 시크릿 축(#211). `audit-orphans`의 `unreferenced-conn`은 **정보성 유지**한다. 앱이 DB 없이
정당하게 돌 수 있어 차단화는 별개 판단이 필요하고, 이 deepening과 다른 축이다.

---

## 테스트 전략 — 인터페이스가 곧 test surface

### 신설 `tools/tests/test_sealed-contract.bats`

정책 매트릭스를 **직접 import**로 소유한다. 선례는 `tools/tests/test_image-pin-lib.bats:7-12`
(`bun -e`로 lib를 import해 인터페이스를 단언하는 관용구) — 픽스처 레포 조립 비용이 0이다.

- `kind !== SealedSecret` 거부
- `namespace !== prod` 거부(strict-scope)
- `name !== <app>-secrets` 거부
- `encryptedData` 비었음 거부
- 키가 UPPER_SNAKE가 아님 거부 (+ `DATABASE_ADMIN_URL` 같은 정당한 키 통과)
- `checksum === sha256(bytes)` 앞 16자
- **`facts.bytes === raw`** (왕복 — #299 회귀 잠금)

**PR-C에서 추가**(정책 강화 — 이 PR 전에는 통과하던 입력):

- `sealedsecrets.bitnami.com/cluster-wide: "true"` 거부
- `sealedsecrets.bitnami.com/namespace-wide: "true"` 거부
- 호환 표기 거부(어노테이션 값의 대소문자·따옴표 변형 포함)
- **음성 회귀**: `sealedsecrets.bitnami.com/patch: "true"`는 **통과해야 한다**(scope가 아닌 patch 모드 —
  argocd extras 선례가 실재하므로 오탐 시 그 컴포넌트를 깨뜨린다)

### 기존 스위트

- `test_create-app.bats` / `test_update-secrets.bats`: **위임 증인 1개씩만** 보유 —
  "봉인 계약 거부가 exit 1 + 자기 `::error::` 접두로 전파된다". 이건 콜사이트 고유의 interface 사실이다.
- **삭제**: `test_create-app.bats:184`,`:198` / `test_update-secrets.bats:52`,`:89` (정책 단언 2쌍).
- **유지**: 원본 바이트 기록(`test_create-app.bats:154`)·checksum 게이트 정합(`:136`)·배선(`:104`,`:121`) —
  이들은 콜사이트 행동이지 봉인 계약 정책이 아니다.

### 게이트 테스트 (PR-A) — 양방향

`tests/gates/`의 check-app-deploy 스위트에 red-green 픽스처. 불변식 ①이 진리표이므로 **16상태를 전수**로 태운다
(design-r2 R-3: "reject all 14 mixed truth-table states"). 표를 손으로 나열하지 않고 **진리표 루프**로 구동한다 —
`S E K C_present` 4비트를 0000~1111로 돌며 픽스처를 조립하고, `0000`·`1111`만 PASS, 나머지 14는 FAIL을 단언한다.
(bash 3.2 제약 — `[[ ]]`·`mapfile` 금지, 단일 대괄호 + `check-bats-style` 규율 준수.)

| S | E | K | C_present | 기대 | 의미 |
|---|---|---|---|---|---|
| 0 | 0 | 0 | 0 | **PASS** | 시크릿 없는 앱 — `create-app` optionality |
| 1 | 1 | 1 | 1 | **PASS** | 완전 배선 — 현행 page·trip-mate-api |
| 나머지 14조합 | | | | **FAIL** | 부분 상태 — 어느 축이 어긋났는지 이름으로 보고 |

특히 확인할 대표 혼합 상태(루프가 자동 포함하지만 실패 시 진단을 위해 이름을 남긴다):

- `S=0 E=1 K=0 C=0` — **design-r2 R-3의 반례**. 옛 수식(`S ⟺ E ∧ K ∧ C`)이 통과시키던 바로 그 상태.
- `S=0 E=0 K=1 C=0` — dangling `resources` → kustomize 렌더 파손
- `S=1 E=0 K=1 C=1` — 배선 누락(봉인본은 뜨는데 앱이 소비 안 함)

**불변식 ② 별도 픽스처** — `S=1`에서 `C_match` 불일치 → FAIL (기존 `check-app-deploy.sh` 동작 보존 회귀).

**축 밖 픽스처:**

| 픽스처 | 기대 |
|---|---|
| 규약 외 `*.sealed.yaml` 존재 | FAIL |
| 봉인본에 `cluster-wide`/`namespace-wide` 어노테이션 | FAIL |
| 봉인본에 `sealedsecrets.bitnami.com/patch` | PASS (scope 아님 — argocd extras 선례 보호) |

### 등록 의무

새 `test_*.bats`는 `scripts/check-bats-accounting.sh`가 gate/chart-test/`.ci-exclude` **정확히 한 도메인**
소속을 강제한다 → gate 도메인 편입 필요. 새 lib 모듈은 `tools/README.md`의 `lib/` 절에 등재.

---

## 도메인 용어 — CONTEXT.md `봉인 계약` 절 신설 (PR-B)

현행 CONTEXT.md는 배포 핀 계열 6용어만 갖는다. 이 개념은 지금 코드 주석·에러 문구·게이트 메시지에
**이름 없이** 흩어져 있다. 신설할 4용어:

- **봉인 계약(sealed contract)** — SealedSecret이 앱 배포에 편입되기 위해 만족해야 하는 규약:
  `kind: SealedSecret` · `namespace: prod` · `name: <app>-secrets` · `encryptedData` 비었음 금지 ·
  키 UPPER_SNAKE · **strict scope**(아래). _Avoid_: 시크릿 검증, sealed 스키마
- **strict scope** — 봉인본이 **그 이름·그 네임스페이스에서만** 복호화된다는 성질. kubeseal 기본값이며,
  `sealedsecrets.bitnami.com/namespace-wide`·`cluster-wide` 어노테이션이 이를 넓힌다 — 봉인 계약은 그
  어노테이션을 **거부**한다. `namespace: prod` 등호는 strict scope를 함의하지 않는다(design-r1 R-2).
  _Avoid_: prod 스코프, 네임스페이스 검증
- **봉인 원본 바이트** — 디스크에 기록되고 checksum이 계산되는 바로 그 바이트. _Avoid_: 봉인본 내용
- **checksum/secrets** — 선언적 회전 트리거 pod annotation = `sha256(봉인 원본 바이트)` 앞 16자.
  _Avoid_: 시크릿 해시
- **배선(wiring)** — 봉인본을 `values.envFrom`과 `kustomization.resources`가 참조하게 만드는 것.
  _Avoid_: 연결, 등록

---

## PR 슬라이싱 — 3개 순차 (스택 금지)

레포 함정: squash 머지 시 의존 PR이 자동 CLOSE된다 → **스택 금지, 순차 머지**.

> **개정(design-r1)** — 최초안은 2개였다. R-2가 요구한 scope 거부는 **행위 보존이 아니라 정책 강화**라,
> PR-B에 섞으면 PR-B의 "순수 행위 보존" 성질이 깨진다(Q7에서 고른 분리 근거 그대로). 그래서 3분할한다.

| PR | 성격 | 내용 |
|---|---|---|
| **PR-A** | 행위 변경 (게이트) | `scripts/check-app-deploy.sh`를 **불변식 ①·②**(위 "게이트" 절 — `(S∧E∧K∧C_present) ∨ (¬S∧¬E∧¬K∧¬C_present)` + `S → C_match`)로 재작성 + 파일명 규약 + **scope 어노테이션 거부(게이트 쪽 절반)** + 16상태 진리표 게이트 bats. born-green(현행 앱 2/2). |
| **PR-B** | **순수 행위 보존** | `tools/lib/sealed-contract.ts` 신설 · create-app/update-secrets 이주 · `test_sealed-contract.bats` 신설 · 중복 단언 2쌍 삭제 + 위임 증인 2개 · `tools/README.md` lib 절 단서 · `CONTEXT.md` 봉인 계약 절. **거부 문구·산출 바이트 전부 동일.** |
| **PR-C** | 행위 변경 (정책 강화) | `readSealed`에 scope 어노테이션 거부 추가 + 전용 테스트(양성 3 · `patch` 음성 1) + `CONTEXT.md` strict scope 용어. |

**순서 근거** — 게이트가 먼저인 것은 리뷰 표면 분리다. PR-B는 순수 행위 보존이어야 "green이 당연한가"를
분리 판단할 수 있다. PR-C는 PR-B가 만든 `readSealed`에 얹으므로 **PR-B 이후**여야 한다(유일한 실제 의존).
PR-A↔PR-B 사이엔 기술적 의존이 없다 — 게이트는 커밋된 `apps/` 디렉토리를 보지 툴 출력을 보지 않는다.

---

## 행동 보존 불변식 (PR-B가 깨면 안 되는 것 — PR-A/PR-C는 의도적 예외)

- 4개 거부 문구의 **문자열이 그대로**여야 한다(양쪽 콜사이트의 관측 가능한 행동).
- 콜사이트별 종료 규약 유지 — `create-app`/`update-secrets` 모두 `::error::<tool>: <why>` + exit 1.
- `create-app`의 optionality 유지 — 봉인본 없는 앱은 `envFrom`·`kustomization.resources` 없이 산출.
- 디스크에 기록되는 봉인본 바이트가 **현재와 동일**해야 한다(`test_create-app.bats:154` 회귀 잠금).
- `check-app-deploy.sh` checksum 재산출 대조가 계속 통과해야 한다.
- 산출 JSON(`keys`·`checksum`)의 형태 유지 — 워크플로가 소비한다.

## 검토된 뒤 기각한 대안

| 대안 | 기각 사유 |
|---|---|
| module이 순수 판정만(불리언), 문구는 콜사이트 | 바이트 동일 복제의 절반(문구 4개)이 남고 드리프트 표면이 그대로 |
| module이 배선까지(`mode: create\|update` 인자) | 모드 플래그가 interface로 올라와 호출자가 내부 분기를 알게 됨 = shallow |
| module이 파일 I/O까지 | lib가 fs를 잡아 테스트가 다시 픽스처 디렉토리를 요구 — 직접 import 이득 상실 |
| 이름 규약을 별도 함수로 분리 | 두 콜사이트 모두 봉인본이 있을 때만 이름을 쓴다 → 소비자 없는 분리, interface만 넓어짐 |
| optionality를 module이 흡수(`raw: string \| null`) | update-secrets는 null이면 실패해야 함 → 두 모드 분기가 interface로 올라옴 |
| 게이트 없이 module만 | 검증자가 이 후보를 살린 결정적 근거(미커버 배선 축)를 포기 |
| conn 축(`unreferenced-conn`)까지 차단화 | 다른 축 — 앱이 DB 없이 정당하게 돌 수 있어 별도 판단 필요 |
| 게이트를 단방향(S 있을 때만 검사)으로 유지 | design-r1 R-1 — 부분 삭제 상태가 통과한다(파드 낡은 값 생존 → 재시작 사망 / dangling resource → 렌더 파손) |
| scope 거부를 PR-B에 함께 넣어 2-PR 유지 | design-r1 R-2 — 정책 강화라 PR-B의 순수 행위 보존 성질이 깨진다. 왕복 비용보다 리뷰 분리 가치가 크다고 판단(사용자 확정) |
| `namespace === "prod"` 등호를 strict scope로 계속 간주 | design-r1 R-2 — 등호는 scope를 함의하지 않는다. cluster-wide 어노테이션이 붙은 봉인본이 5검증을 전부 통과한다 |

## 정직한 약점

- **부피가 작다** — 실질 중복 ~15줄 → module ~35줄. 이득의 상당 부분은 테스트 복제 제거와 불변식 구조화다.
- **발산은 이미 수렴됐다**(#299) — 이 설계는 재발을 *구조적으로* 막지만, 그 클래스는 지금 셸 오라클이 덮고 있다.
- **커플드 처언이 희박하다** — 두 파일을 동시에 만진 커밋은 `009b1be`·`49412fe` 2건(둘 다 2026-06-28)뿐이고,
  `update-secrets.ts`는 생애 3커밋·2026-07-03 이후 무변경. 1인 홈랩이라 "또 갈릴" 압력은 팀 환경보다 낮다.
- 따라서 강도는 **Strong이 아니라 Worth exploring**이다. 이 문서는 그 전제 위에 쓰였다.
