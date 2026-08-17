# 0006 — 컷오버에서 `pg` 복구 원본을 걷어내고, "쓰기≠읽기" 계약을 "쓰기 고정"으로 평행이동한다

- 상태: 수용(accepted) — 2026-08-17, 컷오버 §3-2와 같은 PR
- 관련: `platform/cnpg/prod/cluster.yaml`, `platform/cnpg/prod/test_cluster_params.bats`,
  `scripts/check-pg-servername.sh`, `tests/gates/test_pg-servername.bats`,
  `docs/traps-detail.md`(SSA atomic 리스트 항목)

## 맥락

NUC 이전 동안 `Cluster/pg`는 **두 개의 아카이브 이름**을 동시에 들고 있었다.

| 축 | 필드 | 값 | 의미 |
|---|---|---|---|
| 쓰기 | `.spec.plugins[].parameters.serverName` | `pg-nuc` | NUC이 WAL을 아카이브하는 prefix |
| 읽기 | `.spec.externalClusters[].plugin.parameters.serverName` | `pg` | 라이브 Mac이 써 온 아카이브(복구 원본) |

둘이 같아지면 **두 primary가 같은 R2 prefix에 아카이브해 타임라인이 섞이고**, R2에 버저닝이
없어(`infra/cloudflare/r2.tf`) 되돌릴 수 없다. 그래서 `test_cluster_params.bats`의 해당 @test는
이름에 **"PERMANENT, not a cutover revert item"**을 달아 두 값이 다름을 강제했다.

컷오버로 그 전제가 바뀌었다. 라이브 `pg`는 2026-08-13에 `pg-mac`에서 복구를 마쳐 timeline=2로
살아 있고(G6 달성), 복구 원본은 **1회성 목적을 다했다.** 그리고 CNPG는 `bootstrap`을 **초기화
시점에만** 읽으므로(라이브 CRD에 불변 CEL 없음 — 실측) 그 블록을 남겨두는 것은 이미 떠 있는
클러스터에 아무 효과가 없다.

## 결정

1. `bootstrap.recovery`(source: `pg-mac`)와 `externalClusters`를 **제거하고 `initdb`로 되돌린다.**
   main이 Mac 시대 내내 갖고 있던 형태이고, `postInitApplicationSQL`의 `restore_canary` 시드도
   함께 되살아난다(recovery 스키마엔 그 필드가 없어 이전 브랜치 형태에서는 빠져 있었다).
2. "PERMANENT" @test를 **삭제하지 않고 평행이동**한다. 읽기 축이 물리적으로 사라졌으므로
   남은 축을 같은 강도로 잠근다:
   - 쓰기 `serverName`을 **리터럴 `pg-nuc`로 고정**하고 `pg`로의 회귀를 음성 단언으로 거부
   - **아카이브 writer가 정확히 1개**임을 센다(0건도 red — 열거 붕괴 방지)
   - `externalClusters`의 **부재**와 `bootstrap.initdb`의 **존재**를 형태로 고정

## 왜 "축소"가 아니라 "평행이동"인가

지키려던 위험(한 prefix에 두 타임라인)은 그대로 남아 있고, 그것을 만들 수 있는 경로만
"읽기 원본과 겹침"에서 "쓰기 값 자체가 `pg`로 회귀"로 바뀌었다. 새 @test가 그 경로를 **리터럴로**
막는다. 오히려 강해진 면이 있다 — `check-pg-servername.sh`의 (B) 값 고정은 CI가 **main 진입 시에만**
env를 채우므로 로컬·브랜치에서는 무방비였는데, 이제 매니페스트 단위 @test가 항상 돈다.

⚠️ 이 ADR이 존재하는 이유 자체가 규율이다. "PERMANENT라고 써 놓은 것을 조용히 지운" 전례를
만들지 않기 위해, 계약 해제는 근거와 함께 기록될 때만 허용한다.

## 기각한 대안

**(a) `recovery.source`를 `pg-nuc` 자기참조로 바꾼다** — 콜드 재구축이 자동 복구된다는 이점이 있다.
기각 이유는 가드가 막아서가 아니라(`check-pg-servername.sh` (A)가 쓰기=읽기를 거부한다) **복구본이
자기가 복구해 온 prefix에 다시 아카이브를 시작해 타임라인이 겹치기 때문**이다. R2에 버저닝이 없어
그 오염은 되돌릴 수 없다. 아카이브가 **유일본이 되는 바로 그 국면**에 그 가드를 느슨하게 하는 거래는
값이 맞지 않는다.

**(b) 아무것도 바꾸지 않고 dangling 참조를 둔다** — 어떤 가드도 red가 아니므로 비용이 0으로 보인다.
기각 이유: `Cluster/pg`가 볼륨을 잃고 재생성되면 **얼어붙은 Mac 아카이브에서 낡은 데이터로 조용히
복구된 뒤 그것을 `pg-nuc/`에 아카이브**해 살아 있는 아카이브를 오염시킨다. `initdb`면 **빈 DB로
요란하게** 떠서 사람이 알아채고 `docs/runbooks/restore.md` 경로 A로 복구한다. 조용한 잘못된 복구보다
시끄러운 공백이 낫다는 것이 이 레포가 Mac 시대부터 유지해 온 선택이다.

**(c) PONR 1(`pg/` purge)까지 미룬다** — 시점을 맞추면 깔끔해 보인다. 기각 이유: PONR 1이
**G11 콜드스타트 증명 뒤로** 밀렸으므로(별도 결정) 그때까지 (b)의 위험을 계속 안게 된다.

## 결과

- 콜드 재구축(G11)에서 `Cluster/pg`는 **빈 DB로 뜬다.** 데이터 복구는 `docs/runbooks/restore.md`
  경로 A로 사람이 수행한다. 이것은 회귀가 아니라 복원된 원설계다.
- 🔴 **이 결정이 그 런북을 유일 복구 경로로 승격시키므로, 런북의 `serverName`이 정본과 일치하는지가
  이제 데이터 보존의 문제다.** 컷오버 전 `restore.md` 경로 A는 `serverName: pg`(Mac 아카이브)를
  적고 있었고 그건 **당시 main 기준으로는 옳았다** — 이 PR이 main의 쓰기 prefix를 `pg-nuc`로
  옮기면서 그 런북이 처음으로 틀려진다. 두 prefix가 공존하고(PONR 1 미실행) `pg`로의 복구는
  **실패하지 않고 성공**하므로, 틀린 채로 두면 컷오버 이후 전 기간의 쓰기가 조용히 사라진다.
  ⇒ 같은 작업에서 `restore.md`를 **라이브 파생**(`.spec.plugins[].parameters.serverName`)으로
  고쳤고, 경로 B의 `pgdump/` → `pgdump-nuc/`도 함께 정정했다.
  ⚠️ **그 수정은 CI가 볼 수 없다** — `docs/runbooks/`는 gitignored다(`.gitignore`). 자동 드릴
  (`restore-drill-script.sh`)만 파생을 쓰고 사람 경로는 원리적으로 무가드다. 이 문단이 그 결합을
  추적되는 자리에 남기는 유일한 기록이다. 다음에 `serverName`을 옮기는 사람은 **반드시** 런북
  경로 A·B를 함께 고쳐라.
- `s3://homelab-pg-backups-prod/pg/`(Mac 아카이브)는 **삭제되지 않는다.** PONR 1은 별도 결정으로
  G11 뒤로 미뤄져 있고, 그때까지 그 prefix는 단일 NVMe 위에 올라간 NUC에 대한 마지막 독립 사본이다.
- `restore-drill`의 canary 행 수 비교는 여전히 **상수**다(시드가 1회성이라 라이브는 영구히 1행).
  그 드릴이 진짜 복구를 했는지는 스크립트의 `SAW_NONHEALTHY` 증인이 본다(M17 / PR #482).
  **아카이브 신선도(RPO) 증명은 이 ADR의 범위 밖이고 별건으로 남는다.**
