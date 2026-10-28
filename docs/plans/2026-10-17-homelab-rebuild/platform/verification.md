# 플랫폼 검증 결과표

T13(테스트 앱 통합 검증)의 결과표다. 기준은 [design.md](design.md) G절의 시나리오 1~17과 C.8의 봇 자리 표다. 봇·병합·알림 자리의 최종 확인은 [T13](../issues/T13-platform-integration.md) 할 일 4·5다.

**중간 결과(2026-10-28).** 시나리오 1~11·13·16과 15의 15-1~15-12를 실행했다. 12·14·17과 15-13은 사용자 일정에 맞춰 따로 실행하므로 아직 `설계상 기대`다(사용자 결정 2026-10-28, [approvals.md](../approvals.md)). 실행한 뒤 같은 표를 채우고, T13은 그때까지 진행 중이다. 결과표는 PR로 main에 병합한다(AC-X1).

- 무엇: 시험 앱 `homelab-smoke`(두 번째 DB는 `homelab-smoke2`)로 G의 시나리오를 다시 실행한 결과다. 시나리오 13은 NUC 위 임시 VM(D-12), 나머지는 운영에서 했다.
- 언제: 2026-10-27~28(KST). 준비는 2026-10-26에 시작했다. 줄마다 실행 시각을 적었고, `Z`가 붙은 시각은 UTC다.

## 판정 값

| 판정 | 뜻 |
|---|---|
| 실제 검증 완료 | 실행했고 기대 결과를 만족했다. 실행 명령·시각·증거 위치가 있다. |
| 설계상 기대 | 실행하지 않았다. 설계 G의 기대 결과만 있고 증거는 없다. |
| 실패 | 실행했고 기대 결과를 만족하지 못했다. 수정 티켓을 만들거나 한계 승인을 받는다(T13 완료 조건). |
| 승인된 한계 | 실행했고 기대에 못 미치지만 사용자가 승인했다. 승인 기록은 [approvals.md](../approvals.md)에 있고, 메모에 완화책을 적는다. 시나리오 1·14에 선례가 있다. |

판정 칸의 괄호는 그 줄의 편차·한계를 가리키고, 근거와 처리는 아래 "한계와 후속"에 있다. 확인 일부를 다른 증거로 갈음한 줄은 사용자가 갈음을 정한 경우에만 `실제 검증 완료`로 둔다(시나리오 2·6).

## 증거

- 공개해도 되는 증거는 이 문서와 T13 PR에 적는다: 명령과 출력 요약, PR·커밋 SHA, HTTP 응답 코드, 시크릿의 `sha256`. 표에는 명령, 핵심 값, PR 번호, 커밋 SHA, 응답 코드만 둔다.
- 공개하면 안 되는 증거는 저장소 밖에 두고 위치만 적는다(D-23). tailnet 이름, Tailscale IP, 개인 이메일, 계정 ID, 시크릿 값, 복구 자산 목록, 내부 경로가 그렇다. 위치는 종류만 적고 실제 경로·호스트 이름·계정은 쓰지 않는다.
- **증거 위치(모든 줄 공통):** 명령 출력 원문은 `저장소 밖: 운영자 보관 실행 기록`이고, 외부 변경과 사용자 결정은 [approvals.md](../approvals.md)의 같은 시각 행이다. 모든 줄이 같은 값이라 시나리오 표에 증거 위치 열을 두지 않았다.
- 시크릿은 값 대신 `sha256`만 비교했고 값·토큰을 출력하지 않았다(설계 G 공통 전제). 표에는 해시 앞 몇 자만 적는다.

## 환경 값

| 값 | 뜻 |
|---|---|
| 운영 | 운영 클러스터(NUC)와 그 주변(GitHub·Infisical·R2). |
| VM | 시나리오 13의 VM 클러스터. VM 호스트는 tailnet 밖이다(D-12). |
| 현장 | NUC 앞에서 하는 물리 작업(전원·네트워크 차단). |
| 기기 | 판정에 사용자 기기에서의 확인이 필요한 경우: Telegram 수신, tailnet·LAN 질의, `vm-go` 접속. |

## 시나리오 1~17

기대 결과와 명령 수준 검증 방법은 [design.md](design.md) G절 표에 있다. 앱 PR 번호는 `smoke#N`, 나머지 PR 번호는 이 저장소다. "deploy App 작성, merge App 병합"은 author `ukyi-homelab-deploy`, mergedBy `ukyi-homelab-merge`를 줄인 말이다.

| # | 시나리오 | 환경 | 실행 명령과 결과(핵심 값·PR 번호) | 시각(KST) | 판정 | 메모 |
|---|---|---|---|---|---|---|
| 1 | DB 없는 작은 웹앱을 새 저장소에서 처음 배포 | 운영·기기 | `homelab app new homelab-smoke --apply`(목록 PR #923, `github apply` 1 add 0 destroy, verify exit 0) → 첫 빌드 success·배포 PR 없음(미등록) → `homelab app add homelab-smoke --public smoke.ukyi.app` PR #927 → Argo CD Synced/Healthy, 파드 imageID = `image.yaml` digest, `curl https://smoke.ukyi.app/healthz` 200 → 앱 PR smoke#1(cd321ef, 08:15 병합) → 배포 PR #928(deploy App 작성, merge App 병합, 08:20) → 새 imageID = `image.yaml`(revision cd321ef). 저장소 public, GHCR 익명 token 200. tailnet: 노드 → tailnet 443 open(대조), 앱 라벨 파드 → 같은 대상 blocked | 2026-10-27 04:4x~(#928 병합 08:20 뒤 tailnet 확인) | 승인된 한계(아래) | #923은 처음 `ci` 실패(guard 8 시험 mock), #924로 고친 뒤 통과. tailnet 대상은 운영자 노트북 대신 Argo CD tailnet 프록시(운영자 기기 SSH 불가). 완화: 노드 nftables가 파드 대역 → tailnet 대역 전체를 막아 대상과 무관하다(한계 승인 2026-10-28). 노드 egress nftables(#919)를 켠 뒤 실행 |
| 2 | 기존 앱에 PostgreSQL 추가 | 운영 | `homelab db add homelab-smoke --apply` PR #929(데이터 차트 1.0.3) → Database·DatabaseRole applied=true, PUBLIC CONNECT f·앱 역할 CONNECT t → 마이그레이션 PR #930 → 앱 PR smoke#2(`/healthz/db`·`/healthz/cache`) → 배포 PR #931(deploy App 작성, merge App 병합) → ExternalSecret `pg-role-homelab-smoke`(database)·`homelab-smoke-db`(앱) SecretSynced/True, Job `homelab-smoke-migrate` Complete 1/1(로그 `migrate ok`), 테이블 `t13_smoke` owner `homelab-smoke`, pg_database 1, `/healthz/db` 200(`/healthz/cache` 503은 캐시 전이라 기대값), imageID = `image.yaml`(5f029bd47d8f) | 2026-10-27 09:3x~10:14 | 실제 검증 완료 | migration만 더한 #930은 Application을 OutOfSync로 만들지 않아 Job이 다음 sync(#931)에서 돌았다. 설계의 "데이터 Application이 늦으면 Job이 한 번 실패하고 retry로 수렴"은 이번에 나오지 않았고(DB가 먼저 있었다) T11 증거로 갈음했다(사용자 결정 2026-10-28) |
| 3 | 기존 앱에 캐시용 Valkey 추가 | 운영 | `homelab cache add homelab-smoke --apply` PR #932(`uses.valkey`·`cache.enabled`) → Argo CD Synced/Healthy, ExternalSecret `valkey-auth`·`valkey-url` True, 앱 ns PVC 없음, `CONFIG GET maxmemory-policy` = `allkeys-lru`(maxmemory 64Mi, appendonly no), 인증 없는 PING → NOAUTH, 다른 ns(restricted 시험 ns) 파드 → `homelab-smoke-valkey:6379` blocked, 대조(앱 ns·앱 라벨 파드) open, `/healthz/cache` 200 | 2026-10-27 10:17~10:2x | 실제 검증 완료 | 비밀번호는 Secret에서 stdin으로만 넘겼다. 시험 ns·대조 파드는 지웠다. 마이그레이션 hook이 이 sync에서도 다시 돌았다(멱등) |
| 4 | 영속 작업용 Valkey의 백업과 복원 | 운영 | `cache add --persistent` 2단계(#933 캐시 지움 → #934 `valkey.persistent`·`uses.valkey`) → PVC `valkey-data`(local-retain) Bound, CronJob `homelab-smoke-valkey-backup`(03:30 KST) → 표식 키 `t13:s4:marker` SET → 수동 Job `manual-1`이 R2 `valkey/homelab-smoke/dump-20261027T013840Z.rdb` 업로드(업로드 사본 sha256 = 로컬 sha256일 때만 "올림") → 표식 키 DEL → `homelab cache restore`(실행 202610270139245ff0e6): 서버 내림 #936 → restore-vk Job → 복원 모드 #937(RDB 읽음, 키 2) → `appendonly yes`·rewrite ok → 복원 모드 끄기 #938 → 재시작 뒤 검증 키 확인 → `--finish`. 결과: 표식 키 값 `s4-20261027T013830Z`, DBSIZE 2, `aof_enabled:1`·`aof_rewrite_in_progress:0`·`aof_last_bgrewrite_status:ok`, `/healthz/cache` 200 | 2026-10-27 10:3x~11:0x | 실제 검증 완료 | snapshot 첫 접속 거부 1회 뒤 재시도 성공(NetworkPolicy 반영 창, 차트 주석의 알려진 동작). `manual-1`은 실행 라벨 밖이라 손으로 지웠다 |
| 5 | 같은 등록 명령을 재실행해도 데이터·비밀번호 불변 | 운영 | `homelab app add homelab-smoke --public smoke.ukyi.app --postgres --cache=persistent --apply --json` 두 번 → 두 번 모두 status `same`, 단계 8개(config·app-repo·image·ghcr-anon·cache-gone·infisical-postgres·infisical-valkey·pr) 모두 same/none. 새 PR 없음(최대 #938 그대로), main 1abdc0d 그대로, Secret 4개(pg-role·db·valkey-auth·valkey-url) 해시 전후 같음, `t13_smoke` 행 수 3 = 3 | 2026-10-27 11:0x | 실제 검증 완료 | 현재 상태가 영속 Valkey라 설계 명령의 `--cache` 대신 `--cache=persistent`로 돌렸다(`--cache`면 캐시 전환 계획이 나오는 것이 정상). `--json`에 시크릿 값 없음(키 경로만) |
| 6 | 필수 시크릿이 없으면 잘못된 값 적용 없이 명확히 실패 | 운영·기기 | 준비: `homelab secret set homelab-smoke T13_SMOKE_TOKEN`(stdin) → `app add` 재실행 #944. #945(Infisical에 없는 `T13_MISSING_KEY`) 04:34:07Z 병합 → 04:34:47Z ExternalSecret `homelab-smoke-app` False/SecretSyncedError, 앱 Secret 해시 그대로(cf2ee697…), Deployment generation 13 그대로(뒤 wave 미적용, 새 파드 없음), 옛 파드 Running·`/healthz` 200, Application OutOfSync/Degraded. `homelab status`: "5/6 Ready: homelab-smoke-app. Infisical에 없음: T13_MISSING_KEY (실패)". ExternalSecretNotReady firing 04:45:00Z(for 10m), telegram 전송 지표 5→7·실패 0. 되돌림 #946 04:46:16Z 병합 → 05:17:34Z Synced/Healthy·ExternalSecret True, Secret·generation 그대로 | 2026-10-27 13:34~14:17 | 실제 검증 완료(한계 둘, 아래) | 한계 1: 되돌림이 병합 31분 뒤 반영됐다(실패한 sync 작업의 재시도가 옛 values를 되풀이). 한계 2: `status`의 "다음"이 "잠시 뒤 다시"였다. Telegram 수신은 시각 기록이 없어 전송 지표로 갈음했다(사용자 결정 2026-10-28) |
| 7 | Infisical 장애·인증 만료 중 기존 서비스와 신규 배포 | 운영·기기 | 사용자가 `eso-homelab` 시험 client secret 발급 → backup(원본 해시 eae1d77f5a6f = T09 기록의 운영 값)·swap → 강제 동기화 성공 05:31:39Z → 사용자 폐기 → 05:47:08Z ExternalSecret app·db SecretSyncedError, ClusterSecretStore apps·platform Ready=False(InvalidProviderConfig), 앱 Secret 해시 그대로. 장애 중: 앱 파드 삭제 → 새 파드 05:47:18Z Ready(기존 Secret). 앱 PR smoke#7 → 배포 PR #948 자동 병합(05:52:46Z) → 새 digest d5fa0d0 05:54:16Z, Synced/Healthy(ExternalSecret health 덮어쓰기). 새 키 요구 #947 → 05:55:51Z Degraded, Secret에 옛 키만, status에 ExternalSecret 2개 실패. ExternalSecretNotReady 둘 firing 05:57:30Z, telegram 전송 13·실패 0. restore 05:58:32Z(same_as_backup=yes) → Store Ready 06:02:31Z~06:04:13Z → ExternalSecret Synced 06:09:30Z(새 키 포함) → 새 키 파드 06:13:14Z → Synced/Healthy 06:13:25Z(강제 동기화 없음) → 백업 Secret 삭제 | 2026-10-27 14:2x~15:13 | 실제 검증 완료 | 운영 ESO 자격 로그인은 이때 따로 하지 않고 원복 뒤 Store Ready=True와 원본 해시 일치로 갈음했다(할 일 7 로그인은 시나리오 13 뒤 HTTP 200). `status`가 "Infisical 인증 실패"라는 원인을 말하지 않았다. 교체 순간 `/healthz` 503 1회(단일 레플리카) |
| 8 | DB 비밀번호 변경 후 실제 앱 접속까지 확인 | 운영 | `homelab db rotate homelab-smoke --apply`(01:58:59Z~02:00:50Z): PREVIOUS로 옮김 → 새 40자 → 역할 Secret·앱 Secret 동기화 → 앱 재시작 → CLI가 `/healthz/db`·새 값 접속·옛 값 거부 확인. 독립 확인: 해시 pg-role 7de688d0→bebe2748, homelab-smoke-db 88d38086→b6253286, DatabaseRole PasswordSecretChange(역할 Secret resourceVersion 1055121→1069126)·applied true, `PASSWORD_PREVIOUS`로 psql → password authentication failed, `PASSWORD` → current_user homelab-smoke, `/healthz/db` 200, 새 파드 02:00:34Z → `--finish`로 PREVIOUS 지움 | 2026-10-27 10:58~11:02 | 실제 검증 완료 | 중단 시간: `/healthz/db` 503 02:00:05.1Z ~ 200 02:00:39.9Z = 약 35초(1초 간격 실패 19회). T11 실측 17~20초보다 길다. 이번 값은 역할 Secret 동기화부터 새 파드 Ready까지 전체다(앱이 매 요청 새로 접속). 옛 값 시험은 pg-1 안 127.0.0.1 TCP(비밀번호 인증 경로) |
| 9 | 앱을 삭제해도 DB·영속 데이터 보존 | 운영 | 기준: 표식 행 1,2,3,1313, Valkey 키 3·`t13:s13:marker`, PVC `valkey-data` uid 18bbfc5d. `homelab app remove homelab-smoke` PR #965(`apps/homelab-smoke/` 두 파일 삭제) → Application NotFound, 앱 파드 0 → Database·DatabaseRole 그대로, PVC 같은 uid Bound, 영속 Valkey 1/1(데이터 앱 Synced/Healthy), 표식 행 그대로, `homelab data list` "`data/<app>`은 있고 `apps/<app>`은 없음: homelab-smoke, homelab-smoke2", Infisical `/apps/homelab-smoke` 키 그대로 → `app add` 재등록 PR #966(비밀번호 "있음(그대로 사용)") → 07:30:57Z 앱 Ready, `/healthz`·`/healthz/db`·`/healthz/cache` 200, 표식 행·PVC uid·Valkey 키 같음 | 2026-10-28 16:2x~16:31 | 실제 검증 완료 | 재등록은 `app remove`가 지운 `values.yaml`을 CLI가 다루는 키로 새로 써서 사람이 더한 migration 줄이 사라졌다(문서 경고, 아래). 시험 키 둘이 secrets로 다시 들어갔다 |
| 10 | 공유 PostgreSQL에서 특정 앱만 복원 | 운영 | `homelab-smoke2`(DB만, 손 PR #939) → 표식 smoke {1,2,3}, smoke2 {1001,1002}(앱 역할 소유) → 온디맨드 Backup → T1 = 2026-10-27T02:15:56Z → T1 뒤 smoke id 1 삭제·스키마 `t13_after`·테이블 둘(앱 역할), smoke2 1003 추가, `pg_switch_wal` → `homelab db restore homelab-smoke --to T1`(T1 뒤 completed base backup이 없어 처음엔 멈춤 → 온디맨드 `t13-s10-post-20261027021733` 뒤 통과) → 되돌림 사본 R2 `pgdump/homelab-smoke/pre-restore-20261027021820741de2.dump`, R2에서 만든 임시 Cluster 내용이 T1 상태 → 멈춤 #940 → 재개 #941 → `--finish`. 결과: smoke {1,2,3}, 스키마 public만, 테이블 `public.t13_smoke`(owner homelab-smoke)뿐, smoke2 {1001,1002,1003}, DB owner homelab-smoke, PUBLIC CONNECT f. 임시 Cluster·PVC 0, restore 라벨 Job·Pod·PVC 0, `/healthz/db`·`/healthz/cache` 200. 교차 접속: 각 앱 역할 → 자기 DB 성공, 상대 DB "permission denied for database"(복원 전·후 같음) | 2026-10-27 11:13~11:32 | 실제 검증 완료 | 되돌림 사본 삭제는 사람 작업이다(명령은 저장소 밖). `db restore`가 T1 뒤 base backup을 요구하는 것은 설계 G 10행에 없었다 |
| 11 | 빌드 완료 순서가 바뀌어도 과거 이미지로 배포되지 않음 | 운영 | 두 번째 시도: 앱 PR smoke#5(A2 b86f8ba, 느린 시험 표시 `.slow-build` 남음 → test 150초) 04:05:44Z 병합, 이어 main에서 만든 smoke#6(B2 6ec09ca, 표시 삭제) 04:06:28Z 병합 → B2 빌드 04:07:35Z 먼저 끝남·배포 PR #943(deploy App 작성, merge App 병합) → A2 빌드 04:09:22Z 늦게 끝남, deploy-pr "열린 deploy/homelab-smoke의 revision 6ec09ca 대비 behind: 갱신하지 않는다", 새 PR 없음 → `gh run rerun`(attempt 2, 04:15:25Z) "main의 배포 revision 6ec09ca 대비 behind: 갱신하지 않는다" → 배포 PR은 #928·#931·#942·#943뿐, main `image.yaml` revision 6ec09ca·digest 534f9554, 파드 imageID 534f955400ba | 2026-10-27 13:05~13:15 | 실제 검증 완료 | 첫 시도(smoke#3·#4)는 무효다: B를 A 브랜치에 쌓은 채 squash해 B가 빈 커밋이 됐고 표시 파일이 main에 남아 두 빌드 모두 느렸다(lead 실수). 그때 A의 deploy-pr이 B의 대기 job에 concurrency(cancel-in-progress)로 취소되는 것도 봤다(보조 장치, 순서는 compare가 지킨다). `src/slow.test.ts`는 앱 저장소 main에 남아 있다(표시가 없으면 즉시 끝) |
| 12 | NUC 재부팅 후 의존 서비스 준비 | 운영·기기 | | | 설계상 기대 | 실행 예정(사용자 일정, approvals 2026-10-28) <!-- TODO lead: S12 결과 --> |
| 13 | 빈 NUC에서 문서 절차만으로 재구축 후 테스트 앱 배포 | VM·기기 | VM 격리 조건 여섯: (1) values-vm·root-vm·vm.env, (2) `homelab-dev` 키 대조 빠진 키 0(운영 키 23), ESO `eso-homelab-dev`, (3) VM 버킷 `homelab-backups-vm`·serverName `pg-vm-20261027`에만 아카이브, 운영 원본은 `r2-source-readonly`로만(쓰기 403 거부, base backup 11개 보임), (4) `vm-*` 기기 5개(vm-adguard·vm-argocd·vm-grafana tag:k8s, vm-go tag:k8s-go, vm-tailscale-operator tag:k8s-operator, 콘솔 확인), VM 호스트 `tailscale0` 없음, 운영 tailnet 기기 사라짐 0, D-30 `vm-go/argocd` 리다이렉트(사용자 브라우저), (5) 시험 터널 `/ready` 200·HA 4, Traefik `Host: smoke.ukyi.app` `/healthz`·`/healthz/db`·`/healthz/cache` 200·없는 host 404, 운영 공개 URL 200·DNS 레코드 2개 그대로, (6) context `homelab-vm`. 순서: vm.md 1절(패키지 78개, 네트워크·격리 표, VM, 격리 확인) → VM 안 bootstrap 0.0·1절(verify 통과) → Argo CD → ESO·복구 원본 Secret → 쓰기 거부 → root-vm(02:31Z) → pg healthy 02:35Z → U27 통과(운영 표식 행 1313이 VM에 있음, smoke2 1001~1003) → 새 base backup(VM 버킷) → Valkey: 운영 RDB를 VM 버킷으로 복사·대조 → restore.md 1절 2~6단계(#961 복원 모드, #962 끄기) → 표식 키 `t13:s13:marker` 일치·AOF ok → 앱 재개 #963 → Argo CD 22개 Synced/Healthy, imageID = `image.yaml`, 교차 DB 거부, VM bootstrap 3절 확인 통과 → 정리 PR #964: U26 Argo CD 경로(initdb로 바뀌어도 pg-1 uid·재시작 0 그대로) → `r2-source-readonly` 삭제 → 할 일 7 운영 ESO 로그인 HTTP 200 | 2026-10-28 09:4x~15:0x(VM 복구 PR #959·운영 표식 행 2026-10-27 19:34) | 실제 검증 완료(편차 승인) | 문서에 없는 단계 1개: 운영 NUC의 inotify 인스턴스 한도 128 소진으로 libvirt dnsmasq가 뜨지 못해 #960을 실행 중에 병합·적용하고 libvirtd를 재시작했다(런북 밖). 지금 런북이면 vm.md 1.1이 먼저 막는다. 사용자가 편차로 승인했고 재실행하지 않는다(2026-10-28). 그 밖 넷(1.5 첫 SSH가 pam_nologin에 실패, 첫 verify의 podCIDR 경쟁, 읽기 전용 토큰 두 번 잘못 넣음, Pending PVC가 데이터 sync를 막음)은 #968로 보강. U40 2회차는 하지 않았다 |
| 14 | AdGuard가 멈췄을 때 LAN·Tailscale 기기의 이름 해석 | 운영·기기 | | | 설계상 기대 | 실행 예정(사용자 일정, approvals 2026-10-28). 측정 항목은 표 아래 "시나리오 14 측정값" <!-- TODO lead: S14 결과 --> |
| 15 | 자동 병합 조건 밖의 PR은 사람 승인 뒤에만 병합 | 운영 | 대역 App `ukyi-homelab-bot-standin-2`(ID 5491621, homelab·homelab-smoke만 설치). 15-1 설정 확인 24줄 PASS(automerge secret·배포 브랜치 main, repo·org secret 0, `allow_auto_merge` false, bypass, main-checks 필수 `ci`, 태그 ruleset 3패턴, smoke·template `app-main` 4규칙·관리자 bypass `pull_request`만·CODEOWNERS, workflow-guard 음성 fixture 32개). 15-2 homelab 브랜치 job의 `automerge`·`AutoMerge` 선언 둘 다 "not allowed to deploy to automerge"(run 40467209857). 15-3 test 권한 job에 OIDC 없음, 시험 브랜치의 배포 identity 로그인 403. 15-4 사람 PR #952 `deploy-merge` 조건 1(·2) 불일치. 15-5 `ci` 실패 PR #951 `--admin` 거부("Required status check ci is failing"), #952 `--match-head-commit` 검토 SHA ≠ head 거부. 15-6 `app-chart-v1.0.0` 이동·삭제 push GH013, 태그 그대로. 15-7 대역 App PR #953 조건 1로 미병합, `PUT merge` 405, homelab main·`deploy/s15-x`·smoke main push GH013. 15-8 배포 App 토큰의 `ci.yaml` 변경 push "without workflows permission" 거부. 15-9 smoke가 homelab 워크플로를 부를 때 `HOMELAB_MERGE_KEY` length=0. 15-10 smoke `app-main` disabled 07:37:01Z → 배포 PR #954 조건 9만 불일치 → active 복귀 → 재판정 병합. 15-11 커밋 C 6ad9ddcf([skip ci], 빌드 없음) → 브랜치 워크플로가 C를 빌드·push(revision=C·source 라벨, attestation 없음 404) → 대조 main 빌드 verify 0 → 배포 App 토큰(키 유출 대역)으로 PR #955 → 조건 5만 불일치, 미병합 → 닫기 → 정상 배포 PR #956 병합. 15-12 `homelab github verify` exit 0 → 사용자가 선언 밖 ruleset `s15-drift` 생성 → exit 1 "guard 3: homelab의 ruleset 이름 집합·개수가 선언과 다르다" → 삭제 → exit 0(main 499fe6e). 정리: 시험 PR 3개 닫음, 브랜치 7개·smoke automerge environment 삭제, 대역 App·GHCR 시험 버전 삭제 | 2026-10-27 16:2x~17:1x, 15-12 보충 17:2x~17:4x | 실제 검증 완료(15-1~15-12) <!-- TODO lead: 15-13 뒤 "실제 검증 완료"로 --> | 15-10·15-11은 lead 실행이 분류기에 막혀 사용자가 탭에서 실행했다. 15-11에서 배포 App 키를 로컬에서 한 번 읽었다(회전 안 함, 사용자 결정). 15-7e(대역 App 승인 + 병합)는 설계 행 밖이라 하지 않았다. 15-2의 FAIL 한 줄은 스크립트가 job 완료 전에 읽은 것이다(다시 읽어 PASS) |
| 15-13 | (15의 일부) 결과 PR: owner 자기 승인 거부, `deploy-merge` 조건 1 불일치, 관리자 bypass 병합만 성공 | 운영 | | | 설계상 기대 | 실행 예정(사용자 일정, approvals 2026-10-28) <!-- TODO lead: 15-13 결과 --> |
| 16 | 봇이 없거나 멈춘 상태에서 테스트 경보가 비AI 경로로 도착 | 운영·기기 | 봇 없음(homelab-bot 미배포, E4b 시점과 같음). `amtool alert add alertname=PlatformTest severity=warning` 04:01:14Z → `alertmanager_notifications_total{integration="telegram"}` 4→5, failed_total 합 0 그대로. Telegram 수신 13:01(발송 13:01:14, 2분 안), 해소 13:06(amtool 기본 만료 5분) | 2026-10-27 13:01 | 실제 검증 완료 | 수신은 사용자 화면으로 확인했다 |
| 17 | NUC 전체가 멈추면 외부 생존 감시가 감지해 알림 | 현장·기기 | | | 설계상 기대 | 실행 예정(사용자 일정, approvals 2026-10-28) <!-- TODO lead: S17 결과 --> |

### 시나리오 14 측정값

설계 G 14행과 T13 할 일 6(D-08)의 기록 항목이다. LAN은 C.3.6의 AC-P6 기준으로 판정하고, 적용률은 기록만 한다. <!-- TODO lead: S14 실행 뒤 채운다 -->

- LAN 기기, AdGuard 정지 중 10초 간격 30회(`dig "am$(date +%s)-$i.example.com" +tries=1 +time=5`):
  - 실패 수(시간 초과·SERVFAIL·REFUSED):
  - 응답 시간(`Query time`):
- 셀룰러 Tailscale 기기, AdGuard 정지 중:
  - `nslookup doubleclick.net`(차단 응답 `0.0.0.0` 또는 NXDOMAIN):
  - `nslookup example.com`(정상 응답):
- 노드:
  - `resolvectl query example.com`:
  - `sudo k3s crictl pull docker.io/library/busybox:1.37`:
- tailnet 기기의 내부 UI(`curl -sI https://argocd.<tailnet>.ts.net`):
- 원복(revert PR) 뒤 차단 복귀와 AdGuard Home 질의 로그:
- 사용자 규칙 적용률(`adg-<날짜>-<회차>.ukyi.app`, `0.0.0.0` 응답만 셈):
  - 규칙 전 두 경로 정상 주소 확인:
  - 집 Wi-Fi 20회 중 차단:
  - 셀룰러 20회 중 차단:

## 한계와 후속

시나리오 번호별로 모았다. 줄 끝 괄호가 처리 방식이다: `(한계, 사용자 승인 <근거>)`, `(편차 승인, 사용자 결정 <근거>)`, `(갈음, 사용자 결정 <근거>)`, `(후속: <어디로>)`, `(해결: <PR 또는 조치>)`.

- **1** tailnet 불통 확인 대상을 설계 G 1행의 운영자 노트북(`nc -l`) 대신 Argo CD tailnet 프록시 443으로 바꿨다. 운영자 기기에 SSH로 닿지 못했다. 노드에서 같은 대상이 열리는 것으로 대조했다. 노드 nftables가 파드 대역 → tailnet 대역 전체를 막으므로 대상에 따라 결과가 달라지지 않는다. (한계, 사용자 승인 2026-10-28)
- **1** 새 파드 시작 직후 약 1초 egress 창(T13 할 일 9): 사용자 결정 1안대로 노드 nftables로 파드 대역의 LAN·tailnet·공개 비443 출발을 막았다(#919, 커널 판정 보강 #926). 2026-10-26 운영 적용 뒤 시작 즉시 연결하는 시험 파드가 15/15 통과했다(LAN·tailnet·공개 80/22·다른 DNS·노드 SSH 차단, 443·7844·DNS·6443·API 열림). 시나리오 1은 이 규칙을 켠 뒤 실행했다. 런북 `bootstrap.md` 1.1의 남는 한계 1~4(파드 → 노드 6443·10250, 업스트림 DNS 53, 공개 443·7844, Tailscale DERP 전용)는 1안 범위다. (한계, 사용자 승인 approvals 2026-10-26 "T13 P4 노드 nftables 1안")
- **1** 같은 규칙의 남는 한계 5(부팅 때 규칙이 못 올라와도 k3s는 뜨는 fail-open)는 1안 승인 문구 밖이었다. 시나리오 12(NUC 재부팅) 뒤 `bootstrap.md` 1.1의 시작 즉시 연결하는 시험 파드 블록으로 규칙이 돌아왔는지 본다. (한계, 사용자 승인 2026-10-28. 후속: T13 시나리오 12)
- **1** 1안이 요구한 "적용 뒤 tailnet UI(DERP) 실측"은 운영자 기기 확인 기록이 없다. 노드에서 grafana tailnet 주소 HTTPS 200만 있다. (후속: T13 시나리오 14의 내부 UI 확인과 함께 <!-- TODO lead: S14 결과 -->)
- **2** migration만 바꾼 PR(#930)은 Application을 OutOfSync로 만들지 않아 마이그레이션이 다음 sync(#931)에서 돌았다. 설계 C.5.4에 적었고, Job 확인 기준을 migrate 컨테이너 command·image 대조로 고쳤다. (해결: #950, #957)
- **2** "데이터 Application이 늦으면 Job이 한 번 실패하고 retry로 수렴"은 이번에 나오지 않았다(DB가 먼저 있었다). T11 시나리오 2(동등 절차: 앱 PR을 데이터 PR보다 먼저 병합해 Job이 `auth_failed`로 실패하고 retry로 성공)에서 같은 수렴을 봤다. (갈음, 사용자 결정 2026-10-28: T11 증거)
- **6** 한계 1: 되돌림 #946이 병합 31분 뒤에야 반영됐다. 실패한 자동 sync 작업은 만들 때 복사한 옛 source로 재시도하고, retry 한도(10회, backoff 30초→5분)를 다 쓸 때까지 새 values를 적용하지 않는다. 원인을 설계 B.8 E2·C.3.3에, 진행 중 작업 종료 절차를 런북 `apps.md` 1절에 적었다. (해결: #957)
- **6** 런북 `apps.md` 1.3 4단계의 작업 종료 패치(`phase`를 `Terminating`으로)를 운영에서 실측했다(사용자 승인 2026-10-28). `homelab-smoke`에 Infisical에 없는 키를 요구한 #972(12:23:10Z 병합) → 작업 12:23:42Z 시작, ExternalSecret SecretSyncedError, 재시도 3회째 대기 → 되돌림 #973(12:28:39Z 병합) → spec 반영 12:28:45Z → 3단계 판정 첫 줄(`sameSource: false`, `finishedAt` 있음) → 4단계 패치 12:29:09Z → 이벤트 "Operation terminated (retried 3 times)", 같은 초에 새 작업, 12:29:14Z 작업 Succeeded(패치 뒤 5초), 12:29:15Z Synced/Healthy·ExternalSecret Ready 관측(6초). 되돌림 병합부터 정상 상태 관측까지 36초(시나리오 6에서 기다린 31분). 앱 파드 재시작 없음, 실패 구간 약 5분 30초라 `ExternalSecretNotReady`(for 10m)는 나지 않았다. (해결: #957, 실측 #972·#973)
- **6** 한계 2: 키 누락과 Argo CD 재시도가 겹치면 `homelab status`의 "다음"이 "잠시 뒤 다시"였다. 이제 `homelab secret set <app> <KEY>`를 먼저 안내한다. (해결: #950)
- **6** 설계 G 6행 검증의 "Telegram 수신"은 시각 기록이 없다. 전송 지표 telegram 5→7·실패 0이 있다. (갈음, 사용자 결정 2026-10-28: 전송 지표)
- **7** 운영 ESO 자격 로그인을 시나리오 7 직후에는 따로 하지 않았다. 할 일 7 로그인은 시나리오 13 뒤 HTTP 200이다(토큰은 버림). (해결: 할 일 7, approvals 2026-10-28 "U26 Argo 경로·r2-source prune·r2-source-readonly·운영 ESO 자격" 행)
- **7** `homelab status`가 Store Ready=False일 때 "Infisical 인증 실패" 원인과 다음 행동을 말하지 않았다. (해결: #950)
- **8** `/healthz/db` 실패 창 약 35초는 T11 실측(17~20초)보다 길다. 역할 Secret 동기화부터 새 파드 Ready까지 잰 값이다. `db rotate` 주의 문구를 "수십 초(T11 약 17~20초, T13 약 35초)"로 고쳤다. (해결: #950)
- **9** 재등록(`app add`)은 `app remove`가 지운 `values.yaml`을 CLI가 다루는 키(기본값·플래그·Infisical 키)로 새로 써서 사람이 더한 migration 줄이 사라졌다. `cli/README.md` 동작 규칙과 설계 C.7 등록 명령 설명에 경고를 더했다. (해결: 문서 경고, 결과 PR 1차)
- **9** 시험 키 둘(`T13_S7_NEWKEY`·`T13_SMOKE_TOKEN`)이 재등록으로 secrets에 다시 들어갔다. (후속: T13 정리, `homelab-smoke` 데이터·Infisical 키 정리 때)
- **10** `db restore`가 T1 뒤 completed base backup을 요구한다는 것이 설계 G 10행과 런북에 없었다. 설계 G 10행과 `restore.md` 2절 앞에 온디맨드 Backup 블록을 더했다. (해결: #950)
- **10** R2 되돌림 사본 `pgdump/homelab-smoke/pre-restore-20261027021820741de2.dump` 삭제는 사람 작업이고 실행 기록이 아직 없다. 명령은 저장소 밖에 있다. (후속: T13 정리, 사람 작업)
- **11** 느린 시험 `src/slow.test.ts`가 `homelab-smoke` main에 남아 있다(표시 파일이 없으면 즉시 끝). (후속: T13 정리, `homelab-smoke` 저장소 정리 때)
- **13** 설계 G 13행은 "문서에 없는 수동 단계가 하나라도 있으면 실패로 기록"이다. 이번에 하나 있었다: 운영 NUC의 inotify 인스턴스 한도 128 소진으로 libvirt dnsmasq가 뜨지 못해, #960(호스트 sysctl 8192, vm.md 1.1 사전 확인)을 실행 중에 병합·적용하고 libvirtd를 재시작했다. 운영 NUC 위에 VM을 띄운 시험 환경이 원인이고, 지금 런북이면 1.1 사전 확인이 먼저 막아 이 단계가 필요 없다. 판정은 "실제 검증 완료(편차 승인)"이고 재실행하지 않는다. (편차 승인, 사용자 결정 2026-10-28)
- **13** 첫 SSH 대기가 pam_nologin에 실패(1분 뒤 통과), VM 첫 verify의 podCIDR 경쟁(재실행 통과, 런북이 허용), 복구 원본 자리에 VM 버킷 토큰을 두 번 넣음(블록이 403으로 막음), Valkey 멈춤 중 Pending PVC가 `homelab-smoke-data` sync를 막음(복원 Job 뒤 풀림). vm.md 1.5 로그인 대기, install의 podCIDR 대기, 토큰 버킷 강조, 데이터 차트 1.0.4(pg-acl Sync wave 3, 영속 Valkey wave 4)로 보강했고 시험 앱 둘에 적용했다(#969). #968 리뷰 P3(pg-acl hook이 실패할 때 막히는 것을 wave 4의 Valkey PVC·서버로 한정하는 설명)는 #971로 고쳤다(2026-10-28 병합 d9c7303). (해결: #968, #971)
- **13** U40(클러스터 유실과 Infisical 장애가 겹친 복구) 2회차는 하지 않았다. 후속 티켓은 아직 없다(T13 할 일 3). (한계, 사용자 승인 approvals 2026-10-27 "T13 S13 묶음·U40 2회차·AC-P12 리뷰 App 구조·15-11 배포 키" 행)
- **13** VM 정리 뒤 libvirt iptables 체인만 남았다(재부팅하면 사라짐). (후속: T13 시나리오 12 뒤 vm.md 6.3 다시 확인)
- **15** 15-11에서 배포 App 키를 로컬에서 한 번 읽어 유출을 흉내 냈다. 키는 회전하지 않는다. (한계, 사용자 승인 approvals 2026-10-27 같은 행)
- **15** 15-13(결과 PR에서 owner 자기 승인 거부)은 아직 하지 않았다. (후속: T13 결과 PR <!-- TODO lead: 15-13 결과 -->)
- **12·14·17** 아직 실행하지 않았다. 실행 직전에 다시 승인받는다. <!-- TODO lead: 실행 뒤 한계를 여기에 --> (후속: T13, 사용자 결정 approvals 2026-10-28 "T13 S9·S14·S12·S17 순서" 행)

## 봇 자리 확인

AC-P12 다섯 자리와 AC-P8·AC-P11 자리다. 자리·준비 티켓·확인 방법은 spec §4.4, T13 할 일 4, 설계 C.8·E.3을 따른다. 여기서는 자리의 존재·경로·권한을 보고, 실사용 검증은 T16b·T17·T19가 한다. 확인 명령의 전문은 설계 C.8 표에 있다.

T13 할 일 4·5로 2026-10-27 17:47~17:50(KST)에 운영에서 읽기만으로 다시 확인했다. 쓰기, 시험 경보, App 생성은 하지 않았다. "읽기 전용 접근" 한 자리를 Kubernetes·관측·Argo CD 세 줄로 나눴다.

**요약:** 아홉 자리 중 일곱은 실제 검증 완료다. 리뷰 전용 App 저장소별 설치 구조는 지금 다시 볼 수 없어 T10 증거로 갈음했다(승인된 한계). 외부 생존 감시는 경로와 대체 차단 시험까지 확인했고, NUC 전체 중단을 보는 시나리오 17만 남았다.

### AC-P12

| 자리 | 준비 티켓 | 확인 방법(설계 C.8) | 판정 | 근거(핵심 값) | 남은 일 |
|---|---|---|---|---|---|
| 공개 HTTPS webhook 수신 경로 | T08a | C.8 `공개 HTTPS webhook 수신 경로` 행: `https://hooks.ukyi.app/github`의 GET·다른 경로 POST·서명이 틀린 POST 응답 코드, 시험 webhook ping의 Recent Deliveries 200. | 실제 검증 완료 | `https://hooks.ukyi.app/github` GET 403, 다른 경로 POST 403, 틀린 서명 POST 401(수신기 로그 `POST /github 401`), 터널 `/ready` 200·HA 4. 정상 서명 ping 200은 T08a(approvals 2026-10-20 19:09) | T16b가 시험 수신기 `edge-probe`를 봇으로 바꾸고 지운다 |
| 읽기 전용 접근: Kubernetes | T08b | C.8 `읽기 전용 접근` 행: SA `bot-reader`로 `kubectl auth can-i` yes·no. | 실제 검증 완료 | SA `bot-reader`로 `kubectl auth can-i` 8회: pods list·applications get·nodes get yes, secrets·pods/log·configmaps get·deployments create·pods delete no. ClusterRole verb는 get·list·watch만 | T16b가 대상 ns를 `app-homelab-bot`으로 |
| 읽기 전용 접근: 관측 | T08b | C.8 `읽기 전용 접근` 행: Grafana 토큰으로 `GET /api/search` 200·`POST /api/dashboards/db` 403. | 실제 검증 완료(T08b 실측), 지금 토큰 없음 | Grafana health 200(13.2.4), 데이터소스 둘이 읽기 전용 vmauth 경유. T08b: Viewer 토큰 `/api/search` 200, 대시보드 쓰기 403 | T16b가 토큰 발급 |
| 읽기 전용 접근: Argo CD | T08b | C.8 `읽기 전용 접근` 행: `argocd admin settings rbac can` get Yes·sync No. | 실제 검증 완료(정책), 지금 토큰 없음 | `accounts.bot-reader: apiKey`, applications·applicationsets·projects `get`만, `policy.default` 빈 값 | T16b가 토큰 발급 |
| 경보 외부 수신자 | T08b | C.8 `경보 외부 수신자` 행: `amtool config routes test`에 `bot` 포함, `amtool alert add`의 수신 로그와 `alertmanager_notifications_total{integration="webhook"}` 증가, Telegram 수신. | 실제 검증 완료(T08b 실측), 지금 route 비활성(설계대로) | 봇 route 네 줄은 주석, 시험 수신기 Service 8081. T08b: `BotRouteTest` 수신, webhook 0→1·telegram 0→1, 실패 0 | T16b가 route를 Telegram 형제 route와 함께 켜고 재시험 |
| 격리 작업 실행 공간 | T08b | C.8 `격리 작업 실행 공간` 행: 작업자 SA 토큰 미마운트·RBAC 없음, `infisical-sandbox` 경로 고정, DNS 없이 `HTTPS_PROXY`만으로 `codeload.github.com` 접근·`github.com` 거부, `CODEX_HOME` 영속 공간이 파드 재생성 뒤 유지. | 실제 검증 완료(구조·통제, 네트워크는 T08b 실측) | worker 1/1, SA 토큰 미마운트, RBAC 0, DNS 없는 egress, 프록시 3128만(SNI 허용 셋), PVC `codex-home` Bound, Store `infisical-sandbox` Ready | T16b(E9)가 모델 자격 `auth.json` 시드 |
| 리뷰 전용 App 저장소별 설치 구조 | T10 | C.8 `리뷰 전용 GitHub App` 행: 설치 `repository_selection`이 `selected`, 설치 토큰의 `GET /installation/repositories`가 저장소 하나, bypass 목록에 없음, 대상 저장소의 `CODEOWNERS` 오류 0과 code owner 리뷰·승인 무효화 규칙 `true`. | 승인된 한계(지금 미확인, T10 증거로 갈음. approvals 2026-10-27 "T13 S13 묶음·U40 2회차·AC-P12 리뷰 App 구조·15-11 배포 키" 행) | 시험 App은 2026-10-21 삭제(지금 404). T10: `repository_selection=selected`, 설치 토큰 `GET /installation/repositories` total_count 1, 토큰 폐기 204. 지금 org 설치 4개(codex·deploy·merge·renovate)가 모두 `selected` | T17이 실제 App을 만든다(설계 C.8 권한. T10 시험 App에는 `issues read`가 빠져 있었다) |

### AC-P8

| 자리 | 준비 티켓 | 확인 방법(설계 C.8) | 판정 | 근거(핵심 값) | 남은 일 |
|---|---|---|---|---|---|
| 병합 조건 공개 | T10 | C.8 `병합 조건 공개` 행: 시나리오 15, `homelab github verify` exit 0(guard 통과, plan 무변경). | 실제 검증 완료 | `.github/workflows/README.md` 9조건 공개(공개 URL 200), ruleset 6개(5 active, `main-interim` disabled), environment `automerge` 배포 브랜치 main·secret 하나, repo·org secret 0, `allow_auto_merge` false. 시나리오 15-12 `homelab github verify` 0 → 1 → 0 | 없음 |
| 봇 변경 PR의 자동 병합 차단 | T10(시험 신원. 실제 신원은 T19) | C.8 `봇 변경 PR 작성 자격` 행과 T13 할 일 5: 시험 App(예: `ukyi-homelab-bot-standin-2`)으로 `bot/x` push 성공, homelab main·`deploy/x`·앱 main push 거부, digest만 바꾼 PR이 `deploy-merge`의 "조건 1 불일치"로 병합되지 않음. 시나리오 15. | 실제 검증 완료(시나리오 15-7) | 대역 App PR #953 조건 1로 미병합, `PUT merge` 405, homelab main·`deploy/s15-x`·smoke main push GH013. 대역 App은 시험 뒤 삭제(404) | T19가 실제 봇 쓰기 App으로 다시 본다 |

### AC-P11

| 자리 | 준비 티켓 | 확인 방법(설계 C.8) | 판정 | 근거(핵심 값) | 남은 일 |
|---|---|---|---|---|---|
| 비AI 알림 경로 | T08b | C.8 `비AI 알림 경로` 행: 시나리오 16. 봇 없이 Telegram에 2분 안 도착, `alertmanager_notifications_total{integration="telegram"}` 증가, 실패 지표 불변. | 실제 검증 완료 | receiver `telegram`, 전송 20·실패 0(17:4x 조회). 시나리오 16: 4→5, 수신 13:01 | 없음 |
| 외부 생존 감시 | T08b | C.8 `외부 생존 감시` 행: 시나리오 17. Period+Grace(10분) 뒤 healthchecks.io가 down으로 바꾸고 NUC를 거치지 않는 경로로 알림, 복구 뒤 up. | 경로 실제 검증 완료, 시나리오 17은 설계상 기대 <!-- TODO lead: S17 결과 --> | Watchdog firing, healthchecks webhook 최근 1시간 30회. T08b: ping 차단 20분에 down 알림, 해제 뒤 up 알림 | 시나리오 17 현장 차단 |

- **할 일 5(AC-P8):** 배포 갱신 주체가 아닌 신원의 digest PR이 자동 병합되지 않는지는 새로 만든 대역 App `ukyi-homelab-bot-standin-2`(contents·pull_requests write, webhook 없음, homelab·homelab-smoke 선택 설치)로 시나리오 15-7에서 봤다. App과 키는 시험 뒤 지웠다(approvals 2026-10-27 삭제 행).
- **AC-P12 리뷰 App 구조를 T10 증거로 갈음한 근거:** 시험 App `ukyi-homelab-review-probe`는 T10 시험(2026-10-21 20:12~20:24) 뒤 20:26에 삭제됐다. lead는 2026-10-26에 probe App을 다시 만들어 확인하는 안을 세웠지만, 사용자가 2026-10-27에 "T10 증거로 갈음(한계)"으로 정했다(approvals 같은 날 사용자 결정 행). T10 증거는 실제 설치·토큰 시험이고, 지금 운영 App들도 같은 저장소별(`selected`) 설치를 쓴다. 실제 리뷰 App의 설치와 확인은 T17이다.
