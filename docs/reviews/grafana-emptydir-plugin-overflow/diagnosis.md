# 진단 — grafana emptyDir 플러그인 페이로드 초과로 인한 eviction 루프

- slug: `grafana-emptydir-plugin-overflow`
- 진단일: 2026-07-25
- 증상 보고: 2026-07-25 18:05 KST부터 telegram 알림 반복 (`PodEvicted` ×N, `PodOOMKilled`, `WorkloadUnavailable`)

## 근본 원인

**`platform/victoria-stack/prod/grafana.yaml:48`이 `/var/lib/grafana`를 받는 `data` emptyDir의
`sizeLimit`을 `256Mi`(262,144 KiB)로 선언하지만, grafana는 매 부팅마다 플러그인 전량을 바로 그 볼륨으로
런타임 다운로드하며 그 페이로드는 버전이 하나도 고정돼 있지 않아 업스트림이 마음대로 키운다.
2026-07-25 실측 페이로드는 262,844 KiB — 선언값을 700 KiB(0.27%) 초과한다. kubelet은
emptyDir이 `sizeLimit`을 넘으면 파드를 evict 하므로, grafana는 부팅 → 플러그인 다운로드 → 즉시 evict를
약 60초 주기로 무한 반복한다.**

즉 이 설정은 오래전부터 한계치의 **99.7%**에 붙어 있었고, 업스트림 플러그인 릴리스가 그 선을 넘기면서
터졌다. 코드 변경은 없었다 — `grafana.yaml`은 #312(2026-07-06) 이후 수정된 적이 없다.

### 왜 하필 오늘 18시인가 (도화선)

| 시각 (KST) | 사건 |
|---|---|
| 2026-07-07 20:00 | 당시 grafana 파드 기동 — 이때 다운로드한 플러그인 세트는 256Mi 미만이었고, emptyDir은 파드 수명 동안 유지되므로 18일간 무사 |
| 2026-07-20 | `grafana-lokiexplore-app` 2.4.0 릴리스 |
| 2026-07-21 | `grafana-metricsdrilldown-app` 2.3.0 릴리스 |
| 2026-07-22 | `victoriametrics-logs-datasource` 0.30.1 릴리스 |
| **2026-07-25 17:35:39** | **노드(OrbStack VM) 재부팅** — `node_boot_time_seconds` 실측. 전 파드 재시작, grafana emptyDir 소멸 |
| 2026-07-25 17:36:50 | 재부팅 71초 후 첫 grafana 파드 생성 → 커진 플러그인 세트를 새로 다운로드 → 첫 eviction |
| 2026-07-25 18:05 | 알림 `for:` 경과 후 telegram 발화 시작 (사용자 보고 시각과 일치) |

잠복해 있던 설정 결함을 **VM 재부팅이 기폭**시킨 형태다. 재부팅이 없었으면 파드가 살아있는 한
계속 숨어 있었을 것이다.

### 페이로드 내역 (2026-07-25 실측, `du -sk`)

| 항목 | KiB | 비고 |
|---|---:|---|
| `victoriametrics-logs-datasource` 0.30.1 | 213,400 | **우리가 요청한 유일한 플러그인.** 단일 zip에 8개 플랫폼 백엔드 바이너리(windows_amd64.exe·linux_s390x·darwin_amd64/arm64·freebsd_amd64·linux_amd64/arm/arm64)를 전부 담아 ~200 MiB. 이 노드는 arm64라 1개만 쓴다 |
| `grafana-lokiexplore-app` 2.4.0 | 18,076 | grafana 내장 preinstall 기본 목록 — 요청한 적 없음. Loki 미사용 |
| `grafana-pyroscope-app` 2.1.1 | 11,356 | 〃 Pyroscope 미사용 |
| `grafana-exploretraces-app` 2.1.0 | 9,348 | 〃 트레이싱 미사용 |
| `grafana-metricsdrilldown-app` 2.3.0 | 9,092 | 〃 |
| `grafana.db` + 기타 | 1,572 | SQLite |
| **합계** | **262,844** | vs `sizeLimit` 262,144 → **+700 초과** |

`defaults.ini`가 `preinstall_auto_update = true`, `update_strategy = minor`로 박혀 있어
preinstall 앱 4종은 **매 부팅마다 최신으로 갱신**된다 — 상한이 없다.

## 증거 — RED로 가는 명령

```
$ scratchpad/debug-a4f2-loop.sh
declared sizeLimit : 256Mi (262144 KiB)
measured boot usage: 262844 KiB
RED: 부팅 시 기록량이 선언된 emptyDir sizeLimit 이상 — kubelet이 파드를 evict 한다 (초과 700 KiB)
EXIT=1
```

이 루프는 `grafana.yaml`에서 선언값·이미지·`GF_INSTALL_PLUGINS`를 읽어(하드코딩 없음) 동일 스펙 프로브를
`sizeLimit: 1Gi`로 띄우고, 사용량이 안정될 때까지 폴링한 뒤 선언값과 비교한다. 약 60초, 결정적.

라이브 확증:

```
$ kubectl -n observability get events --field-selector reason=Evicted
Warning  Evicted  pod/grafana-7d94cf4ccc-fkcqv  Usage of EmptyDir volume "data" exceeds the limit "256Mi".
   (…60초 간격으로 계속)
$ kubectl -n observability get pods --no-headers | grep -c '^grafana-'
375
```

## 가설 순위와 실측 판정

Phase 3에서 세운 순위와, 프로브로 실제 검증한 결과다.

| # | 가설 | 예측 | 판정 |
|---|---|---|---|
| 1 | emptyDir `sizeLimit`이 런타임 플러그인 페이로드보다 작다 | 1Gi 프로브에서 사용량이 262,144 KiB를 넘을 것 | ✅ **확정** — 262,844 KiB |
| 2 | 노드 압박(디스크/메모리)에 의한 eviction | 노드 `DiskPressure`/`MemoryPressure`가 True일 것 | ❌ 기각 — 둘 다 False, 2026-06-14 이후 전이 없음. 루트 fs 189 GiB 여유 |
| 3 | grafana 메모리 limit(256Mi) 초과로 OOMKill | 종료 사유가 `OOMKilled`, exit 137일 것 | ❌ 기각 — 종료 사유는 `Evicted` / exit 0(SIGTERM 정상 종료) |
| 4 | 최근 커밋/ArgoCD 동기화가 grafana 스펙을 바꿨다 | `grafana.yaml` git 이력에 최근 변경이 있을 것 | ❌ 기각 — 최종 변경 #312(2026-07-06), ReplicaSet 해시 `7d94cf4ccc` 불변 |
| 5 | victorialogs OOM이 원인이고 grafana는 그 여파 | victorialogs 재시작이 grafana churn보다 **선행**할 것 | ❌ 기각 — 역방향. 아래 참조 |

## 2차 영향 — `victorialogs-0` OOMKilled는 하류 증상

grafana eviction 루프의 **결과**이지 별개 버그가 아니다.

| 지표 | 폭풍 이전 (−48h/−24h/−12h/−8h) | 폭풍 중 (−4h/−2h/현재) |
|---|---:|---:|
| `increase(vl_rows_ingested_total[1h])` | ~28,500 | ~145,000 (**5.1배**) |
| `increase(vl_streams_created_total[1h])` | 6–8 | ~124 (**약 18배**) |
| `kube_pod_container_status_restarts_total{container="victorialogs"}` | 1 (3일 이상 고정) | 8 |
| grafana 파드 개수 | 1 | 305 → 375 |

메커니즘: 시간당 약 60개의 새 grafana 파드 = 새 로그 스트림 약 120개(stdout/stderr) + 매 부팅마다 쏟아지는
플러그인 설치 로그 버스트 → VictoriaLogs 인제스트 5배 → limit `128Mi`(`--memory.allowedPercent=60`,
현재 working_set 96.9 MiB) 돌파 → OOMKill. 스트림 생성률 증가폭(약 118/h)이 파드 생성률(약 60/h)의
정확히 2배라는 점이 인과를 못박는다.

**grafana를 고치면 인제스트가 기저치로 복귀하므로 victorialogs는 별도 수정 대상이 아니다.**
다만 128Mi에 여유가 없다는 사실 자체는 드러났다 — 수정 후 재관찰 대상으로 남긴다.

`WorkloadUnavailable`도 마찬가지로 grafana Deployment가 Available=False로 10분 이상 머문 결과다.

## 수정 방향 — 실측으로 좁혀진 선택지

프로브로 세 조합을 직접 돌려 확인했다. **플러그인을 덜어내는 길은 Grafana 13.1.0에서 막혀 있다.**

| 설정 | 총 사용량 (KiB) | VL 데이터소스 | preinstall 앱 4종 |
|---|---:|---|---|
| 현행 `GF_INSTALL_PLUGINS` | 262,844 | ✅ | ✅ (불필요) |
| `GF_PLUGINS_PREINSTALL_SYNC=…@0.30.1` + `GF_PLUGINS_PREINSTALL=""` | 262,844 | ✅ (핀 적용) | ✅ **여전히 설치됨** |
| `GF_PLUGINS_PREINSTALL_DISABLED=true` + `…_SYNC=…@0.30.1` | 1,568 | ❌ **같이 죽음** | ❌ |

- 기본 preinstall 목록(`elasticsearch`·`zipkin`·앱 4종)은 `defaults.ini`가 아니라 **바이너리에 컴파일**돼
  있어 `GF_PLUGINS_PREINSTALL`을 비워도 사라지지 않는다.
- `GF_INSTALL_PLUGINS`는 Grafana 13에서 deprecated이며 내부적으로 **preinstall 경로로 라우팅**된다.
  따라서 유일한 킬스위치 `preinstall_disabled=true`는 우리가 요구한 데이터소스까지 함께 제거한다.
- 버전 핀만 걸어도 총량은 그대로다(위 2행) — **핀 단독으로는 이 버그가 고쳐지지 않는다.**

⇒ 최소 수정은 **용량 측**뿐이다.

### 채택 제안

`platform/victoria-stack/prod/grafana.yaml:48`

```yaml
- { name: data, emptyDir: { sizeLimit: 256Mi } }   # 현행
- { name: data, emptyDir: { sizeLimit: 512Mi } }   # 수정
```

- 여유 249 MiB(약 2.0배 마진). 노드 루트 fs 189 GiB 여유이므로 비용은 무시 가능.
- emptyDir 기본 medium은 디스크다(`medium: Memory` 아님) — **메모리 원장(`docs/memory-ledger.md`)과 무관**,
  갱신 불필요.
- 같은 파일 계열의 선례와 일치: `vmagent.yaml`은 이미
  `--remoteWrite.maxDiskUsagePerURL=450MiB` < `sizeLimit: 512Mi`로 동일 함정을 방어하고 있다.
  grafana에는 그 대응물(앱 내부 상한)이 없어 무방비였다.

**뒤집히는 관측 가능한 동작 1개**: grafana 파드가 부팅 후 emptyDir 초과로 evict 되지 않고 Ready를 유지한다.

### 이번 범위 밖 (수정 후 `/deepen` 권고)

- **런타임 다운로드 의존 자체의 제거** — initContainer로 arm64 바이너리만 받아 넣거나 플러그인을 구운
  커스텀 이미지. 페이로드가 ~215 MiB로 줄고 업스트림 드리프트가 사라지지만, 새 아키텍처 시임 + 공급망
  검증이 필요해 bugfix 범위가 아니다.
- **emptyDir 사용률 예측 알림** — 현재 `kubelet_volume_stats_*`는 PVC 전용이라 emptyDir 관측 지표가 없다.
  `pvc-du-exporter`를 emptyDir까지 확장하면 "터지기 전에" 잡을 수 있다.
- **`docs/traps-detail.md` 항목 추가** — "런타임 플러그인 다운로드 페이로드 vs emptyDir sizeLimit" 은
  라이브에서 검증된 새 함정이다.
- **누적 파드 오브젝트 375개 정리** — 수정 후 `kubectl -n observability delete pod --field-selector=status.phase!=Running`
  성격의 운영 작업(코드 변경 아님).
- **victorialogs 128Mi 마진 재평가** — 기저 복귀 확인 후 판단.

## Seam

**`platform/victoria-stack/prod/test_grafana_plugin_budget.bats`** ::
`@test "grafana data emptyDir sizeLimit keeps margin over the measured plugin payload"`

- 이 디렉토리는 이미 콜로케이트 bats 관례를 쓴다(`test_automount.bats`·`test_egress_netpol.bats` 등)
  → `run-bats.sh` gate 도메인에 자동 수집된다.
- 가드 내용: `grafana.yaml`의 `data` emptyDir `sizeLimit`이 실측 페이로드 기준선(2026-07-25: 262,844 KiB)
  대비 여유를 유지하는지. 실측치는 주석으로 근거를 남긴다.
- red-green: `256Mi`에서 실패, `512Mi`에서 통과하는 픽스처를 함께 둔다
  (`tests/test_resource_limits.bats`의 red-green 픽스처 방식과 동일).
- ⚠️ 한계(명시): 정적 가드라 **미래 업스트림 증가는 잡지 못한다**. 그건 위 `/deepen` 항목의
  emptyDir 사용률 알림이 담당해야 한다.
- bats 관례 준수: `@test` 이름은 영어(CJK 인코딩 함정), 중간 단언은 `[ ]`/`grep`만(bash 3.2 `[[ ]]` 침묵통과).
