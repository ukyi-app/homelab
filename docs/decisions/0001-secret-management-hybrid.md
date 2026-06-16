# 0001 — 시크릿 관리 하이브리드(SOPS + SealedSecrets) 유지

- 상태: 수용(accepted)
- 관련: `AGENTS.md`(시크릿 공급 규약), `scripts/sealing-key-dr-gate.sh`, `docs/traps.md`

## 맥락
플랫폼 시크릿은 SOPS + age(`*.enc.yaml`, recipient 2개: cluster + recovery)로,
앱 시크릿은 SealedSecrets(컨트롤러 공개키로 봉인)로 관리한다. "한 도구로 통일하자"는
제안이 반복해서 나왔다(인지부하 감소).

## 결정
하이브리드를 유지한다. 전면 통일하지 않는다.

## 근거
- **controller-독립 복호가 DR 앵커다.** SOPS+age는 age 개인키만 있으면 컨트롤러·클러스터
  없이도 복호된다. SealedSecrets는 라이브 컨트롤러의 sealing key에 종속된다 — 컨트롤러가
  죽으면 봉인 시크릿은 복구 키 없이는 못 푼다. 플랫폼 부트스트랩 시크릿을 SealedSecrets로
  옮기면 "클러스터를 세우려면 클러스터가 필요한" 순환이 생긴다.
- 판정단 검토 8/10이 하이브리드 우세로 판정(통일의 단순함 < controller-독립 DR 자산).

## 기각된 대안
- **전면 SealedSecrets 통일**: controller-독립 SOPS DR 자산을 잃는다. 부트스트랩 순환.
- **전면 SOPS 통일**: 앱 레포가 age 개인키(또는 KSOPS 권한)를 알아야 해 신뢰 경계가 넓어진다.
  SealedSecrets는 공개키만으로 앱 레포에서 봉인 가능(write-only 경계).

## 결과
- sealing key 백업 체인을 DR fail-closed 게이트로 강제한다(`tests/test_sealed-secrets-restore.bats`).
- "어느 도구로 뭘 봉인하나"의 인지부하는 `make secret-edit`/`secret:seal` 진입점으로 완화한다.
