# 메타갭 하드닝 캠페인 — 설계 (2026-07-06)

2026-07-06 심층 감사(14차원·3-렌즈 적대검증, 확정 27건 전건 수정 완료 #282~#299)의
**완전성 비평가가 지적한 메타갭 5건**을 다음 캠페인으로 처리한다. 확정 발견과 달리
이들은 감사 차원 자체가 못 본 시스템 수준 리스크다.

## 대상 갭과 승인된 방향 (owner Q&A 확정)

| # | 갭 | 승인 방향 |
|---|---|---|
| ① | adguard `*.home` rewrite가 tailscale IP(100.120.85.39) 하드코딩 + ConfigMap 첫부팅 시드 전용 + 드리프트 가드 0 — 내부 DNS 링치핀 | **셀프힐 리컨실러**(CronJob이 실 svc IP로 AdGuard API 수렴) |
| ② | renovate `pinDigests: true` 선언 vs platform 매니페스트 전부 태그-only — 정책↔현실 드리프트 방치 | 진단 → 핀 적용 → **재발 가드 게이트** |
| ③ | 단일 무쿼터 btrfs `/`(~224GiB)에 PGDATA/WAL·vmsingle·vlogs·adguard 동거 — 상관장애 + 관측자 동거 | **예측 알림 + vmsingle/vlogs를 bulk-ssd로 이전**(DB는 내장 유지) |
| ④ | 장수 자격증명(tailscale·R2·telegram bot·GitHub App key·PAT) 만료/회전 감시 0 (+ R2_PG 2026-07-01 노출 건 회전 미완) | **인벤토리 + 만료 감시 + R2_PG 회전 실행** (자동회전은 비범위) |
| ⑤ | RBAC/SA automount 최소권한 축 미감사 (automount:false는 glances뿐) | **전수 감사 + 저위험 조치만**(automount 확산·verb 축소), 위험 항목은 보고 |

**스코프 결정**: 5건 전부 한 캠페인, 위험도 오름차순 3웨이브. 웨이브별 독립 머지·라이브
검증 후 다음 진행(PR-first + auto-merge, 파괴·구조 변경은 수동 확인 게이트).

## W1 — 감시·인벤토리 (구조 무변경)

### W1-A (③) 디스크 예측 알림 + per-PVC 가시화
- vmalert 룰: root fs `predict_linear`(72h 윈도) 소진 예측 + 절대 임계(avail <15% warn / <10% critical).
  hostPath라 `kubelet_volume_stats` 영구부재(원장 함정) → node_filesystem 기반.
- per-PVC 가시화: 일일 du CronJob이 PVC 루트 디렉토리별 bytes를 vmsingle에 push
  (restore-drill의 단발 import 패턴 복제 — instant-query staleness 함정 대응은 last_over_time).
- Grafana 패널(용량 추이) 추가.

### W1-B (④) 토큰 인벤토리 + 만료 감시
- 로컬 런북 `docs/runbooks/token-inventory.md`: 자격증명 메타데이터(이름·위치·스코프·만료·회전 절차)만, 값 없음.
- `policy/credential-expiry.json`(이름+만료일만, 커밋 가능): 만료가 존재하는 자격증명 등록
  (GHCR_PULL_TOKEN fine-grained PAT 등). 주간 스케줄 워크플로가 D-14/D-3 텔레그램 경고(telegram-notify composite 재사용).
- 실측 확인 항목: tailscale tagged 디바이스(traefik-ts·pg-rw) 키만료 상태 — tagged는 기본
  비만료 예상, 만료 활성이면 disable을 W2로 승격. operator OAuth client는 비만료 확인만.

### W1-C (⑤) RBAC 전수 감사
- 산출물: SA/ClusterRole/RoleBinding/automount 인벤토리 + 워크로드별 API 실사용 여부 →
  조치안을 저위험(W2-C 대상)/보고-only로 분류한 리포트. 코드 변경 없음.

## W2 — 설정·조치 (컴포넌트 단위)

### W2-A (①) adguard rewrite 셀프힐 리컨실러
- CronJob(10분, edge ns): `traefik-ts` svc(gateway ns)의 실 tailscale IP를 읽어 AdGuard admin
  API(`/control/rewrite/list|delete|add`)로 `*.home.ukyi.app` rewrite를 수렴.
- **API 쓰기는 AdGuard 라이브 설정(PVC)에 영속** → "ConfigMap 첫부팅 시드 전용" 함정 우회.
  DR 재구축 시나리오(디바이스 재등록으로 IP 변경)도 10분 내 자가복구 — 드리프트 자체가 소멸.
- 불일치 수정 시 텔레그램 통지(ensure-role-password Job 패턴). 성공 timestamp 메트릭 push +
  staleness 알림룰(absent 가드 fail-closed).
- RBAC: gateway ns svc get 한정(Role+RoleBinding cross-ns). 인증: 기존 adguard 자격
  SealedSecret 재사용. netpol: apiserver=노드서브넷:6443 함정 준수, adguard:3000, DNS. PSA restricted 준수.
- ConfigMap 시드의 하드코딩 IP·주석은 유지하되 "리컨실러가 수렴" 주석 추가. lan-dns 런북 갱신.

### W2-B (②) renovate pinDigests 드리프트 해소
1. 진단: dependency dashboard issue·renovate 런 로그에서 kubernetes manager pin이 no-op인
   원인 확정(스케줄/컨커런시 큐잉, pin PR 미생성, datasource 실패 등 — 가설 검증 우선).
2. 수정 적용 후 대형 "Pin dependencies" PR 1회 리뷰·수동 머지(automerge 금지 유지).
3. 재발 가드: `scripts/check-image-pins.sh`(가칭) — platform/apps 매니페스트의 `image:`에
   `@sha256` 부재 시 실패, allowlist는 기존 관례(policy/) 형식. make verify 편입.

### W2-C (⑤) RBAC 저위험 조치
- W1-C 분류에 따라: API 미사용 워크로드에 `automountServiceAccountToken: false` 확산
  (공유 차트는 default false + 필요 앱 opt-in 스키마 검토 — 렌더 영향 bats로 증명),
  homepage host-introspection ClusterRole verb 최소화. 기능 위험 항목은 조치하지 않고 보고만.

### W2-D (④) R2_PG 토큰 회전 실행 (owner-local)
- 절차 런북화(재발급 → `.env.secrets` 갱신 → `make seed-secrets` → 소비자 파드 재시작
  확인 — envFrom 함정 유의) 후 이번에 실제 회전해 2026-07-01 노출 건 해소.
- 검증: 회전 후 barman 아카이브·hedge·cache-backup 라운드트립 전부 정상 확인.

## W3 — 구조 (③ 관측 데이터 외장 이전)

- vmsingle TSDB·vlogs 데이터를 bulk-ssd 정적 PV로 이전(files 컴포넌트의 정적 PV 패턴):
  scale-down → rsync → PVC 스왑 → 기동 → 라이브 검증. 관측 공백 수 분 수용.
- **DB(PGDATA/WAL)·adguard는 내장 유지** — 안정성 우선, 외장은 재생성 가능 티어만.
- 리스크: 외장 SSD 부재 시 관측 스택 다운 → (a) 기존 bulk-ssd 게이트 확장으로 명확 실패,
  (b) dead-man's switch(healthchecks.io)는 외부 경로라 관측 스택 전체 다운은 계속 감지됨,
  (c) launchd FDA 함정(rsync 별도 FDA)은 K8s 내부 이전이라 비해당.
- 동반 갱신: observability-bootstrap/restore/external-ssd 런북, 원장 산문(hostPath 위치),
  W1-A 알림룰의 마운트포인트 분리(외장 fs도 predict_linear 대상 편입).

## 비범위 (명시)

- 토큰 자동 회전(수명 관리 자동화) — 만료 감시·절차 런북까지만.
- btrfs qgroup/디스크 쿼터 — 이전+알림으로 갈음(과설계 판단).
- RBAC 고위험 재설계(vmagent/ksm/traefik 등 클러스터 read 필수 워크로드) — 보고만.
- rewrite 구조 변경(IP→이름 앵커) — 셀프힐로 근본 원인(드리프트) 제거되므로 불채택.

## 검증 전략

- 각 항목 `make ci` rc=0 + 항목별 라이브 검증을 계획 단계에 명시. 대표:
  - W2-A: rewrite를 의도적으로 오염시킨 뒤 10분 내 수렴 + 텔레그램 통지 확인.
  - W2-B: 핀 PR 머지 후 digest-exporter·ImageDigestDrift와의 상호작용 무해 확인.
  - W3: 이전 후 메트릭 연속성(직전 데이터 조회)·알림 파이프(watchdog) 정상 확인.
- 웨이브 간 게이트: 이전 웨이브 라이브 검증 완료가 다음 웨이브 착수 조건.

## 참조

- 감사 결과: 세션 리포트(2026-07-06) 확정 27건 수정 PR #282~#299, 메타갭 출처=완전성 비평가.
- 관련 함정: AdGuard ConfigMap 첫 부팅 시드 전용 / split-horizon rewrite DR stale /
  NetworkPolicy egress apiserver / envFrom 시크릿 변경 파드 재시작 / VM 다중 series max() /
  상주 워크로드 자원 limit 블라인드스팟 (docs/traps-detail.md).
