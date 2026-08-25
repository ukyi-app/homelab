// vmalert 룰 expr 정적 lint — "문법은 유효한데 eval-time에 죽는" 결함 3종(모드 A/B/C) 재발 방지.
// 모드 A/B = instance-라벨 불안정(재부팅 IP churn 오탐, PR #327) · 모드 C = push 주기 > instant 룩백
// (죽은 알림, PR #339/#341).
//
// 배경: 호스트 재부팅이면 파드 오브젝트가 그대로여도 CNI가 파드 IP를 재할당해 스크레이프 타깃의
// `instance` 라벨이 바뀐다. 시계열 정체성이 갈리면서 두 파괴 모드가 나온다(둘 다 문법은 유효해서
// required 게이트인 `vmalert -dryRun`을 통과한다 — 그래서 4회 재발했다).
//
//   모드 A — rollup(increase/rate/…)이 **상태-파생 카운터**(exporter 재시작에도 값이 0으로 리셋되지
//            않는 것, 예: KSM의 kube_pod_container_status_restarts_total)에 걸려 있으면, 새 instance
//            시계열의 첫 샘플(=누적값)을 VM이 "0에서 증가"로 읽어 누적값을 통째로 증가분으로 오독한다.
//            → rollup **이전에** 집계로 instance를 벗겨야 한다(서브쿼리 필수).
//            프로세스-로컬 카운터(alertmanager_*/vmagent_*/vmalert_*)는 재시작 시 0 리셋이라 무해 —
//            그래서 판정 기준은 "rollup을 썼는가"가 아니라 "denylist 메트릭인가"다.
//
//   모드 B — 산술 이항 연산이 on()/ignoring()으로 instance를 매칭키에서 빼는데 피연산자가 raw 셀렉터면,
//            구/신 instance 시계열이 staleness(~5분) 동안 공존해 그룹당 2 시계열 → many-to-many →
//            "duplicate time series on the … side of" HTTP 422 → 룰 평가 실패.
//            → 양변을 max by(...)로 사전 집계해 1:1 매칭을 강제해야 한다.
//            (and/or/unless는 집합 연산자라 중복에 422를 내지 않는다 — 대상 아님.)
//
//   모드 C — **push(스크레이프 아닌) 메트릭을 연속성 보존 rollup 없이 참조**하면 그 룰은 어떤 조건에서도
//            발화하지 못한다. vmalert의 instant 질의 룩백은 `-datasource.queryStep`(미지정 시 기본 5m)인데
//            push 주기가 그보다 길면 매 주기 후반에 시리즈가 vmalert 눈에서 사라진다 → 룰 시리즈에 구멍 →
//            `for:` pending이 매 주기 리셋 → 임계 시간을 영원히 누적 못한다(`ImageDigestDrift` 라이브 60일
//            발화 0 · `FilesBulkSSDLow` 동일). 시리즈가 "없다"는 게 증상이라 **아무 신호도 나지 않는다**.
//            → `last_over_time(m[W])`류로 감싸야 한다(**W ≥ push 주기**).
//
// 모드 C가 **fail-open으로 뚫렸던 구멍 8개**. 아래 라벨은 본문 곳곳에서 인용되니 **이름을 유지한다**
// (각 구멍마다 회귀 프로브가 있다 — 지우기 전에 그 프로브부터 보라).
//   F-1 셀렉터 우회: `{__name__="m"}`·`{"m"}`(VM 축약)은 메트릭명을 문자열 안에 숨겨 토큰 스캔을 피한다.
//       → 마스킹 **전에** `m{...}`로 정규화. 정규식/부정(`=~`·`!~`·`!=`)은 이름 집합이 열려 fail-closed.
//   F-2 가짜 rollup: `irate`·`idelta` 등 **2샘플 요구** 함수는 push 주기상 결과가 비어 알림이 여전히 죽는다.
//       → 단일 샘플로도 값을 내는 `*_over_time` 계열(ROLLUP_OK)만 rollup으로 인정한다.
//   F-3 메트릭 등록 누락: 생산자 **파일 경로**만 보면 기존 exporter에 메트릭을 추가하는 최다 경로가 우회된다.
//       → 생산자에서 실제 push되는 **이름을 추출**해 레지스트리와 양방향 대조.
//   F-4 cron 권위 강등: schedule 파일 부재 시 상수 폴백하면 CronJob 이동·리네임만으로 교차검증이 뚫린다.
//       → schedule은 판별 가능한 소스다: `cron`(레포 내 — 부재/파싱불가 = FAIL) 또는 `external`(근거 필수).
//   G-1 생산자 발견이 단일 엔드포인트에 묶임: `api/v1/import` 하나로 찾으면 remote_write·influx·datadog·
//       opentsdb·URL 합성 push가 **발견 자체를** 우회한다. → 신호 = VM 수집 경로 조각 ∪ (VM 호스트 + 쓰기 동사).
//       읽기 전용 소비자는 쓰기 신호가 없어 후보가 안 된다 — **제외 목록을 두지 않는다**(그 자체가 우회로다).
//   G-2 URL 신호도 우회 가능: 호스트·경로가 전부 변수/시크릿이면 위 둘 다 안 걸린다. → 세 번째 신호는
//       **페이로드 모양**(쓰기 동사 + exposition 조립 성공). 판정표: [URL 있음·추출 성공]=생산자 /
//       [URL 있음·추출 실패]=**fail-closed FAIL** / [URL 없음·쓰기동사+추출 성공]=생산자 / 나머지=후보 아님.
//   S-1 rollup 윈도 귀속이 위치 기반: 폴백이 **아무 형제 서브쿼리의 첫 `[W:step]`**를 긁으면 미끼 윈도로
//       죽은 알림이 통과한다. → 메트릭을 **실제로 감싸는** depth-0 종료 서브쿼리만 집는다(스코프 인식).
//   S-2 heredoc 메트릭 누락: `EXPO_RE`가 진짜 개행을 못 봐 heredoc push를 놓쳤다(다른 메트릭이 있으면
//       fail-closed도 안 걸린다). → 줄 전체를 `name{labels} value [ts]$`로 앵커링하는 `EXPO_LINE` 추가.
//
// 한계(의도적 — 여전히 못 잡는 것):
//  - 정적 패턴 검사라 remediation의 **정확성**은 보장하지 않는다. 모드 A의 집계자는 `max`여야 한다 —
//    순진한 `sum without(instance)`는 staleness 중첩 구간에서 값이 배가된다. denylist는 큐레이트 목록이라
//    미래의 상태-파생 `increase(kube_*_total)`은 목록 확장이 필요하다(false-negative 가능).
//  - 모드 C가 강제하는 것은 **하한(W ≥ 주기)뿐**이다. 강화판 둘은 룰마다 값이 갈려 린터가 판정할 수 없다 →
//    각 e2e 게이트의 preflight 산술 단언 소관이다:
//      · 누락 내성 **W ≥ 2×주기**를 여기서 강제하면 배포된 `ImageDigestDrift` 픽스(W=15m, 주기 10m)가
//        FAIL한다 — W=15m은 `for: 20m` **상한 때문에 강제된 선택**이다.
//      · **상한 W < `for:`**(라벨-값 상태 게이지 한정 — rollup 윈도가 구 상태를 되살리는 래치라서).
//        타임스탬프-값 하트비트(r4의 `time() - last_over_time(…)`)엔 상한이 없다 → 이 비대칭은 린터가
//        구분 못 한다. cf. `docs/traps-detail.md` 「rollup 윈도 상한 — 상태 게이지 vs 하트비트 비대칭」.
//  - **rollup 함수 선택도 못 본다**(위 비대칭의 세 번째 축). `ROLLUP_OK`는 "단일 샘플에도 값을 내는가"만
//    판정하므로 `last_over_time`과 `max_over_time`이 **둘 다** 통과한다. 그런데 값이 **클러스터 밖**에서 오면
//    공급원이 역행 샘플을 줄 수 있고(GitHub Actions API가 낡은 스냅샷을 200으로 반환 — 라이브 실측),
//    그때 단조량에 `last_over_time`을 쓰면 그 한 샘플이 그대로 오발화가 된다. 판별 기준은 "타임스탬프인가"가
//    아니라 **"값이 클러스터 밖에서 왔는가 · 내려가는 것이 사실일 수 있는가"**다 — 아래 레지스트리엔 아직
//    그 축(공급원의 단조성)이 없어 **레포 전역 강제가 없다**(알려진 잔여). 현재 이 클래스의 원소는
//    `gha_workflow_last_success_timestamp` 하나뿐이고, 그 인스턴스는 gate 3종이 지킨다.
//    cf. `docs/traps-detail.md` 「GitHub API는 낡은 스냅샷을 200으로 돌려준다 …」.
//  - **동적으로 합성된 메트릭명**(`label_replace`로 만든 이름, 변수 조립)은 정적으로 추적 불가.
//  - 생산자 메트릭 추출은 **exposition 페이로드 조립부의 알려진 형태**만 인식한다: 인라인(printf 포맷 ·
//    `VAR="${VAR}name{…} val\n"` 누적)과 **heredoc(진짜 개행 줄)**(S-2). 추출 0이면 **fail-closed**(FAIL)지만,
//    이 세 형태 밖(예: 셸 배열을 loop로 join)이면 **일부만** 인식될 수 있다 → 알려진 형태로 쓰거나 EXPO_*를 넓혀라.
//  - 생산자 발견은 **이 레포 안 · 텍스트로 조립되는 페이로드**만 본다:
//    (a) **앱 레포(`ukyi-app/*`)가 직접 push**하면 여기 스캔 범위 밖이다 — 그 메트릭을 알림 룰에서 읽으려면
//        레지스트리에 **수동 등재**해야 한다(등재 안 하면 모드 C가 그 메트릭을 안 본다).
//    (b) 호스트·수동 실행처럼 **레포에 코드가 없는** push.
//    (c) 클라이언트 **라이브러리**로 push하는 코드(protobuf remote_write SDK 등) — 페이로드가 문자열로
//        조립되지 않아 추출기(EXPO_*)가 볼 게 없다. URL이 코드에 있으면 (1)·(2) 신호로는 잡힌다.
//  - `PRODUCER_EXEMPT`(vmagent/vmalert 릴레이)는 사유가 강제되지만 **면제 자체가 신뢰 지점**이다 — 새 항목은
//    리뷰에서 "정말 고정 메트릭 집합이 없는가"를 물어야 한다.
//  - 모드 C의 record 체인: 기록룰이 rollup을 착용하면 그 **record명**은 연속 시리즈라 이를 참조하는 alert는
//    검사 대상이 아니다(push 메트릭명만 매칭 — 이중 계산 없음). 기록룰이 맨 참조면 결함은 **기록룰 1건**으로만
//    보고된다.
//
// check-resource-limits.ts를 미러한다(--repo-root · scan-floor · allowlist · 한국어 메시지).
import { existsSync, readFileSync } from "node:fs";
import { parse, parseAllDocuments } from "yaml";
import { parseFlags } from "./lib/cli.ts";
import { RULES_ROOT, walkManifests } from "./lib/repo-walk.ts";

let f: Record<string, string | boolean>;
try { f = parseFlags(process.argv.slice(2), { value: ["--repo-root", "--registry", "--supply-policy"], bool: [] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --repo-root · --registry · --supply-policy`); process.exit(2); }
const ROOT = typeof f["--repo-root"] === "string" ? (f["--repo-root"] as string) : ".";
// --registry: push 메트릭 레지스트리 주입(**테스트 픽스처 격리 전용**). 실 레포 검증은 항상 기본
// 레지스트리(DEFAULT_REGISTRY)로 돈다 — 부분 레포 루트를 쓰느라 프로덕션 검증을 약화시키지 않기 위함(F-4).
const REGISTRY_FILE = typeof f["--registry"] === "string" ? (f["--registry"] as string) : "";

// 룰 디렉토리 경로의 SSOT는 워커의 `rules` 스코프 root다(콜사이트 인라인 사본 금지).
const RULES_DIR = RULES_ROOT;
const DENYLIST = "policy/alert-instance-stability-denylist.txt";
const ALLOWLIST = "policy/alert-instance-stability-allowlist.txt";
const MIN_SCAN = 30;   // 실 룰 49건(48 alert + 1 record) — 셀렉터 붕괴 false-green 차단
// denylist 항목 바닥값 — 파일이 남아 있는데 **내용만** 비거나 주석만 남는 부분 드리프트를 잡는다
// (필수 읽기는 파일 부재만 잡는다). 실 원장 1항목 — 이 목록은 줄어들 이유가 없다. 래칫 아님.
const MIN_DENY = 1;

// rollup(range) 함수 — 이들만 시계열 첫 샘플을 "0에서 증가"로 취급할 수 있다.
const ROLLUP = "increase|increase_pure|increase_prometheus|rate|rate_prometheus|irate|delta|idelta|deriv|resets|changes";
// 라벨을 벗길 수 있는 집계 연산자.
const AGG = "max|min|sum|avg|count|group|topk|bottomk|quantile|stddev|stdvar";
const OPERAND_AGG_RE = new RegExp(`^[\\s(]*(?:${AGG})\\s+(?:by|without)\\s*\\(`);
// on()/ignoring() 뒤에 올 수 있는 **매칭 수식어** — 피연산자가 아니다. 우변을 읽기 전에 벗겨야 한다.
// 벗기지 않으면 `on(...) group_left(x) max by (...) (m)`의 우변이 `group_left…`로 시작하는 것으로 보여
// **정상적으로 사전 집계된 우변을 raw로 오판**한다. many-to-one 조인은 group_left 없이 표현할 수 없으므로
// 그 오판은 해당 조인 형태 전체를 allowlist(=룰 단위 → 모드 A/C까지 동반 해제)로 밀어낸다.
// ⚠️ 수식어만 벗기고 그 뒤 피연산자는 그대로 판정한다 — 검사 자체를 건너뛰면 group_left 모양의 구멍이 된다
//    (tests/test_alert_rules.bats가 두 방향을 모두 잠근다).
const GROUP_MOD_RE = /^\s*group_(?:left|right)\s*(?:\([^)]*\))?/;
// 집합 연산자 — on()을 써도 422가 불가능하다.
const SET_OP_RE = /(?:^|[^\w])(and|or|unless)\s*$/;
// 산술·비교 이항 연산자(on() 직전에 올 수 있는 것).
const BIN_OP_RE = /(?:==|!=|>=|<=|[+\-*/%^]|>|<)\s*$/;

// ── 모드 C 상수 ──
// **생산자 발견 신호**(G-1). `api/v1/import` 문자열 하나로 찾으면 remote_write·influx·datadog·opentsdb·
// vmagent 경유·URL 합성 push가 **발견 자체를 우회**한다 → 우리가 막으려던 fail-open이 그대로 남는다.
// 두 갈래로 찾는다: (1) VM 수집(쓰기) 엔드포인트 경로 조각, (2) vmsingle/vmagent 호스트 + 쓰기 요청 동사
// (URL이 변수로 합성돼 경로가 안 보여도 잡힌다).
const WRITE_PATH_RES: RegExp[] = [
  /api\/v1\/import(?:\/[a-z]+)?/,   // /api/v1/import{,/prometheus,/csv,/native}
  /api\/v1\/write/,                 // Prometheus remote_write
  /\/influx(?:\/|\b)/,              // InfluxDB 라인 프로토콜(/write · /influx/api/v2/write)
  /\/datadog(?:\/|\b)/,
  /\/opentsdb(?:\/|\b)/,
];
const VM_HOST_RES: RegExp[] = [/\bvmsingle\b/, /\bvmagent\b/, /:8428\b/, /:8429\b/];
const WRITE_VERB_RES: RegExp[] = [
  /--data-binary/, /--data-raw/, /--data\s+@/, /\s-d\s+@/, /-X\s*POST/, /--request\s+POST/,
  /remoteWrite/, /remote_write/,
];
// ★ 읽기 전용 소비자(homepage 위젯·grafana 데이터소스·netpol·게이트 스크립트)는 위 신호가 **없다** —
//   `/api/v1/query`·`/export`·`/series`·`/rules`는 쓰기 신호가 아니라 애초에 후보가 되지 않는다.
//   읽기 경로 "제외 목록"을 두지 않는 이유: 제외 목록 자체가 우회 경로가 된다(읽기 경로로 위장한 push는
//   불가능하므로 신호를 **양성 목록**으로만 두는 편이 엄격하다).
// 자기 참조 제외: 이 파일이 신호 문자열들을 리터럴로 들고 있다.
const SELF = "tools/check-alert-rules.ts";

// VM에 쓰지만 **큐레이트 메트릭 생산자가 아닌** 인프라 릴레이 — 고정된 메트릭 이름 집합이 없다(시계열
// 이름의 소유자가 딴 데 있다). 사유 필수(무근거 면제 금지). 새 항목은 반드시 리뷰 대상이다.
const PRODUCER_EXEMPT: Record<string, string> = {
  "platform/victoria-stack/prod/vmagent.yaml":
    "스크레이프 릴레이 — remoteWrite로 전달만 한다(메트릭 이름은 스크레이프 타깃이 소유). push 주기 = 스크레이프 간격(≤ 룩백)이라 모드 C 대상이 아니다.",
  "platform/victoria-stack/prod/vmalert.yaml":
    "recording rule 결과 remoteWrite — 이름은 룰 파일이 소유하고 이 린터가 직접 검사한다. 기록 주기 = vmalert 평가 간격(≤ 룩백).",
};
const VMALERT_MANIFEST = "platform/victoria-stack/prod/vmalert.yaml";

// **연속성 보존 rollup**(F-2): 윈도 안 샘플이 **1개뿐이어도 값을 내는** 함수만 push 구멍을 메운다.
// irate/idelta/rate/increase/delta/deriv/resets/changes는 **2샘플 이상**을 요구해, push 주기보다 좁은 시야에선
// 결과가 비어버린다 → rollup으로 인정하지 않는다(인정하면 "가짜 픽스"가 게이트를 통과한다).
// 목록 밖 함수는 **fail-closed**(위반) — 새 함수를 쓰려면 단일 샘플 안전성을 확인하고 여기 등재하라.
const ROLLUP_OK = new Set([
  "last_over_time", "first_over_time", "max_over_time", "min_over_time", "avg_over_time",
  "sum_over_time", "count_over_time", "median_over_time", "mode_over_time", "quantile_over_time",
  "present_over_time", "absent_over_time", "distinct_over_time", "geomean_over_time",
  "tlast_over_time", "tfirst_over_time", "tmin_over_time", "tmax_over_time", "default_rollup",
]);

// 모드 D의 메트릭 토큰 필터 — PromQL 내장/키워드는 메트릭이 아니다. 뒤에 `(`가 오는 토큰은 이미
// 함수 호출로 걸러지지만, 인자 없이 쓰이는 키워드(`bool`·`offset` 등)는 여기서 뺀다.
const PROMQL_BUILTIN = new Set([
  "time", "vector", "scalar", "absent", "absent_over_time", "bool", "offset", "start", "end",
  "max", "min", "sum", "avg", "count", "count_values", "stddev", "stdvar", "topk", "bottomk", "quantile",
  "group", "rate", "irate", "increase", "delta", "idelta", "deriv", "predict_linear", "resets", "changes",
  "label_replace", "label_join", "clamp", "clamp_max", "clamp_min", "round", "abs", "ceil", "floor",
  "histogram_quantile", "timestamp", "day_of_week", "day_of_month", "days_in_month", "hour", "minute",
  "month", "year", "unless", "ignoring", "group_left", "group_right", "without",
]);
let supplyRefs = 0;   // 모드 D가 **실제로 판정한** 참조 수(원장 크기와 다른 축 — 강제 루프가 죽으면 여기가 0이 된다)

// ── push 메트릭 레지스트리 (큐레이트 SSOT) ──
//   metric   = 룰 expr에서 매칭할 시계열 이름
//   producer = `api/v1/import`로 push하는 파일(완전성 가드가 스캔에서 만나는 파일). 이 파일이 push하는
//              **모든 메트릭**이 레지스트리에 있어야 하고(F-3), 역으로 레지스트리 메트릭은 생산자가 실제로
//              push해야 한다(이름 변경/삭제 드리프트 차단).
//   schedule = cron(레포 내 CronJob — 주기를 **여기서만** 파생, 파일 부재/파싱불가 = FAIL) |
//              external(CronJob 밖 스케줄 — 호스트 systemd timer 등: 상수 + 근거 필수). F-4.
type Schedule =
  | { kind: "cron"; file: string }
  | { kind: "external"; periodSec: number; why: string };
type PushEntry = { metric: string; producer: string; schedule: Schedule };

const DIGEST_EXPORTER = "platform/victoria-stack/prod/digest-exporter.yaml";
const DU_EXPORTER = "platform/victoria-stack/prod/pvc-du-exporter.yaml";
const GHA_LIVENESS = "platform/victoria-stack/prod/gha-liveness-exporter.yaml";
const ADGUARD_RECONCILER = "platform/adguard/prod/rewrite-reconciler.yaml";
const RESTORE_DRILL = "platform/cnpg/prod/restore-drill-script.sh";
const FILES_BACKUP = "scripts/backup-files-data.sh";
// ⚠️ **국면 A(NUC 이식) 동안 이 스케줄은 의도적으로 돌지 않는다.** 실행자(`scripts/backup-files-data.sh`)는
//    리눅스로 재작성됐고 — 매체 판별 권위가 `diskutil`이 아니라 `findmnt`+`lsblk`의 디바이스 정체성이다 —
//    배선도 끝나 있다(호스트 systemd 유닛 `files-data-backup.{service,timer}`, OnCalendar=daily,
//    `infra/k3s-bootstrap/host-config/etc/systemd/system/` 아래 tracked). 그런데 국면 A에서는 그 타이머를
//    **enable하지 않는다**(NUC은 디스크가 하나라 source·dest가 같은 물리 매체 — 켜면 정직한 red가 아니라
//    false-green이 된다. 사유는 service 유닛 머리말). 그래서 periodSec=86400은 **관측된 주기가 아니라
//    계약상의 주기**다 — 이 레지스트리는 external을 "CronJob 밖 스케줄"로만 정의하고 그 스케줄이
//    실제로 도는지는 원리적으로 검사하지 않는다.
// ⚠️ 그래도 **86400을 유지한다.** 이 값이 모드 C의 rollup 윈도 하한(W ≥ 주기)을 만들고 r4의
//    FilesBackupStale [10d] · FilesBulkSSDLow [3d]가 그 하한 위에 서 있다. 낮추거나 지우면 국면 B에서
//    타이머를 enable할 때 윈도 검사가 이미 헐거워져 있다(죽은 알림 재발).
// ⚠️ **스크립트를 지우는 것도 답이 아니다** — 생산자 파일 부재는 이 도구가 fatal로 잡고, 무엇보다
//    국면 B에서 enable할 실행자가 없어진다. 미가동의 기록은 여기 why + r4 룰 주석 +
//    `tests/gates/test_files-backup-phase-a.bats`(억제 절 ↔ 창 양방향 정합)가 나눠 진다.
// ⚠️ 근거 인용은 `scripts/backup-files-data.sh` 헤더 + 타이머 유닛으로 둔다.
//    `docs/runbooks/external-ssd.md`는 2026-08-17 베어메탈 재작성 이후 배선·enable 절차를 담지만
//    **gitignored 로컬 전용**이라 tracked 근거가 되지 못한다(옛 인용을 뺀 사유였던 "그 런북엔 한
//    글자도 없다"는 그 재작성으로 낡았다).
const SYSTEMD_TIMER_DAILY: Schedule = {
  kind: "external",
  periodSec: 86400,
  why: "계약상 일 1회(RPO=24h) — 근거: scripts/backup-files-data.sh 헤더 + " +
    "infra/k3s-bootstrap/host-config/etc/systemd/system/files-data-backup.timer(OnCalendar=daily). " +
    "⚠️ 국면 A(infra/k3s-bootstrap/versions.env의 BULK_MIGRATION_WINDOW_UNTIL이 비어 있지 않은 동안)에는 " +
    "**이 타이머를 의도적으로 enable하지 않는다**(source·dest가 같은 물리 매체라 false-green이 된다). " +
    "이 값은 rollup 윈도 하한을 지키기 위한 계약 상수이지 관측된 주기가 아니다 — 국면 B에서 타이머를 " +
    "enable할 때 실제 주기로 재확인하고 이 문구를 갱신하라.",
};

const DEFAULT_REGISTRY: PushEntry[] = [
  // digest-exporter는 같은 curl 페이로드에 수집 결과(ghcr_latest_digest)와 자기관측 메트릭 3종을 함께 싣는다.
  // 하트비트 의미론 = **push 경로 생존**(수집 성공 아님) → DigestExporterStale(r4)이 이걸 읽는다.
  // 수집 카운트 2종(configured/scraped)은 그 **직교 축**이다 — push는 살아 있는데 skopeo가 일부/전부 실패하는
  // 부분 고장을 관측한다 → DigestExporterScrapeIncomplete(r4). 셋 다 같은 CronJob(*/10) 주기라 모드 C 대상.
  ...["ghcr_latest_digest", "digest_exporter_last_success_timestamp",
    "digest_exporter_apps_configured", "digest_exporter_apps_scraped"]
    .map((metric): PushEntry => ({ metric, producer: DIGEST_EXPORTER, schedule: { kind: "cron", file: DIGEST_EXPORTER } })),
  ...["pvc_dir_size_bytes", "storage_tier_size_bytes", "storage_tier_avail_bytes", "pvc_du_last_success_timestamp"]
    .map((metric): PushEntry => ({ metric, producer: DU_EXPORTER, schedule: { kind: "cron", file: DU_EXPORTER } })),
  // gha-liveness-exporter(*/30) — GHA 스케줄 워크플로의 **마지막 성공 시각**을 GitHub API에서 읽어 push.
  // 09가 닫지 못한 표면(run이 아예 발생하지 않는 것)의 유일한 관측자라, 이 push가 끊기면 그 감시가
  // 통째로 실명한다 → GHALivenessExporterStale(r6)이 하트비트를 읽고, ScrapeIncomplete가 부분 고장을 읽는다.
  // 예산(max_age)도 메트릭으로 함께 싣는다 — 룰이 워크플로별 임계값을 하드코딩하지 않게 하려는 것이다.
  ...["gha_workflow_last_success_timestamp", "gha_workflow_max_age_seconds",
    "gha_liveness_configured", "gha_liveness_scraped", "gha_liveness_last_success_timestamp"]
    .map((metric): PushEntry => ({ metric, producer: GHA_LIVENESS, schedule: { kind: "cron", file: GHA_LIVENESS } })),
  ...["adguard_rewrite_reconcile_timestamp", "adguard_rewrite_last_fix_timestamp"]
    .map((metric): PushEntry => ({ metric, producer: ADGUARD_RECONCILER, schedule: { kind: "cron", file: ADGUARD_RECONCILER } })),
  // push는 스크립트가, 크론(`0 5 * * 0` 주 1회)은 별도 CronJob 매니페스트가 들고 있다.
  { metric: "restore_drill_last_success_timestamp", producer: RESTORE_DRILL,
    schedule: { kind: "cron", file: "platform/cnpg/prod/restore-drill-cronjob.yaml" } },
  ...["files_backup_last_success_timestamp", "files_data_bulk_avail_bytes", "files_data_bulk_size_bytes"]
    .map((metric): PushEntry => ({ metric, producer: FILES_BACKUP, schedule: SYSTEMD_TIMER_DAILY })),
];

function fatal(msg: string): never { console.error(`FAIL: ${msg}`); process.exit(1); }

// ⚠️ 정책 파일은 **필수 읽기**다. 옛 `existsSync(p) ? … : []` 폴백은 파일 부재/이동/오타 경로를
// "항목 0개"로 위장했다. denyMetrics가 비면 모드 A의 `denyMetrics.find(...)`가 상시 미스라
// `continue`로 빠지고, 성공 메시지는 여전히 "모드 A/B/C 위반 0"이라며 **검사했다고 주장한다**.
// 적대 검토가 A/B 대조로 실측: 같은 위반 룰을 둔 채 denylist 파일만 치우면 rc 1 → 0, stderr 0줄.
// 모드 A가 지키는 것은 라이브에서 4회 재발한 instance 라벨 churn phantom-increase다(denylist 헤더 참조).
// allowlist는 부재 시 면제 0 = 더 엄격(fail-closed)이라 성격이 다르지만, **부재 자체는 양쪽 다 드리프트**다.
function readList(rel: string): string[] {
  const p = `${ROOT}/${rel}`;
  try {
    return readFileSync(p, "utf8").split("\n");
  } catch (e) {
    fatal(`정책 파일 읽기 실패(${rel}) — 검사 불가(이 자리가 0건 검사 후 초록이 되던 곳이다): ${e instanceof Error ? e.message : String(e)}`);
  }
}

// 문자열 리터럴 내부를 같은 길이의 채움문자로 마스킹 — 괄호/연산자 구조 스캔이 라벨 값에 속지 않게.
function maskStrings(s: string): string {
  const out = s.split("");
  let q: string | null = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === "\\") { out[i] = "_"; if (i + 1 < s.length) out[++i] = "_"; continue; }
      if (c === q) { q = null; continue; }
      out[i] = "_";
    } else if (c === '"' || c === "'" || c === "`") { q = c; }
  }
  return out.join("");
}

// `#` 주석을 줄 끝까지 마스킹(문자열 마스킹 **후** 호출 — 라벨 값 안의 '#'에 속지 않게).
function maskComments(s: string): string {
  const out = s.split("");
  for (let i = 0; i < s.length; i++) {
    if (s[i] !== "#") continue;
    while (i < s.length && s[i] !== "\n") out[i++] = " ";
  }
  return out.join("");
}

// pos의 '(' 에 대응하는 ')' 인덱스. 못 찾으면 -1.
function matchParen(s: string, open: number): number {
  let d = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === "(") d++;
    else if (s[i] === ")") { d--; if (d === 0) return i; }
  }
  return -1;
}

// end(배타) 직전의 피연산자 시작 인덱스 — 괄호 균형을 역방향 추적, 감싸는 '('를 만나면 멈춘다.
function operandStart(s: string, end: number): number {
  let d = 0;
  for (let i = end - 1; i >= 0; i--) {
    const c = s[i];
    if (c === ")") d++;
    else if (c === "(") { d--; if (d < 0) return i + 1; }
  }
  return 0;
}

// start(포함) 이후의 피연산자 끝 인덱스(배타) — 감싸는 ')' 또는 최상위 이항 연산자에서 멈춘다.
function operandEnd(s: string, start: number): number {
  let d = 0;
  for (let i = start; i < s.length; i++) {
    const c = s[i];
    if (c === "(") d++;
    else if (c === ")") { d--; if (d < 0) return i; }
    else if (d === 0 && /[+\-*/%^<>=!]/.test(c) && i > start) return i;
  }
  return s.length;
}

// ── 모드 C 헬퍼 ──

// MetricsQL 기간 리터럴 → 초. 복합(`1h30m`) 허용. 파싱 실패는 null(호출부에서 fail-loud).
function durationSec(d: string): number | null {
  const t = d.trim();
  if (!/^(?:\d+[smhdw])+$/.test(t)) return null;
  const U: Record<string, number> = { s: 1, m: 60, h: 3600, d: 86400, w: 604800 };
  let sec = 0;
  for (const mt of t.matchAll(/(\d+)([smhdw])/g)) sec += parseInt(mt[1], 10) * U[mt[2]];
  return sec;
}

function fmtSec(s: number): string {
  if (s % 86400 === 0) return `${s / 86400}d`;
  if (s % 3600 === 0) return `${s / 3600}h`;
  if (s % 60 === 0) return `${s / 60}m`;
  return `${s}s`;
}

// vmalert instant 질의 룩백. `-datasource.queryStep` 미지정 시 기본 5m(문서화되지 않은 상수) —
// 매니페스트가 그 플래그를 명시하면 **거기서 파생**한다(상수가 조용히 낡는 fail-open 차단).
function lookbackSec(): number {
  const p = `${ROOT}/${VMALERT_MANIFEST}`;
  if (!existsSync(p)) return 300;   // 테스트 루트 등 매니페스트 밖 — vmalert 기본값
  const mt = /-datasource\.queryStep=([0-9a-z]+)/.exec(readFileSync(p, "utf8"));
  if (!mt) return 300;              // 플래그 미지정 = vmalert 기본 5m
  const s = durationSec(mt[1]);
  if (s === null) fatal(`${VMALERT_MANIFEST}: -datasource.queryStep=${mt[1]} 파싱 실패 — 룩백을 파생할 수 없다`);
  return s;
}
const LOOKBACK = lookbackSec();

// cron → 연속 실행 간격(초). 이 레포가 실제로 쓰는 형태만 지원하고 나머지는 **fail-loud**(추측 금지).
function cronPeriodSec(sched: string, where: string): number {
  const fields = sched.trim().split(/\s+/);
  const bad = (why: string): never => fatal(
    `${where}: cron "${sched}" 주기 파생 실패(${why}) — 지원 형태(*/N * * * * · M H * * * · M H * * D)가 아니다. ` +
    `레지스트리 schedule을 external(상수 + 근거)로 바꾸거나 파서를 확장하라.`);
  if (fields.length !== 5) bad("필드 5개가 아님");
  const [mi, ho, dom, mon, dow] = fields;
  if (mon !== "*" || dom !== "*") bad("월/일 필드 고정은 미지원");
  if (dow !== "*") {
    if (!/^\d$/.test(dow) || !/^\d+$/.test(mi) || !/^\d+$/.test(ho)) bad("요일 지정인데 분/시가 고정값이 아님");
    return 604800;   // 주 1회
  }
  const em = /^\*\/(\d+)$/.exec(mi);
  const eh = /^\*\/(\d+)$/.exec(ho);
  if (ho === "*") {
    if (mi === "*") return 60;
    if (em) return parseInt(em[1], 10) * 60;
    if (/^\d+$/.test(mi)) return 3600;   // 매시 정각 1회
    bad("분 필드 형태 미지원");
  }
  if (eh && /^\d+$/.test(mi)) return parseInt(eh[1], 10) * 3600;
  if (/^\d+$/.test(ho) && /^\d+$/.test(mi)) return 86400;   // 일 1회
  return bad("시 필드 형태 미지원");
}

// 매니페스트에서 CronJob 스케줄 1건을 뽑는다. 파일 부재·다중 CronJob = **FAIL**(조용한 상수 폴백 금지, F-4).
function cronOf(rel: string): string {
  const p = `${ROOT}/${rel}`;
  if (!existsSync(p)) {
    fatal(`레지스트리가 schedule=cron으로 선언한 파일이 없다: ${rel} — CronJob을 옮겼거나 리네임했다면 ` +
      `레지스트리를 함께 고쳐라(상수로 조용히 강등하지 않는다).`);
  }
  const found: string[] = [];
  for (const doc of parseAllDocuments(readFileSync(p, "utf8"))) {
    const o = doc.toJS() as any;
    if (o?.kind === "CronJob" && typeof o?.spec?.schedule === "string") found.push(o.spec.schedule);
  }
  if (found.length !== 1) fatal(`${rel}: CronJob 스케줄 ${found.length}건 — 정확히 1건이어야 한다`);
  return found[0];
}

// 이 파일이 메트릭을 push하는가? 신호를 돌려준다(null = 후보 아님).
//   viaUrl=true  — URL로 VM에 쓰는 게 확실하다(경로 조각 또는 호스트+쓰기동사).
//   viaUrl=false — **G-2 페이로드 신호**: URL이 전부 변수/시크릿이라 파일에 아무 URL 흔적이 없어도,
//                  쓰기 동사 + Prometheus exposition 페이로드 조립이면 그건 메트릭 push다.
//                  (URL 신호에 기대는 한 `VM_URL="$(cat /etc/secret/vm-url)"` 형태가 발견을 통째로 우회한다.)
// 판정표: [URL 있음·추출 성공]=생산자 / [URL 있음·추출 실패]=fail-closed FAIL(VM에 쓰는데 해석 불가) /
//         [URL 없음·쓰기동사+추출 성공]=생산자(G-2) / [URL 없음·추출 실패]=후보 아님(그냥 다른 API 호출).
function producerSignal(text: string): { why: string; viaUrl: boolean } | null {
  for (const re of WRITE_PATH_RES) {
    const mt = re.exec(text);
    if (mt) return { why: `쓰기 엔드포인트 '${mt[0]}'`, viaUrl: true };
  }
  const verbRe = WRITE_VERB_RES.find((re) => re.test(text));
  if (!verbRe) return null;
  const verb = (verbRe.exec(text) as RegExpExecArray)[0].trim();
  if (VM_HOST_RES.some((re) => re.test(text))) {
    return { why: `vmsingle/vmagent 호스트 + 쓰기 요청('${verb}') — URL 합성 push`, viaUrl: true };
  }
  // exposition을 조립해 POST한다 = URL이 어디서 오든 메트릭 push다. 추출 성공이 곧 그 증거.
  // (exposition이 아닌 POST — AdGuard API JSON·telegram·alertmanager — 은 추출 0이라 후보가 아니다.)
  const metrics = extractMetrics(text);
  if (metrics.length) {
    return { why: `쓰기 요청('${verb}') + Prometheus exposition 페이로드 조립(${metrics.join("·")}) — URL이 변수/시크릿이어도 페이로드 모양이 push를 증명한다`, viaUrl: false };
  }
  return null;
}

// 생산자 표면 walk — 메트릭을 push하는 파일을 찾는다(하네스·벤더·자기 자신·룰 디렉토리 제외).
// 룰 디렉토리는 **소비자** 표면이다(이 린터의 검사 대상) — 생산자로 오인하면 안 된다.
type Candidate = { path: string; why: string; viaUrl: boolean; metrics: string[] };
// 생산자 표면은 **레포 전역**이다. 예전엔 7개 루트(PRODUCER_ROOTS)를 큐레이트했는데 그 유일한
// 근거가 "레포 전체 walk는 금물(루트에 scratch/워크트리 잔재가 있다)"였다 — 공유 워커는 **tracked**
// 열거(`git ls-files`)라 .scratch/는 gitignored, 워크트리 잔재는 untracked로 애초에 안 잡힌다.
// 근거가 사라져 목록도 없앴다: 손실 0, 표면 3건 확대(.claude/hooks/manifest-guard.sh ·
// .pre-commit-config.yaml · .sops.yaml). 큐레이트 목록은 **완전성 가드가 막으려는 바로 그
// staleness**(빠진 항목이 조용히 안 보임)를 스스로 갖고 있었다.
// 열거(레포 전역·하네스/charts 제외·생산자 확장자)는 공유 워커의 `producers` 스코프가 소유한다.
// 여기 남는 것은 전부 **의미론적 판정**이다 — "이 파일이 생산자인가"는 도메인 질문이지 "레포에
// 무엇이 있는가"가 아니다(design-r1 R-1). 특히 룰 디렉토리는 이 린터의 **검사 대상**(소비자 표면)
// 이라 생산자로 오인하면 안 되는 것이지, 존재하지 않는 파일이 아니다.
function collectProducers(): Candidate[] {
  const out: Candidate[] = [];
  for (const { path: r, text } of walkManifests("producers", ROOT)) {
    if (r === SELF || PRODUCER_EXEMPT[r]) continue;          // 면제는 사유와 함께 코드에 명시
    if (r.startsWith(`${RULES_DIR}/`)) continue;             // 소비자 표면 — 생산자 아님
    const sig = producerSignal(text);
    if (sig) out.push({ path: r, why: sig.why, viaUrl: sig.viaUrl, metrics: extractMetrics(text) });
  }
  return out;
}

// 생산자에서 **실제 push되는 메트릭 이름**을 추출한다(F-3). Prometheus exposition 페이로드 조립부의
// 알려진 형태를 인식한다:
//   printf 'name %s\n' …                     (이름이 따옴표 직후)
//   printf 'a %s\nb %s\n' …                  (이름이 **리터럴** `\n` 직후 — 이스케이프 문자열)
//   BODY="${BODY}name{labels} ${val}\n"      (이름이 `${VAR}` 확장 직후 — 라벨 안의 `${…}`도 허용)
//   <<EOF\nname{labels} 7\nEOF               (heredoc — 이름이 **진짜 개행** 직후, S-2)
// 이름 뒤에는 (선택)라벨 블록 + 공백 + **값 토큰**이 와야 한다 — 이 값 토큰 요구가 일반 셸 문자열
// ("vmsingle push failed …" 등)과 메트릭 라인을 가른다.
// EXPO_INLINE = 문자열/변수 안에서 조립되는 형태(값 토큰 = %fmt · $var · 숫자).
const EXPO_INLINE = /(?:\\n|\$\{[A-Za-z_][A-Za-z0-9_]*\}|["'`])([a-z_][a-z0-9_]*)(?:\{(?:\$\{[^}]*\}|[^{}])*\})?[ \t]+(?:%[a-z]|\$\{?[A-Za-z0-9_]|\d)/g;
// EXPO_LINE = **진짜 개행**으로 시작하는 exposition 라인. 줄 전체를 `name{labels} value [ts]$`로 앵커링해
// 좁힌다(값 뒤엔 선택 timestamp 하나만 오고 줄이 끝나야 한다). lookbehind/lookahead로 개행을 소비하지 않아
// 연속 라인이 전부 잡힌다. **heredoc 본문에만** 적용한다 — shell에서 메트릭명이 진짜 개행으로 시작하는 곳은
// heredoc뿐이고, 전역 적용하면 `return 1`·`exit 1`·`sleep 5`처럼 `단어 숫자` 셸 코드를 메트릭으로 오인한다.
const EXPO_LINE = /(?<=^|\n)[ \t]*([a-z_][a-z0-9_]*)(?:\{(?:\$\{[^}]*\}|[^{}])*\})?[ \t]+(?:-?\d[\d.eE+-]*|%[a-z]|\$\{?[A-Za-z0-9_])(?:[ \t]+-?\d+)?[ \t]*(?=\n|$)/g;
// heredoc 본문을 뽑는다: `<<[-~]?['"]?DELIM['"]?` … 뒤 라인부터 `DELIM`만 있는 줄 전까지(S-2).
function heredocBodies(text: string): string[] {
  const bodies: string[] = [];
  // `(?<!<)` — `<<<`(here-string)를 heredoc으로 오인하지 않는다(단일 라인 입력이라 본문이 없다).
  const open = /(?<!<)<<[-~]?\s*(['"]?)([A-Za-z_]\w*)\1/g;
  for (let m = open.exec(text); m; m = open.exec(text)) {
    const start = text.indexOf("\n", open.lastIndex);
    if (start < 0) break;
    const body: string[] = [];
    for (const line of text.slice(start + 1).split("\n")) {
      if (line.trim() === m[2]) break;   // 닫는 구분자(선택 들여쓰기)
      body.push(line);
    }
    bodies.push(body.join("\n"));
  }
  return bodies;
}
function extractMetrics(text: string): string[] {
  const out = new Set<string>();
  for (const mt of text.matchAll(EXPO_INLINE)) out.add(mt[1]);
  for (const body of heredocBodies(text)) for (const mt of body.matchAll(EXPO_LINE)) out.add(mt[1]);
  return [...out].sort();
}

// pos의 '{' 에 대응하는 '}' 인덱스(따옴표 인식). 못 찾으면 -1.
function matchBrace(s: string, open: number): number {
  let d = 0, q: string | null = null;
  for (let i = open; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === "\\") i++; else if (c === q) q = null; continue; }
    if (c === '"' || c === "'" || c === "`") { q = c; continue; }
    if (c === "{") d++;
    else if (c === "}") { d--; if (d === 0) return i; }
  }
  return -1;
}

// 최상위 콤마로 분할(따옴표·괄호 인식).
function splitTop(s: string): string[] {
  const parts: string[] = [];
  let d = 0, q: string | null = null, start = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === "\\") i++; else if (c === q) q = null; continue; }
    if (c === '"' || c === "'" || c === "`") { q = c; continue; }
    if (c === "{" || c === "(" || c === "[") d++;
    else if (c === "}" || c === ")" || c === "]") d--;
    else if (c === "," && d === 0) { parts.push(s.slice(start, i)); start = i + 1; }
  }
  if (s.slice(start).trim()) parts.push(s.slice(start));
  return parts;
}

// 셀렉터 의미론적 정규화(F-1): `{__name__="X", …}` · `{"X", …}`(VM 축약)를 `X{…}`로 되돌린다.
// 마스킹 **전에** 돌려야 한다 — 마스킹 후엔 이름이 이미 `_`로 지워져 있다.
// `__name__=~` / `!~` / `!=`는 이름 집합이 열려 있어 정규화 불가 → nameMatchers로 모아 fail-closed 판정.
function canonicalize(expr: string): { canon: string; nameMatchers: Array<{ op: string; pat: string }> } {
  let out = "";
  const nameMatchers: Array<{ op: string; pat: string }> = [];
  let i = 0;
  while (i < expr.length) {
    const c = expr[i];
    if (c === '"' || c === "'" || c === "`") {   // 문자열 리터럴은 통째로 복사
      let j = i + 1;
      while (j < expr.length && expr[j] !== c) { if (expr[j] === "\\") j++; j++; }
      out += expr.slice(i, Math.min(j + 1, expr.length));
      i = j + 1; continue;
    }
    if (c !== "{") { out += c; i++; continue; }
    const close = matchBrace(expr, i);
    if (close < 0) { out += expr.slice(i); break; }   // 불균형 → 원문 보존(하류가 파싱 실패로 잡는다)
    const prev = out.replace(/\s+$/, "").slice(-1);
    const bare = !/[\w:\]]/.test(prev);   // 앞에 식별자/`]`가 없으면 bare 셀렉터
    const parts = splitTop(expr.slice(i + 1, close));
    let name = "";
    const rest: string[] = [];
    parts.forEach((raw, k) => {
      const p = raw.trim();
      const nm = /^__name__\s*(=~|!~|!=|=)\s*(["'`])([\s\S]*)\2$/.exec(p);
      if (nm) {
        if (nm[1] === "=") { name = nm[3]; return; }
        nameMatchers.push({ op: nm[1], pat: nm[3] });
        rest.push(raw); return;
      }
      const sh = /^(["'`])([a-zA-Z_:][a-zA-Z0-9_:]*)\1$/.exec(p);   // VM 축약 {"metric", …} — 첫 항만
      if (sh && k === 0 && bare) { name = sh[2]; return; }
      rest.push(raw);
    });
    if (name && bare) out += `${name}{${rest.join(",")}}`;
    else out += expr.slice(i, close + 1);
    i = close + 1;
  }
  return { canon: out, nameMatchers };
}

// pos를 감싸는 첫 **함수 호출**(식별자 + '(')을 바깥으로 나가며 찾는다. 익명 괄호는 통과한다
// (`max by (x) (m)`의 `(m)` 등) → `last_over_time(max by (x) (m)[15m:1m])`의 소유자는 last_over_time.
function ownerFn(s: string, pos: number): { name: string; open: number; close: number } | null {
  let depth = 0;
  for (let i = pos; i >= 0; i--) {
    const c = s[i];
    if (c === ")") { depth++; continue; }
    if (c !== "(") continue;
    if (depth > 0) { depth--; continue; }
    let j = i - 1;
    while (j >= 0 && /\s/.test(s[j])) j--;
    const end = j;
    while (j >= 0 && /[\w:]/.test(s[j])) j--;
    const name = s.slice(j + 1, end + 1);
    if (name) return { name, open: i, close: matchParen(s, i) };
    // 익명 괄호 → 더 바깥으로
  }
  return null;
}

// from(메트릭명 직후) 위치에서 range 셀렉터 `[W]`/`[W:step]`를 읽는다. 라벨 매처 `{...}`는 건너뛴다.
function rangeAt(s: string, from: number): string | null {
  let j = from;
  const ws = () => { while (j < s.length && /\s/.test(s[j])) j++; };
  ws();
  if (s[j] === "{") { const c = s.indexOf("}", j); if (c < 0) return null; j = c + 1; ws(); }
  if (s[j] !== "[") return null;
  const c = s.indexOf("]", j);
  if (c < 0) return null;
  return s.slice(j + 1, c).split(":")[0].trim();   // 서브쿼리 [W:step]도 앞이 W
}

// 메트릭 토큰을 **실제로 감싸는** rollup 윈도를 스코프 인식으로 찾는다(S-1). owner = 메트릭을 감싸는
// 최내곽 함수(rollup). owner 인자를 종료하는 서브쿼리 `[W:step]`는 owner 본문에서 **paren-depth 0**에
// 있고 메트릭 **뒤**에 온다(브래킷은 식 뒤에 붙으므로). 형제 서브쿼리(`[1h:1m]` 등)는 paren-depth ≥ 1에
// 있어 절대 집히지 않는다 — 위치 기반 "본문 첫 [W]" 폴백이 미끼 윈도에 속던 버그를 없앤다.
function rollupWindow(s: string, metricPos: number, metricLen: number, owner: { open: number; close: number }): string | null {
  const direct = rangeAt(s, metricPos + metricLen);   // 메트릭에 직접 붙은 [W]
  if (direct !== null) return direct;
  const rel = metricPos - (owner.open + 1);            // 본문 내 메트릭 상대 위치
  const body = s.slice(owner.open + 1, owner.close);
  let depth = 0;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (c === "(") depth++;
    else if (c === ")") depth--;
    else if (c === "[" && depth === 0 && i > rel) {   // 메트릭을 감싸는 depth-0 종료 서브쿼리
      const close = body.indexOf("]", i);
      if (close < 0) return null;
      return body.slice(i + 1, close).split(":")[0].trim();
    }
  }
  return null;
}

const denyMetrics = readList(DENYLIST).map((l) => l.split("#", 1)[0].trim()).filter(Boolean);

// ── 모드 D: 공급원 의미론 정책 (알림이 `time()`과 빼서 비교하는 시계열) ──
//   질문이 모드 C와 **다르다**: 저긴 "이 값이 얼마나 자주 push되는가"(생산자), 여긴 "이 값이 내려갈
//   수 있는가 · 신선도가 클러스터 밖 읽기에 의존하는가"(의미론)다. 후자가 필요한 메트릭 일부는
//   스크레이프라 push 레지스트리에 **원리적으로 존재할 수 없다**(barman_cloud_… · certmanager_… ·
//   kube_job_status_*) — 그래서 SSOT를 나눈다. 정책 파일 헤더가 판별 기준의 SSOT다.
// --supply-policy: 정책 주입(**테스트 픽스처 격리 전용**). 실 레포 검증은 항상 기본 경로를 쓴다.
// ⚠️ 주입 모드는 **바닥값만 면제**한다(형제 가드의 확립된 관용구 — check-bats-style의 명시-파일 모드와
//    같다). 신호는 그대로 내고 강제 로직도 그대로 돈다 — 면제되는 것은 "도메인이 충분히 큰가"뿐이다.
const SUPPLY_INJECTED = typeof f["--supply-policy"] === "string" ? (f["--supply-policy"] as string) : "";
const SUPPLY_POLICY = SUPPLY_INJECTED || "policy/alert-supply-monotonicity.json";
const MIN_SUPPLY = 12;      // 열거 붕괴 바닥값(도입 시 15건). 도메인이 줄지 않는 한 손댈 일이 없다.
const MIN_SUPPLY_REFS = 12; // **강제**가 실제로 몇 건을 판정했는가 — 원장 크기와 별개 축이다(아래 참조).
type SupplyEntry = { metric: string; supply: "in-cluster" | "external"; decreasing: "impossible" | "is-truth"; why: string };
// ⚠️ 정책 파일은 **필수 읽기**다(모드 A의 규율 미러) — 부재/오타 경로를 "항목 0개"로 위장시키지 않는다.
function loadSupply(): SupplyEntry[] {
  let raw: string;
  try { raw = readFileSync(SUPPLY_INJECTED ? SUPPLY_POLICY : `${ROOT}/${SUPPLY_POLICY}`, "utf8"); }
  catch (e) { fatal(`${SUPPLY_POLICY}를 읽을 수 없다(${(e as Error).message}) — 부재를 '항목 0개'로 위장시키지 않는다`); }
  let parsed: { metrics?: SupplyEntry[] };
  try { parsed = JSON.parse(raw); } catch (e) { fatal(`${SUPPLY_POLICY} JSON 파싱 실패: ${(e as Error).message}`); }
  const list = parsed.metrics;
  if (!Array.isArray(list)) fatal(`${SUPPLY_POLICY}에 metrics 배열이 없다`);
  for (const e of list) {
    if (!e?.metric) fatal(`${SUPPLY_POLICY}: metric 필드가 없는 항목이 있다`);
    if (e.supply !== "in-cluster" && e.supply !== "external") fatal(`${SUPPLY_POLICY}: ${e.metric}의 supply가 'in-cluster'|'external'이 아니다`);
    if (e.decreasing !== "impossible" && e.decreasing !== "is-truth") fatal(`${SUPPLY_POLICY}: ${e.metric}의 decreasing이 'impossible'|'is-truth'가 아니다`);
    if (!e.why || !e.why.trim()) fatal(`${SUPPLY_POLICY}: ${e.metric}에 why(근거)가 없다 — 무근거 선언은 금지`);
  }
  return list;
}
const SUPPLY = loadSupply();
const supplyOf = new Map(SUPPLY.map((e) => [e.metric, e]));
// **화이트리스트**다. "max만 금지"로 두면 avg/sum이 통과하는데 `sum_over_time(타임스탬프[W])`는
// `time() - 거대값`이 영구 음수라 **조용한 무발화**다(격리 사본 실증).
function requiredRollup(e: SupplyEntry, flipped: boolean): string {
  if (e.supply === "external" && e.decreasing === "impossible") return flipped ? "min_over_time" : "max_over_time";
  return flipped ? "min_over_time" : "last_over_time";
}
if (denyMetrics.length < MIN_DENY) {
  fatal(`denylist 항목 ${denyMetrics.length}건 < ${MIN_DENY}(${DENYLIST}) — 열거 붕괴 의심(모드 A가 통째로 무발화한다)`);
}

// ── 레지스트리 로드 + 완전성 가드(모드 C 전처리) ──
function loadRegistry(): PushEntry[] {
  if (!REGISTRY_FILE) return DEFAULT_REGISTRY;
  let j: unknown;
  try { j = JSON.parse(readFileSync(REGISTRY_FILE, "utf8")); }
  catch (e) { fatal(`--registry 읽기 실패: ${REGISTRY_FILE}: ${e instanceof Error ? e.message : e}`); }
  if (!Array.isArray(j)) fatal(`--registry는 PushEntry 배열이어야 한다: ${REGISTRY_FILE}`);
  for (const e of j as any[]) {
    if (typeof e?.metric !== "string" || typeof e?.producer !== "string") fatal("--registry 항목에 metric·producer 필수");
    const s = e.schedule;
    if (s?.kind === "cron") { if (typeof s.file !== "string") fatal(`--registry ${e.metric}: schedule.cron에 file 필수`); }
    else if (s?.kind === "external") {
      if (typeof s.periodSec !== "number" || typeof s.why !== "string" || !s.why.trim()) {
        fatal(`--registry ${e.metric}: schedule.external은 periodSec + why(근거) 필수 — 무근거 상수 금지`);
      }
    } else fatal(`--registry ${e.metric}: schedule.kind는 cron|external`);
  }
  return j as PushEntry[];
}
const REGISTRY = loadRegistry();
if (!REGISTRY.length) fatal("push 메트릭 레지스트리가 비었다 — 모드 C가 무력화된다(fail-closed)");

const registryMetrics = new Set(REGISTRY.map((e) => e.metric));
const producerViol: string[] = [];
const pushPeriod = new Map<string, number>();   // 메트릭 → push 주기(초)

// 면제 목록은 사유가 있어야 한다(무근거 면제 = 우회 경로).
for (const [p, why] of Object.entries(PRODUCER_EXEMPT)) {
  if (!why.trim()) fatal(`PRODUCER_EXEMPT['${p}']에 사유가 없다 — 무근거 면제 금지`);
}

// (a) 레지스트리 항목 검증: 생산자 실재 + 여전히 VM에 씀 + 그 메트릭을 실제로 발행 + 주기 판별.
for (const e of REGISTRY) {
  const pp = `${ROOT}/${e.producer}`;
  if (!existsSync(pp)) fatal(`레지스트리 생산자 파일 부재: ${e.producer}(${e.metric}) — 경로를 고치거나 항목을 지워라`);
  const text = readFileSync(pp, "utf8");
  if (!producerSignal(text)) fatal(`${e.producer}: 메트릭 push 호출이 사라졌다(${e.metric}) — 레지스트리 항목이 낡았다`);
  if (!extractMetrics(text).includes(e.metric)) {
    producerViol.push(`${e.producer} — 레지스트리 메트릭 '${e.metric}'을 더는 push하지 않는다(이름 변경/삭제? 추출 실패?)`);
  }
  pushPeriod.set(e.metric, e.schedule.kind === "cron"
    ? cronPeriodSec(cronOf(e.schedule.file), e.schedule.file)   // 파일 부재/파싱불가 = FAIL(F-4)
    : e.schedule.periodSec);
}

// (b) 완전성 가드: push하는 표면을 전부 스캔해 **파일 단위 + 메트릭 단위** 등록을 강제(F-3·G-1·G-2).
const found: Candidate[] = collectProducers();
const foundProducers = found.map((x) => x.path);
const registeredProducers = new Set(REGISTRY.map((e) => e.producer));
for (const { path: p, why, viaUrl, metrics } of found) {
  if (!registeredProducers.has(p)) {
    producerViol.push(`${p} — 메트릭을 push하는데(${why}) 레지스트리에 없는 생산자` +
      (metrics.length ? ` (발행 메트릭: ${metrics.join("·")})` : " (페이로드 정적 해석 불가 — 아래 fail-closed 참조)"));
    continue;
  }
  // fail-closed: **VM에 쓰는 게 확실한데**(URL 신호) 무엇을 쓰는지 정적으로 못 읽으면 모드 C가 그 메트릭을
  // 영영 못 본다. (URL 신호 없이 페이로드로만 잡힌 후보는 정의상 추출에 성공한 것이라 이 갈래가 아니다.)
  if (viaUrl && !metrics.length) {
    producerViol.push(`${p} — VM에 쓰지만(${why}) push 페이로드를 **정적으로 해석할 수 없다**(메트릭 이름 추출 0) — ` +
      `fail-closed. 알려진 exposition 형태로 쓰거나(printf 'name val\\n' · VAR="\${VAR}name{…} val\\n") EXPO_INLINE·EXPO_LINE을 넓혀라`);
  }
  for (const m of metrics) {
    if (!registryMetrics.has(m)) {
      producerViol.push(`${p} — push하는 메트릭 '${m}'이 레지스트리에 없음(기존 exporter에 메트릭 추가 = 모드 C 우회 경로)`);
    }
  }
}
for (const p of registeredProducers) {
  if (!foundProducers.includes(p)) {
    producerViol.push(`${p} — 레지스트리 생산자인데 스캔에서 안 잡혔다(추적 안 됨·하네스/charts 제외·push 시그널 미검출 중 하나) — 완전성 가드가 못 본다`);
  }
}

// 모드 C 대상 = 주기가 룩백보다 긴 메트릭만(≤ 룩백이면 항상 시야 안이라 구멍이 안 난다).
const modeCMetrics = REGISTRY.filter((e) => (pushPeriod.get(e.metric) as number) > LOOKBACK).map((e) => e.metric);

// allowlist: `<alert>` 또는 `<file>:<alert>` + 사유 주석(`#`) 필수 — 무근거 면제 차단.
const allowed = new Set<string>();
const allowErrors: string[] = [];
readList(ALLOWLIST).forEach((line, i) => {
  const raw = line.trim();
  if (!raw || raw.startsWith("#")) return;
  const key = raw.split("#", 1)[0].trim();
  if (!raw.includes("#")) { allowErrors.push(`${ALLOWLIST}:${i + 1} '${key}' — 사유 주석(#) 없음`); return; }
  allowed.add(key);
});

// 열거는 공유 워커의 `rules` 스코프가 소유한다(tracked + YAML). MIN_SCAN은 이 린터에 남는다 —
// 워커 바닥값은 없다(열거자는 "글롭이 깨져 0건"과 "정당하게 0건"을 구별할 도메인 지식이 없다).
const ruleEntries = walkManifests("rules", ROOT);

let ruleCount = 0;
const viol: string[] = [];

// expr 1건 검사. name = alert명(또는 record명), rel = 룰 ConfigMap 파일 경로.
function checkExpr(rel: string, name: string, expr: string): void {
  const m = maskStrings(expr);
  const isAllowed = allowed.has(name) || allowed.has(`${rel}:${name}`);

  // ── 모드 A: rollup 인자에 denylist(상태-파생) 메트릭이 있으면 instance 제거 증거를 요구 ──
  const rollupRe = new RegExp(`\\b(${ROLLUP})\\s*\\(`, "g");
  for (let mt = rollupRe.exec(m); mt; mt = rollupRe.exec(m)) {
    const open = mt.index + mt[0].length - 1;
    const close = matchParen(m, open);
    if (close < 0) { viol.push(`${rel} ${name} [모드 A: rollup 괄호 불균형 — 파싱 실패]`); return; }
    const arg = m.slice(open + 1, close);
    const hit = denyMetrics.find((d) => new RegExp(`\\b${d}\\b`).test(arg));
    if (!hit) continue;   // 프로세스-로컬 카운터 = 안전(재시작 시 0 리셋)
    const agg = new RegExp(`\\b(?:${AGG})\\s+(by|without)\\s*\\(([^)]*)\\)`).exec(arg);
    const sub = /\[[^\]]*:[^\]]*\]/.test(arg);   // 집계 위 rollup은 서브쿼리여야 한다
    let bad = "";
    if (!agg) bad = "rollup 이전에 instance를 벗기는 집계(max by/without)가 없음";
    else if (agg[1] === "by" && /\binstance\b/.test(agg[2])) bad = "by(...) 목록에 instance가 남아 있음";
    else if (agg[1] === "without" && !/\binstance\b/.test(agg[2])) bad = "without(...) 목록에 instance가 없음";
    else if (!sub) bad = "집계 위 rollup인데 서브쿼리 [기간:step]가 없음";
    if (bad) {
      if (isAllowed) continue;
      viol.push(`${rel} ${name} [모드 A: ${hit} — ${bad}]`);
    }
  }

  // ── 모드 B: 산술 이항 + on()/ignoring() 인데 피연산자가 raw 셀렉터면 422 위험 ──
  const onRe = /\b(on|ignoring)\s*\(/g;
  for (let mt = onRe.exec(m); mt; mt = onRe.exec(m)) {
    const before = m.slice(0, mt.index);
    if (SET_OP_RE.test(before)) continue;                 // and/or/unless = 422 불가
    const opMatch = BIN_OP_RE.exec(before);
    if (!opMatch) { viol.push(`${rel} ${name} [모드 B: ${mt[1]}() 앞의 연산자를 못 찾음 — 파싱 실패]`); return; }
    if (isAllowed) continue;
    const opPos = before.length - opMatch[0].length;      // 연산자 시작 위치
    const lhs = m.slice(operandStart(m, opPos), opPos);
    const onOpen = mt.index + mt[0].length - 1;
    const onClose = matchParen(m, onOpen);
    if (onClose < 0) { viol.push(`${rel} ${name} [모드 B: ${mt[1]}() 괄호 불균형 — 파싱 실패]`); return; }
    const rhs = m.slice(onClose + 1, operandEnd(m, onClose + 1)).replace(GROUP_MOD_RE, "");
    const bare: string[] = [];
    if (!OPERAND_AGG_RE.test(lhs)) bare.push("좌변");
    if (!OPERAND_AGG_RE.test(rhs)) bare.push("우변");
    if (bare.length) {
      viol.push(`${rel} ${name} [모드 B: ${mt[1]}() 산술 조인의 ${bare.join("·")}이 집계 미포함 raw 셀렉터 — max by(...)로 사전 집계 필요]`);
    }
  }

  // ── 모드 D: `time()`과 빼서 비교하는 시계열은 공급원 의미론이 요구하는 rollup만 쓸 수 있다 ──
  // 열거는 **소비자 표면**에서 뽑는다(생산자가 아니라) — 판별 기준이 "push인가"가 아니라
  // "값이 클러스터 밖에서 왔는가"라서, 생산자 렌즈로 세면 스크레이프 메트릭이 통째로 빠진다.
  // ⚠️ 범위는 **뺄셈·비교의 피연산자 span**뿐이다. expr 전체를 훑으면 `CronJobFlapping` 같은 큰
  //    조인에서 `kube_job_failed`·`kube_job_owner`(타임스탬프가 아닌 조인 피연산자)까지 잡혀
  //    '미등재 = FAIL'이 실 레포를 red로 만든다(실측).
  {
    const { canon: dcanon } = canonicalize(expr);
    const md = maskComments(maskStrings(dcanon));
    const spans: Array<[number, number]> = [];
    const timeRe = /\btime\s*\(\s*\)/g;
    for (let tm = timeRe.exec(md); tm; tm = timeRe.exec(md)) {
      const tStart = tm.index, tEnd = tm.index + tm[0].length;
      // (i) `time() - X` — 뒤쪽 피연산자
      const after = md.slice(tEnd).match(/^\s*-/);
      if (after) {
        const from = tEnd + after[0].length;
        spans.push([from, operandEnd(md, from)]);
      }
      // (ii) `X - time()` — 앞쪽 피연산자(만료 모양)
      const before = md.slice(0, tStart).match(/-\s*$/);
      if (before) {
        const to = tStart - before[0].length;
        spans.push([operandStart(md, to), to]);
      }
      if (!after && !before) continue;
      // (iii) 그 뺄셈을 감싸는 최근접 비교의 **반대편** — r6 우변(예산)이 여기서 잡힌다.
      // ⚠️ `operandEnd`는 산술·비교에서만 멈추고 **집합 연산자(and/or/unless)에서는 안 멈춘다**(모드 B가
      //    그 동작에 의존하므로 공유 헬퍼를 바꾸지 않는다). 여기서 잘라내지 않으면 `… > 100 and on() (X > 0)`
      //    의 X가 비교 반대편으로 딸려 들어와 **무관한 조인 피연산자가 미등재로 잡힌다**(실측).
      const cmp = /[<>]=?|[!=]=/g;
      for (let cm = cmp.exec(md); cm; cm = cmp.exec(md)) {
        if (cm.index <= tStart) continue;
        const from = cm.index + cm[0].length;
        let to = operandEnd(md, from);
        const setOp = /\b(?:and|or|unless)\b/.exec(md.slice(from, to));
        if (setOp) to = from + setOp.index;
        spans.push([from, to]);
        break;
      }
    }
    const seen = new Set<string>();
    for (const [a, b] of spans) {
      const scrub = md.slice(a, b)
        .replace(/\{[^}]*\}/g, "")
        .replace(/\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)/g, "");
      for (const mt of scrub.matchAll(/\b([a-z_][a-z0-9_]{4,})\b(\s*\()?/g)) {
        if (mt[2]) continue;                        // 뒤에 '('가 오면 함수 호출이지 메트릭이 아니다
        if (/^_+$/.test(mt[1])) continue;           // maskStrings 채움문자(밑줄 런) — 라벨 값의 잔해다
        if (PROMQL_BUILTIN.has(mt[1])) continue;
        seen.add(mt[1]);
      }
    }
    for (const metric of [...seen].sort()) {
      const e = supplyOf.get(metric);
      if (!e) {
        if (isAllowed) continue;
        viol.push(`${rel} ${name} [모드 D: ${metric}가 time() 비교에 쓰이는데 ${SUPPLY_POLICY}에 없다 — ` +
          `**기본값은 없다**(기본을 하나로 정하면 반대쪽 클래스가 조용히 열린다). supply(값의 신선도가 ` +
          `클러스터 밖 읽기에 의존하는가)와 decreasing(내려가는 것이 사실일 수 있는가)을 근거와 함께 등재하라]`);
        continue;
      }
      // `X - time()`(만료 모양)이면 부등호 방향이 뒤집혀 요구도 뒤집힌다(max는 fail-open, min이 fail-closed).
      const flipped = new RegExp(`\\b${metric}\\b[\\s\\S]{0,120}?-\\s*time\\s*\\(\\s*\\)`).test(md);
      const want = requiredRollup(e, flipped);
      const re = new RegExp(`\\b${metric}\\b`, "g");
      for (let mt = re.exec(md); mt; mt = re.exec(md)) {
        const owner = ownerFn(md, mt.index);
        const isRollup = !!owner && ROLLUP_OK.has(owner.name);
        supplyRefs++;
        if (isAllowed) continue;
        if (!isRollup) {
          // external+단조는 **흡수가 0인 것 자체가 위반**이다 — 역행 샘플이 그대로 판정에 들어간다.
          if (e.supply === "external" && e.decreasing === "impossible") {
            viol.push(`${rel} ${name} [모드 D: ${metric}(external·단조)가 rollup 밖에서 참조된다 — ` +
              `공급원이 역행 샘플을 주는데 흡수가 0이다. ${want}(...)로 감싸라]`);
          }
          continue;   // 그 외는 rollup 부재가 이 모드의 대상이 아니다(윈도 래치가 없다)
        }
        if (owner!.name === want) continue;
        const why = e.supply === "external" && e.decreasing === "impossible"
          ? `공급원이 역행 샘플을 준다 — ${want}만이 그것을 유계 흡수한다`
          : e.decreasing === "is-truth"
            ? `이 값은 **내려가는 것이 사실**이다 — max 계열은 옛 값을 윈도만큼 부활시켜 새 값이 늦게 먹는다`
            : `값이 클러스터 안에서 생겨 흡수할 잡음이 없다 — max 계열은 이득 0이고 값의 전진 점프만 윈도만큼 래치한다`;
        viol.push(`${rel} ${name} [모드 D: ${metric}가 ${owner!.name}()에 감싸였으나 ${want}()여야 한다 — ${why}. ` +
          `판별 기준과 근거는 ${SUPPLY_POLICY}]`);
      }
    }
  }

  // ── 모드 C: push 주기 > 룩백인 메트릭은 윈도 ≥ 주기인 **연속성 보존 rollup** 안에서만 참조 가능 ──
  // 정규화(F-1) → 문자열/주석 마스킹 순서. 마스킹을 먼저 하면 `{__name__="m"}`의 이름이 지워진다.
  const { canon, nameMatchers } = canonicalize(expr);
  const mc = maskComments(maskStrings(canon));

  // 이름 매처가 정규식/부정이면 어떤 push 메트릭을 집을지 정적으로 못 정한다 → fail-closed(F-1).
  if (!isAllowed) {
    for (const nm of nameMatchers) {
      let hits: string[];
      if (nm.op === "=~") {
        let re: RegExp | null = null;
        try { re = new RegExp(`^(?:${nm.pat})$`); } catch { re = null; }
        hits = re ? modeCMetrics.filter((x) => re.test(x)) : modeCMetrics;   // 정규식 파싱 실패 = 전부 매치 취급
      } else {
        hits = modeCMetrics;   // `!=`·`!~`는 "그 외 전부" → push 메트릭을 포함할 수 있다
      }
      if (hits.length) {
        viol.push(`${rel} ${name} [모드 C: __name__${nm.op}"${nm.pat}" 형태는 push 메트릭(${hits.join("·")})을 ` +
          `매치할 수 있는데 rollup 착용 여부를 정적으로 판정할 수 없다 — fail-closed. 메트릭명을 직접 쓰고 ` +
          `last_over_time으로 감싸거나, 정당하면 ${ALLOWLIST}에 사유와 함께 등재]`);
      }
    }
  }

  for (const metric of modeCMetrics) {
    const period = pushPeriod.get(metric) as number;
    const why = `push 주기 ${period}s > vmalert instant 룩백 ${LOOKBACK}s → 매 주기 시리즈에 구멍 → ` +
      `for: pending이 매 주기 리셋 → **어떤 조건에도 발화 불가**`;
    // ⚠️ 처방이 **공급원을 알아야 한다** — 모드 C가 무조건 `last_over_time`을 지시하면, external·단조
    //    메트릭(공급원이 역행 샘플을 준다)에 대해 그대로 따랐을 때 **모드 D가 red를 낸다**. 두 모드가
    //    서로 모순되는 지시를 내리면 사람은 게이트를 믿지 않게 된다. 정책 파일이 답을 갖고 있으니 읽는다.
    const sp = supplyOf.get(metric);
    const wantFn = sp ? requiredRollup(sp, false) : "last_over_time";
    const fix = `${wantFn}(${metric}[≥${fmtSec(period)}])로 감싸라 (전문: docs/traps-detail.md)`;
    const re = new RegExp(`\\b${metric}\\b`, "g");
    for (let mt = re.exec(mc); mt; mt = re.exec(mc)) {
      if (isAllowed) continue;
      const owner = ownerFn(mc, mt.index);
      // F-2: 아무 `[W]`나 인정하지 않는다 — 단일 샘플로도 값을 내는 rollup(ROLLUP_OK)이 소유해야 한다.
      if (!owner || !ROLLUP_OK.has(owner.name)) {
        const who = owner ? `${owner.name}()가 감싸고 있음` : "감싸는 함수 없음(맨 참조)";
        viol.push(`${rel} ${name} [모드 C: ${metric}가 연속성 보존 rollup(*_over_time) 밖 — ${who}. ${why}. ` +
          `irate/idelta/rate/increase/delta/deriv는 윈도 안 2샘플 이상을 요구해 push 메트릭엔 무력하다(가짜 픽스). ${fix}]`);
        continue;
      }
      const w = rollupWindow(mc, mt.index, metric.length, owner);
      if (w === null) {
        viol.push(`${rel} ${name} [모드 C: ${metric}가 ${owner.name}() 안에 있으나 range 윈도 [W]가 없다 — ${fix}]`);
        continue;
      }
      const wsec = durationSec(w);
      if (wsec === null) {
        viol.push(`${rel} ${name} [모드 C: ${metric}의 rollup 윈도 '${w}' 파싱 실패 — 기간 리터럴(예: 15m·3d)이어야 한다]`);
        continue;
      }
      if (wsec < period) {
        viol.push(`${rel} ${name} [모드 C: ${metric}의 rollup 윈도 ${w}(${wsec}s) < push 주기 ${period}s — ` +
          `주기 사이 구멍이 남아 for: pending이 리셋된다. 윈도를 ≥ ${fmtSec(period)}로 넓혀라 (전문: docs/traps-detail.md)]`);
      }
    }
  }
}

for (const { path: rel, text, docs } of ruleEntries) {
  for (const doc of docs) {
    if (doc.errors.length) { console.error(`FAIL: YAML 파싱 실패: ${rel}: ${doc.errors[0].message}`); process.exit(1); }
    const o = doc.toJS() as any;
    if (!o || o.kind !== "ConfigMap" || !o.data) continue;
    for (const [key, body] of Object.entries(o.data as Record<string, string>)) {
      if (!key.endsWith(".yaml") || typeof body !== "string") continue;
      let inner: any;
      try { inner = parse(body); }
      catch (e) { console.error(`FAIL: 룰 본문 파싱 실패: ${rel} .data["${key}"]: ${e instanceof Error ? e.message : e}`); process.exit(1); }
      for (const g of inner?.groups ?? []) {
        for (const r of g?.rules ?? []) {
          const name = r?.alert ?? r?.record;
          if (!name || typeof r?.expr !== "string") continue;
          ruleCount++;
          checkExpr(rel, name, r.expr);
        }
      }
    }
  }
}

// scan-floor: 룰 추출이 붕괴하면 아무것도 검사 안 하고 GREEN — fail-loud. 바닥값 판정은
// SCAN 방출보다 **앞**이어야 한다: 열거 붕괴 실행이 마커를 내고 죽으면 실행 관측이 그 실행을
// "정상 실행됨"으로 오독한다(scripts/lib/scan-floor.sh 규약 — SCAN 면제는 바닥값 실패 경로뿐).
if (ruleCount < MIN_SCAN) {
  console.error(`FAIL: 스캔 룰 ${ruleCount}건 < ${MIN_SCAN} — 룰 추출 회귀 의심(${RULES_DIR} 재배치 또는 ConfigMap .data 키 변경?)`);
  process.exit(1);
}
if (!SUPPLY_INJECTED) {
  if (SUPPLY.length < MIN_SUPPLY) {
    console.error(`FAIL: ${SUPPLY_POLICY} 항목 ${SUPPLY.length}건 < ${MIN_SUPPLY} — 큐레이션이 사라졌다(0건 검사 후 초록이 되는 자리)`);
    process.exit(1);
  }
  if (supplyRefs < MIN_SUPPLY_REFS) {
    console.error(`FAIL: 모드 D가 판정한 참조 ${supplyRefs}건 < ${MIN_SUPPLY_REFS} — 원장은 그대로인데 **강제 루프가 죽었다**(열거 범위 회귀 의심)`);
    process.exit(1);
  }
}
// SCAN 신호(scripts/lib/scan-floor.sh 규약) — 실행 관측용 균일 마커. 바닥값 판정 **뒤**,
// 위반 검사 **앞**이다: 도메인을 평가한 실행은 위반 여부와 무관하게 신호를 낸다.
// 라벨 = 바닥값이 걸린 열거 도메인 하나 — 여긴 룰(MIN_SCAN)과 denylist(MIN_DENY) 둘이다.
console.log(`SCAN: check-alert-rules:rules: ${ruleCount}`);
console.log(`SCAN: check-alert-rules:denylist: ${denyMetrics.length}`);
// 모드 D는 **두 축**의 신호를 낸다. 원장 크기(supply)는 큐레이션이 사라지는 것을 잡고,
// 판정 참조 수(supply-refs)는 **강제 루프가 조용히 죽는 것**을 잡는다 — 전자만 있으면
// 열거가 0건이 돼도 원장은 그대로라 초록이 된다(이 레포가 반복해 밟은 그 비대칭).
console.log(`SCAN: check-alert-rules:supply: ${SUPPLY.length}`);
console.log(`SCAN: check-alert-rules:supply-refs: ${supplyRefs}`);
if (allowErrors.length) {
  console.log(`FAIL: ${ALLOWLIST} 항목에 사유 주석이 없다 — 무근거 면제는 금지:`);
  for (const e of allowErrors) console.log("  " + e);
  process.exit(1);
}
// 완전성 가드: 미등록 생산자/메트릭은 모드 C를 **조용히 통과**한다(fail-open) → 여기서 막는다.
if (producerViol.length) {
  console.log("FAIL: push 메트릭 레지스트리 완전성 위반 — 미등록 메트릭은 모드 C 검사를 빠져나가 죽은 알림으로 " +
    "배포된다. tools/check-alert-rules.ts의 DEFAULT_REGISTRY에 메트릭·생산자·스케줄을 등재하라:");
  for (const p of producerViol) console.log("  " + p);
  process.exit(1);
}
if (viol.length) {
  console.log("FAIL: vmalert 룰 expr 안티패턴(모드 A/B=instance 라벨 불안정 · 모드 C=push 주기 > 룩백 · 모드 D=공급원 의미론↔rollup 함수 불일치) — " +
    "수정하거나 " + ALLOWLIST + "에 사유와 함께 등재:");
  for (const v of viol) console.log("  " + v);
  process.exit(1);
}
console.log(`check-alert-rules OK (${ruleCount} 룰 스캔, push 생산자 ${foundProducers.length}건 / 등록 메트릭 ` +
  `${REGISTRY.length}건[모드 C 대상 ${modeCMetrics.length}], 룩백 ${LOOKBACK}s, ` +
  `공급원 원장 ${SUPPLY.length}건/판정 ${supplyRefs}참조, 모드 A/B/C/D 위반 0)`);
