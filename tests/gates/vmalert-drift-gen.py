#!/usr/bin/env python3
"""vmalert-drift-firing-e2e 하네스용 합성 시계열 생성기 — VictoriaMetrics /api/v1/import(JSON lines).

라이브 데이터 모델을 그대로 재현한다:
  - ghcr_latest_digest{app,digest}      = 1  → digest-exporter CronJob의 **push** 메트릭(주기 = 크론 간격)
  - kube_pod_container_info{image_spec=…, image_id=…} = 1  → KSM **scrape** 메트릭(주기 = scrape 간격)
    · image_spec = 파드 **spec**이 핀한 이미지 참조(= values의 digest 핀 = GHCR **인덱스** digest)
    · image_id   = **containerd**가 보고하는 실제 이미지 참조(= 최초 저장 시점의 인덱스 digest)
    라이브 KSM은 두 라벨을 **모두** 내보낸다. 평시엔 둘의 digest가 같지만, 항상 같지는 않다(아래 attestation).
digest는 image_id의 `…@sha256:<manifest digest>`에서 추출된다(라이브 실측: `image` 라벨은 bare ID라 못 씀).

시나리오(argv[1]):
  drift   — exporter latest digest ≠ 파드 digest가 전 구간 지속(진짜 드리프트 → 발화해야 함)
  nodrift — 양쪽 digest 동일(드리프트 없음 → 어떤 ImageDigestDrift 시리즈도 없어야 함)
  phantom — 이미지 bump: 파드가 먼저 새 digest로 전환되고(ArgoCD sync) exporter가 다음 폴링에서 따라잡는다.
            수렴 후엔 실제 드리프트가 0이다 → 발화 금지. 하지만 record의 rollup 윈도가 과대하면 구 digest
            시리즈가 rollup 안에서 되살아나 for: 윈도를 넘겨 **오발화**한다 — L3/L8이 정확히 그걸 잡는다.
  ksmdown — exporter push는 살아 있고 **파드 텔레메트리(kube_pod_container_info)가 통째로 없다**
            (KSM 사망 / scrape 단절). 조인 우변이 사라지면 `unless`가 아무것도 제거하지 못한다 →
            좌변에 rollup만 붙이고 **우변 존재 가드가 없으면** 전 앱이 for: 뒤에 "이미지 불일치"라는
            **거짓 사유**로 발화한다(진실은 "KSM이 죽었다"). L7이 그 두 번째 페이징 조건을 막는다.
            현행(버그) 룰에서도 좌변이 구멍나 무발화이므로 baseline에서도 통과한다.
  attestation — **buildx attestation 재빌드**(라이브 오탐의 실제 모양, page 앱에서 실측):
            buildx는 태그에 **인덱스**(arm64 이미지 매니페스트 + provenance/SBOM attestation 매니페스트)를
            push하는데 attestation이 **비결정적**이라 소스가 한 글자도 안 바뀐 재빌드에도 **인덱스 digest가
            바뀐다**. 그런데 arm64 자식 매니페스트는 **바이트 동일**이라 containerd는 이미 가진 콘텐츠를
            재사용하고 `image_id`로 **최초 저장 시점의 (구) 인덱스 digest**를 계속 보고한다.
            → exporter latest = 파드 spec 핀 = 신 인덱스, image_id = 구 인덱스. **배포된 콘텐츠는 동일**하다.
            현행 룰은 image_id만 조인하므로 영구 불일치로 오판 → **영구 firing**(오탐). 발화 금지가 정답.

argv: <scenario> <data_start_epoch> <data_end_epoch> <push_period_s> <scrape_s> <bump_epoch> <pod_switch_epoch>
"""
import json
import sys

SCENARIO = sys.argv[1]
DATA_START = int(sys.argv[2])
DATA_END = int(sys.argv[3])
PUSH_S = int(sys.argv[4])
SCRAPE_S = int(sys.argv[5])
BUMP = int(sys.argv[6])  # exporter가 새 digest를 처음 push하는 시각(push 그리드 정렬)
POD_SWITCH = int(sys.argv[7])  # 파드가 새 digest로 전환되는 시각(scrape 그리드 정렬)

D_OLD = "sha256:" + "a" * 64  # exporter가 보고하는 (구) latest digest
D_RUN = "sha256:" + "b" * 64  # 파드가 실제로 돌리는 digest (drift 시나리오)
D_NEW = "sha256:" + "c" * 64  # bump 후 digest (phantom 시나리오)
D_IDX = "sha256:" + "e" * 64  # attestation 재빌드로 새로 생긴 **인덱스** digest (콘텐츠는 D_OLD와 동일)

APP = "page"
REPO = "ghcr.io/ukyi-app/" + APP


def grid(step, start=DATA_START, end=DATA_END):
    """[start, end]를 step 간격으로 — 시작점을 step에 정렬(결정성)."""
    t = start + (-start % step)
    out = []
    while t <= end:
        out.append(t * 1000)
        t += step
    return out


def push_series(digest, timestamps):
    return {
        "metric": {
            "__name__": "ghcr_latest_digest",
            "app": APP,
            "digest": digest,
            "job": "digest-exporter",
        },
        "values": [1] * len(timestamps),
        "timestamps": timestamps,
    }


def pod_series(digest, timestamps, pod, uid, spec_digest=None):
    """digest=containerd가 보고하는 image_id의 digest, spec_digest=파드 spec이 핀한 digest.

    평시엔 둘이 같다(spec_digest 미지정 = digest). attestation 재빌드에서만 갈린다.
    """
    return {
        "metric": {
            "__name__": "kube_pod_container_info",
            "namespace": "prod",
            "pod": pod,
            "container": APP,
            # 라이브: values가 digest 핀이므로 파드 spec 이미지 참조도 `repo@sha256:…` 형태다.
            "image_spec": REPO + "@" + (spec_digest or digest),
            # ⚠️ 라이브 실측: `image`는 bare 이미지 ID라 digest 추출 소스가 될 수 없다 → image_id만이 SSOT.
            "image": "sha256:" + "d" * 64,
            "image_id": REPO + "@" + digest,
            "uid": uid,
            "job": "kube-state-metrics",
        },
        "values": [1] * len(timestamps),
        "timestamps": timestamps,
    }


out = []
if SCENARIO == "drift":
    out.append(push_series(D_OLD, grid(PUSH_S)))
    out.append(pod_series(D_RUN, grid(SCRAPE_S), APP + "-6d9f7c8b4-abcde", "1" * 8 + "-2222-3333-4444-" + "5" * 12))
elif SCENARIO == "nodrift":
    out.append(push_series(D_OLD, grid(PUSH_S)))
    out.append(pod_series(D_OLD, grid(SCRAPE_S), APP + "-6d9f7c8b4-abcde", "1" * 8 + "-2222-3333-4444-" + "5" * 12))
elif SCENARIO == "phantom":
    # exporter: BUMP 전엔 구 digest, BUMP 시각의 push부터 새 digest.
    out.append(push_series(D_OLD, [t for t in grid(PUSH_S) if t < BUMP * 1000]))
    out.append(push_series(D_NEW, [t for t in grid(PUSH_S) if t >= BUMP * 1000]))
    # 파드: POD_SWITCH에 교체된다(구 파드 시리즈 종료 + 새 파드 시리즈 시작 — 파드명/uid가 바뀌므로 별개 시리즈).
    old_ts = [t for t in grid(SCRAPE_S) if t < POD_SWITCH * 1000]
    new_ts = [t for t in grid(SCRAPE_S) if t >= POD_SWITCH * 1000]
    out.append(pod_series(D_OLD, old_ts, APP + "-6d9f7c8b4-abcde", "1" * 8 + "-2222-3333-4444-" + "5" * 12))
    out.append(pod_series(D_NEW, new_ts, APP + "-7f0a1b2c3-fghij", "9" * 8 + "-8888-7777-6666-" + "5" * 12))
elif SCENARIO == "ksmdown":
    # exporter는 정상 push, 파드 텔레메트리는 **전 구간 부재**(KSM 사망). 조인 우변이 통째로 없는 상태.
    # 의도적으로 pod_series를 하나도 넣지 않는다 — 하네스가 이 부재를 백필 sanity로 재확인한다.
    out.append(push_series(D_OLD, grid(PUSH_S)))
elif SCENARIO == "attestation":
    # exporter latest = **신 인덱스**(attestation 재빌드로 digest만 바뀜). 파드 spec 핀도 신 인덱스와 동일
    # (bump-poll이 values를 그 digest로 핀했다) — 즉 **배포는 최신이고 드리프트가 없다**.
    # 그런데 containerd는 arm64 자식 매니페스트가 바이트 동일이라 콘텐츠를 재사용하고 image_id로 **구 인덱스**를
    # 계속 보고한다. 전 구간 지속(파드 재생성이 없으면 영구) → 현행 룰은 영구 firing(오탐).
    out.append(push_series(D_IDX, grid(PUSH_S)))
    out.append(
        pod_series(
            D_OLD,  # image_id = 구 인덱스 (containerd 콘텐츠 재사용)
            grid(SCRAPE_S),
            APP + "-6d9f7c8b4-abcde",
            "1" * 8 + "-2222-3333-4444-" + "5" * 12,
            spec_digest=D_IDX,  # image_spec = 신 인덱스 (values 핀 = GHCR 최신)
        )
    )
else:
    sys.stderr.write("unknown scenario: %s\n" % SCENARIO)
    sys.exit(2)

for o in out:
    if not o["timestamps"]:
        sys.stderr.write("empty series in scenario %s — 시간창 계산 오류\n" % SCENARIO)
        sys.exit(2)
    print(json.dumps(o))

sys.stderr.write(
    "gen[%s]: %s\n"
    % (SCENARIO, " ".join("%s=%d" % (o["metric"].get("digest", o["metric"].get("pod")), len(o["timestamps"])) for o in out))
)
