// 결과 계약 스키마 생성기 — tools/cli-result-schema.json 전체가 이 파일과 기술자 행
// (lib/catalog-rows.ts CONTRACT_ROWS)의 산출물이다(cli-deepening 심화 3). 행렬 분기(allOf
// member 0)와 verb enum은 행에서 생성되고, x-contract·variant→exitCode 재진술(의도된 이중부기)·
// definitions 본문은 아래 수제 조각이다 — 컴팩트 스타일은 과거 리뷰의 의도적 결정이라 보존한다.
// import는 기술자(catalog-rows·platform 좌표 SSOT)와 node 표준뿐이다: 계약 독자(contract.ts)도 생성물
// JSON도 참조하지 않으므로 생성물이 없거나 파손돼도 재생성이 성립한다(설계 게이트 r1 D3 —
// test_result-schema-gen.bats 증명). initSuccess·initFailure의 archetype enum은 platform.ts ARCHETYPES
// 파생이다(cli-deepening 심화 6 후속 — 리터럴 사본이면 아키타입 확장 시 입력 표면(MCP)은 수용하는데
// 결과 계약만 낡는다).
// 사용: 기본 --check(대상과 byte 대조, 드리프트면 exit 1) | --write(대상에 기록).
//       --out <path>로 대상 지정(기본: 이 파일 옆 cli-result-schema.json).
// 강제 지점 둘: 게이트는 test_result-schema-gen.bats(run-bats 수집 — required check), make verify의
// --check 라인은 로컬 보조다(verify는 CI에서 안 돈다 — check-guard-authority.ts 헤더). 파일명이
// 가드 열거 규약(check-*) 밖인 것은 의도다 — 생성기 겸 게이트라 check- 접두가 거짓이 된다.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { CONTRACT_ROWS, LANES, type MutationVariantName } from "./lib/catalog-rows.ts";
import { ARCHETYPES } from "./lib/platform.ts";

const HEADER_A = `{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "cli-result-schema",
  "title": "homelab CLI --json 결과 계약 v1 (SSOT — 전 동사·MCP tool 공용)",
  "description": "homelab CLI 전 동사의 --json 출력과 MCP tool 결과가 공유하는 결과 오브젝트 계약. 이 파일이 산문 아닌 SSOT다: variant 어휘·종료코드 매핑·stdout 순수성·MCP 매핑을 여기서 정의하고, CLI는 x-contract를 런타임에 읽어 그대로 따른다(코드 상수로 복제하지 않는다). 이후 티켓은 verb enum과 variant·definitions에 항목을 추가할 뿐 기존 필드를 깨지 않는다(v1 내 추가 = 하위호환). '라이브 구간 생략'은 variant가 아니라 직교 축 omitted[]로 모델링한다 — 생략은 success·pending 어느 variant와도 결합 가능해서 variant로 두면 조합이 폭발하고, 빈 배열을 필수로 두어 '생략 없음'이 필드 부재가 아니라 명시 값으로 남는다(생략과 성공의 구분).",
  "x-contract": {
    "envelope": "homelab-cli/1",
    "exitCodes": {
      "success": 0,
      "failure": 1,
      "race": 3,
      "skip": 4,
      "pending": 1,
      "no-op": 0,
      "superseded": 3
    },
    "usageExit": 2,
    "exitRationale": "기존 도구 규약(tools/lib/cli.ts 주석이 산문 SSOT: 0=성공·1=검증/게이트 실패·2=사용법·3=race·4=skip)에 CLI variant를 매핑한다. no-op=0: 멱등 수렴은 성공의 아종. pending=1: '확인하지 못함'이 0이면 && 체인에 vacuous green이다 — 대기 매트릭스가 배포 오판을 막으려고 존재하는데 종료코드가 거짓말하면 무의미하다(스크립트는 exit로, 에이전트는 variant로 분기). superseded=3: 표면이 이미 다른 값 = 전제 상태 변동(race 계열, variant가 둘을 구분). skip=4: stderr에 'SKIP: homelab <verb>: <이유>' 마커를 같은 실행에서 함께 낸다(가드 skip 신호 규약).",
    "stdout": "--json이면 stdout은 이 스키마의 오브젝트 정확히 하나(개행 종단)뿐이다. 사람용 텍스트·진행 표시는 전부 stderr. 예외 둘: usage 오류(exit 2)는 오브젝트를 내지 않는다(플래그 해석이 실패한 상태라 --json 여부 자체를 신뢰할 수 없다). --help는 --json보다 우선한다 — 사용법 질의는 동사 실행 결과가 아니므로 사용법 텍스트가 stdout(exit 0)이고 오브젝트는 없다(GNU 관례).",
    "mcp": {
      "isErrorVariants": ["failure", "race", "superseded"],
      "normalVariants": ["success", "no-op", "skip", "pending"],
      "note": "MCP tool 결과 content = 같은 결과 오브젝트 한 벌(계약 한 벌). pending은 MCP에서 에러가 아니다 — tool 호출은 동기·바운디드이고 재호출(status 핸들 조회·같은 입력 init 재실행)이 재개 경로다. usage 오류는 JSON-RPC invalid params(-32602)로 매핑한다."
    }
  },
  "type": "object",
  "additionalProperties": false,
  "required": ["schema", "verb", "variant", "exitCode", "omitted", "result"],
  "properties": {
    "schema": { "enum": ["homelab-cli/1"] },`;

const HEADER_B = `    "variant": { "enum": ["success", "failure", "race", "skip", "pending", "no-op", "superseded"] },
    "exitCode": { "enum": [0, 1, 3, 4] },
    "omitted": { "type": "array", "uniqueItems": true, "items": { "enum": ["live"] } },
    "result": { "type": "object" }
  },
  "allOf": [
    {
      "description": "verb→(허용 variant 집합, result) 결합(structure r1 a1·b1 + 시도2 A2·B2): verb별로 낼 수 있는 variant와 result 정의를 루트에 강제 — 어긋난 shape·불가능한 verb/variant 쌍은 스키마 차원에서 red. 변이 동사(db/cache create)는 variant 단위 분기이고 공유 mutation* 정의에 allOf로 verb별 action을 고정한다(verb↔action 교차 배선 차단). 동사 추가 = 분기 추가.",
      "oneOf": [`;

const TAIL_MID = `      ]
    },
    {
      "description": "variant→exitCode 결합(structure r1 b2): 허용 쌍 밖(success+1 등)은 red. 이 분기들은 x-contract.exitCodes의 재진술이며, 둘의 일치는 test_homelab-cli.bats의 SSOT pinning 테스트가 강제한다.",
      "oneOf": [
        { "type": "object", "properties": { "variant": { "enum": ["success", "no-op"] }, "exitCode": { "enum": [0] } } },
        { "type": "object", "properties": { "variant": { "enum": ["failure", "pending"] }, "exitCode": { "enum": [1] } } },
        { "type": "object", "properties": { "variant": { "enum": ["race", "superseded"] }, "exitCode": { "enum": [3] } } },
        { "type": "object", "properties": { "variant": { "enum": ["skip"] }, "exitCode": { "enum": [4] } } }
      ]
    }
  ],
  "definitions": {`;

// archetype enum 인라인 — verb enum과 같은 표기(`"a", "b"`)로 생성물 byte를 보존한다.
const ARCHETYPE_ENUM = ARCHETYPES.map((a) => '"' + a + '"').join(", ");
const DEFINITIONS = `    "doctorResult": {
      "type": "object",
      "additionalProperties": false,
      "required": ["checks", "summary"],
      "properties": {
        "checks": {
          "type": "array",
          "minItems": 9,
          "items": { "$ref": "#/definitions/doctorCheck" }
        },
        "summary": {
          "type": "object",
          "additionalProperties": false,
          "required": ["pass", "fail", "warn"],
          "properties": {
            "pass": { "type": "integer", "minimum": 0 },
            "fail": { "type": "integer", "minimum": 0 },
            "warn": { "type": "integer", "minimum": 0 }
          }
        }
      }
    },
    "mutationRun": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "url"],
      "properties": {
        "id": { "type": "integer", "minimum": 1 },
        "url": { "type": "string", "minLength": 1 },
        "conclusion": { "type": "string" },
        "failedJobs": { "type": "array", "items": { "type": "string" } }
      }
    },
    "mutationPr": {
      "type": "object",
      "additionalProperties": false,
      "required": ["number", "url", "merged"],
      "properties": {
        "number": { "type": "integer", "minimum": 1 },
        "url": { "type": "string", "minLength": 1 },
        "merged": { "type": "boolean" },
        "mergeSha": { "type": "string" }
      }
    },
    "mutationApp": {
      "description": "--wait 수렴 관측 증거 — 후손·표면 판정 포함(health 단독 판정 금지). error는 그 사이클의 조회 실패.",
      "type": "object",
      "additionalProperties": false,
      "required": ["name"],
      "properties": {
        "name": { "type": "string", "minLength": 1 },
        "sync": { "type": "string" },
        "health": { "type": "string" },
        "revision": { "type": "string" },
        "descendant": { "type": "boolean" },
        "surfaceOk": { "type": "boolean" },
        "error": { "type": "string" }
      }
    },
    "mutationChain": {
      "description": "app secrets 이중 모드 증거 — chain(앱 레포 안 연쇄: seal→커밋→push→도달성) / dispatch-only(밖).",
      "type": "object",
      "additionalProperties": false,
      "required": ["mode"],
      "properties": {
        "mode": { "enum": ["chain", "dispatch-only"] },
        "sealedPath": { "type": "string" },
        "pushed": { "type": "boolean" },
        "headSha": { "type": "string" },
        "sealSkipped": { "type": "boolean" }
      }
    },
    "mutationRefused": {
      "description": "디스패치 전 거부(app secrets 선행 조건 실패) — correlation이 없고(nonce 미생성) 연쇄 증거(chain)가 실린다. app secrets failure 분기 전용.",
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "error", "chain"],
      "properties": {
        "action": { "enum": ["update-secrets"] },
        "name": { "type": "string", "minLength": 1 },
        "error": { "type": "string", "minLength": 1 },
        "chain": { "$ref": "#/definitions/mutationChain" }
      }
    },
    "mutationNoop": {
      "description": "정당한 no-op(동일 봉인본 — PR·머지 SHA 없음). --wait 검증은 main 기준 표면 동치(applications 증거).",
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "correlation", "waited", "run"],
      "properties": {
        "action": { "enum": ["create-database", "create-cache", "create-app", "update-secrets"] },
        "name": { "type": "string", "minLength": 1 },
        "correlation": { "type": "string", "minLength": 8 },
        "waited": { "type": "boolean" },
        "run": { "$ref": "#/definitions/mutationRun" },
        "applications": { "type": "array", "items": { "$ref": "#/definitions/mutationApp" } },
        "chain": { "$ref": "#/definitions/mutationChain" }
      }
    },
    "mutationSuccess": {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "correlation", "waited", "run", "pr"],
      "properties": {
        "chain": { "$ref": "#/definitions/mutationChain" },
        "action": { "enum": ["create-database", "create-cache", "create-app", "update-secrets"] },
        "name": { "type": "string", "minLength": 1 },
        "correlation": { "type": "string", "minLength": 8 },
        "waited": { "type": "boolean" },
        "run": { "$ref": "#/definitions/mutationRun" },
        "pr": { "$ref": "#/definitions/mutationPr" },
        "applications": { "type": "array", "items": { "$ref": "#/definitions/mutationApp" } }
      }
    },
    "mutationFailure": {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "correlation", "error"],
      "properties": {
        "chain": { "$ref": "#/definitions/mutationChain" },
        "action": { "enum": ["create-database", "create-cache", "create-app", "update-secrets"] },
        "name": { "type": "string", "minLength": 1 },
        "correlation": { "type": "string", "minLength": 8 },
        "error": { "type": "string", "minLength": 1 },
        "run": { "$ref": "#/definitions/mutationRun" },
        "pr": { "$ref": "#/definitions/mutationPr" }
      }
    },
    "mutationRace": {
      "description": "신원 판정 불가(같은 nonce의 run ≥2 또는 브랜치 PR ≥2) — 전제 상태 변동 계열(exit 3).",
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "correlation", "error", "observedRuns"],
      "properties": {
        "chain": { "$ref": "#/definitions/mutationChain" },
        "action": { "enum": ["create-database", "create-cache", "create-app", "update-secrets"] },
        "name": { "type": "string", "minLength": 1 },
        "correlation": { "type": "string", "minLength": 8 },
        "error": { "type": "string", "minLength": 1 },
        "observedRuns": { "type": "integer", "minimum": 0 },
        "run": { "$ref": "#/definitions/mutationRun" }
      }
    },
    "mutationPending": {
      "description": "바운디드 부분 결과 — 도달 지점(run/pr/applications)이 증거로 실리고 핸들 재조회가 재개 경로다.",
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "correlation", "pendingReason"],
      "properties": {
        "chain": { "$ref": "#/definitions/mutationChain" },
        "action": { "enum": ["create-database", "create-cache", "create-app", "update-secrets"] },
        "name": { "type": "string", "minLength": 1 },
        "correlation": { "type": "string", "minLength": 8 },
        "pendingReason": { "type": "string", "minLength": 1 },
        "run": { "$ref": "#/definitions/mutationRun" },
        "pr": { "$ref": "#/definitions/mutationPr" },
        "applications": { "type": "array", "items": { "$ref": "#/definitions/mutationApp" } }
      }
    },
    "mutationSuperseded": {
      "description": "관측 후손 리비전에서 desired-state 표면 부재 — 요청이 추월됨(성공 아님, exit 3).",
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "correlation", "error", "pr", "applications"],
      "properties": {
        "chain": { "$ref": "#/definitions/mutationChain" },
        "action": { "enum": ["create-database", "create-cache", "create-app", "update-secrets"] },
        "name": { "type": "string", "minLength": 1 },
        "correlation": { "type": "string", "minLength": 8 },
        "error": { "type": "string", "minLength": 1 },
        "run": { "$ref": "#/definitions/mutationRun" },
        "pr": { "$ref": "#/definitions/mutationPr" },
        "applications": { "type": "array", "items": { "$ref": "#/definitions/mutationApp" } }
      }
    },
    "mutationAbsentApp": {
      "description": "absence 수렴 관측(teardown) — Application의 존재/부재. present=false=prune 완료, true=진행 중, error=미확정(그 사이클 조회 실패). sync/health를 종결 근거로 쓰지 않는다 — 삭제 대상은 Healthy가 될 수 없다.",
      "type": "object",
      "additionalProperties": false,
      "required": ["name"],
      "properties": {
        "name": { "type": "string", "minLength": 1 },
        "present": { "type": "boolean" },
        "error": { "type": "string" }
      }
    },
    "teardownSuccess": {
      "description": "철거 성공 — 머지 관측 + Application 부재(prune 완료). KUBECONFIG 부재면 applications 생략(omitted=live). dnsReclaim은 DNS 회수가 이 명령의 관측 대상이 아님을 명시(iac/tf-reconcile 소관).",
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "correlation", "waited", "run", "pr", "dnsReclaim"],
      "properties": {
        "action": { "enum": ["teardown-app"] },
        "name": { "type": "string", "minLength": 1 },
        "correlation": { "type": "string", "minLength": 8 },
        "waited": { "type": "boolean" },
        "run": { "$ref": "#/definitions/mutationRun" },
        "pr": { "$ref": "#/definitions/mutationPr" },
        "dnsReclaim": { "enum": ["iac/tf-reconcile"] },
        "applications": { "type": "array", "items": { "$ref": "#/definitions/mutationAbsentApp" } }
      }
    },
    "teardownFailure": {
      "description": "철거 실패 — 디스패치/run 실패 또는 머지 SHA에 표면이 남음(철거 미반영). presence 동사와 달리 표면 잔존이 실패 신호다(극성 반전).",
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "correlation", "error", "dnsReclaim"],
      "properties": {
        "action": { "enum": ["teardown-app"] },
        "name": { "type": "string", "minLength": 1 },
        "correlation": { "type": "string", "minLength": 8 },
        "error": { "type": "string", "minLength": 1 },
        "dnsReclaim": { "enum": ["iac/tf-reconcile"] },
        "run": { "$ref": "#/definitions/mutationRun" },
        "pr": { "$ref": "#/definitions/mutationPr" }
      }
    },
    "teardownRace": {
      "description": "신원 판정 불가(같은 nonce run ≥2 또는 브랜치 PR ≥2) — 전제 상태 변동 계열(exit 3).",
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "correlation", "error", "observedRuns", "dnsReclaim"],
      "properties": {
        "action": { "enum": ["teardown-app"] },
        "name": { "type": "string", "minLength": 1 },
        "correlation": { "type": "string", "minLength": 8 },
        "error": { "type": "string", "minLength": 1 },
        "observedRuns": { "type": "integer", "minimum": 0 },
        "dnsReclaim": { "enum": ["iac/tf-reconcile"] },
        "run": { "$ref": "#/definitions/mutationRun" }
      }
    },
    "teardownPending": {
      "description": "바운디드 부분 결과 — 사람 머지 대기(파괴 승인) 또는 Application prune 미완. applications는 부재 관측 증거이고 핸들 재조회가 재개 경로다.",
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "correlation", "pendingReason", "dnsReclaim"],
      "properties": {
        "action": { "enum": ["teardown-app"] },
        "name": { "type": "string", "minLength": 1 },
        "correlation": { "type": "string", "minLength": 8 },
        "pendingReason": { "type": "string", "minLength": 1 },
        "dnsReclaim": { "enum": ["iac/tf-reconcile"] },
        "run": { "$ref": "#/definitions/mutationRun" },
        "pr": { "$ref": "#/definitions/mutationPr" },
        "applications": { "type": "array", "items": { "$ref": "#/definitions/mutationAbsentApp" } }
      }
    },
    "initSecrets": {
      "description": "디스패치 시크릿 쌍 상태(--dispatch-secrets 요청 시) — App ID·private key 각각 설정 여부. 절반 상태(하나만 true)는 알려진 무효 구성이고 재실행이 나머지를 수렴시킨다.",
      "type": "object",
      "additionalProperties": false,
      "required": ["requested", "appId", "privateKey"],
      "properties": {
        "requested": { "type": "boolean" },
        "appId": { "type": "boolean" },
        "privateKey": { "type": "boolean" }
      }
    },
    "initSuccess": {
      "description": "init 성공 또는 no-op — 스캐폴드+push 완료(+요청 시 시크릿 쌍). success=이번 실행이 최소 한 단계 수행, no-op=이미 완료라 변경 없음(멱등 재실행). correlation 없음(변이 디스패처가 아닌 로컬 체인).",
      "type": "object",
      "additionalProperties": false,
      "required": ["app", "archetype", "public", "repo", "scaffolded", "pushed"],
      "properties": {
        "app": { "type": "string", "minLength": 1 },
        "archetype": { "enum": [${ARCHETYPE_ENUM}] },
        "public": { "type": "boolean" },
        "repo": { "type": "string", "minLength": 1 },
        "existed": { "type": "boolean" },
        "created": { "type": "boolean" },
        "adopted": { "type": "boolean" },
        "scaffolded": { "type": "boolean" },
        "pushed": { "type": "boolean" },
        "checkpoint": { "enum": ["pushed", "secrets"] },
        "secrets": { "$ref": "#/definitions/initSecrets" }
      }
    },
    "initFailure": {
      "description": "init 실패 — preflight 거부(부수효과 0)·마커 없는 레포 fail-closed·단계 오류. checkpoint가 도달 지점을 명시하고(재개 근거), 시크릿 절반 상태도 여기 실린다.",
      "type": "object",
      "additionalProperties": false,
      "required": ["app", "archetype", "public", "repo", "checkpoint", "error"],
      "properties": {
        "app": { "type": "string", "minLength": 1 },
        "archetype": { "enum": [${ARCHETYPE_ENUM}] },
        "public": { "type": "boolean" },
        "repo": { "type": "string", "minLength": 1 },
        "existed": { "type": "boolean" },
        "created": { "type": "boolean" },
        "adopted": { "type": "boolean" },
        "scaffolded": { "type": "boolean" },
        "pushed": { "type": "boolean" },
        "checkpoint": { "enum": ["preflight", "created", "cloned", "scaffolded", "pushed", "secrets"] },
        "error": { "type": "string", "minLength": 1 },
        "secrets": { "$ref": "#/definitions/initSecrets" }
      }
    },
    "urlResult": {
      "description": "db url/cache url 결과 — conn URL 엔진(lib/conn-url.ts)의 계획/수행 보고(CLI --json·MCP 공용). 평문 자격은 담지 않는다(비출력 계약): 계획은 엔진의 타입 결과(UrlResult ↔ 이 정의 1:1)이고 실제 기록은 wrote 불리언으로만 표기한다. dryRun=계획만(wrote=false). failure는 error를 담는다.",
      "type": "object",
      "additionalProperties": false,
      "required": ["name", "dryRun"],
      "properties": {
        "name": { "type": "string", "minLength": 1 },
        "mode": { "type": "string" },
        "secretRef": { "type": "string" },
        "envKey": { "type": "string" },
        "envFile": { "type": "string" },
        "note": { "type": "string" },
        "dryRun": { "type": "boolean" },
        "wrote": { "type": "boolean" },
        "error": { "type": "string" }
      }
    },
    "statusResult": {
      "description": "status의 result — 모드(list/app/run/pr) 판별 union + 오류 branch(variant=failure일 때 mode+error). 생략(live)은 result가 아니라 envelope.omitted가 명시한다.",
      "oneOf": [
        { "$ref": "#/definitions/statusList" },
        { "$ref": "#/definitions/statusApp" },
        { "$ref": "#/definitions/statusRun" },
        { "$ref": "#/definitions/statusPrHandle" },
        { "$ref": "#/definitions/statusError" }
      ]
    },
    "statusList": {
      "type": "object",
      "additionalProperties": false,
      "required": ["mode", "apps", "count"],
      "properties": {
        "mode": { "enum": ["list"] },
        "apps": { "type": "array", "items": { "$ref": "#/definitions/statusAppRow" } },
        "count": { "type": "integer", "minimum": 0 }
      }
    },
    "statusAppRow": {
      "description": "값 없음 = 키 부재(스키마는 JSON null을 두지 않는다 — 파일/키 부재의 의미 부여는 소비자).",
      "type": "object",
      "additionalProperties": false,
      "required": ["name"],
      "properties": {
        "name": { "type": "string", "minLength": 1 },
        "tag": { "type": "string" },
        "digest": { "type": "string" },
        "autoDeploy": { "type": "boolean" },
        "sourceRepo": { "type": "string" },
        "ledgerMi": { "type": "integer", "minimum": 0 }
      }
    },
    "statusApp": {
      "type": "object",
      "additionalProperties": false,
      "required": ["mode", "app", "runs", "openPrs"],
      "properties": {
        "mode": { "enum": ["app"] },
        "app": { "$ref": "#/definitions/statusAppRow" },
        "runs": { "type": "array", "items": { "$ref": "#/definitions/statusRunRow" } },
        "openPrs": { "type": "array", "items": { "$ref": "#/definitions/statusOpenPrRow" } },
        "live": {
          "description": "라이브 계층 — 부재는 envelope.omitted=[\\"live\\"](생략), error는 조회 실패의 관측 보고(선택 계층이라 variant는 success 유지).",
          "oneOf": [
            {
              "type": "object",
              "additionalProperties": false,
              "required": ["argocd"],
              "properties": {
                "argocd": {
                  "type": "object",
                  "additionalProperties": false,
                  "required": ["sync", "health"],
                  "properties": {
                    "sync": { "type": "string", "minLength": 1 },
                    "health": { "type": "string", "minLength": 1 },
                    "revision": { "type": "string" }
                  }
                }
              }
            },
            {
              "type": "object",
              "additionalProperties": false,
              "required": ["error"],
              "properties": { "error": { "type": "string", "minLength": 1 } }
            }
          ]
        }
      }
    },
    "statusRunRow": {
      "type": "object",
      "additionalProperties": false,
      "required": ["status", "url"],
      "properties": {
        "name": { "type": "string" },
        "status": { "type": "string", "minLength": 1 },
        "conclusion": { "type": "string" },
        "headSha": { "type": "string" },
        "url": { "type": "string" }
      }
    },
    "statusOpenPrRow": {
      "type": "object",
      "additionalProperties": false,
      "required": ["number", "head", "url", "autoMerge"],
      "properties": {
        "number": { "type": "integer", "minimum": 1 },
        "title": { "type": "string" },
        "head": { "type": "string", "minLength": 1 },
        "url": { "type": "string" },
        "autoMerge": { "type": "boolean" }
      }
    },
    "statusRun": {
      "type": "object",
      "additionalProperties": false,
      "required": ["mode", "run"],
      "properties": {
        "mode": { "enum": ["run"] },
        "run": { "$ref": "#/definitions/statusRunRow" }
      }
    },
    "statusPrHandle": {
      "type": "object",
      "additionalProperties": false,
      "required": ["mode", "pr"],
      "properties": {
        "mode": { "enum": ["pr"] },
        "pr": {
          "type": "object",
          "additionalProperties": false,
          "required": ["number", "state", "merged", "autoMerge", "url"],
          "properties": {
            "number": { "type": "integer", "minimum": 1 },
            "state": { "type": "string", "minLength": 1 },
            "merged": { "type": "boolean" },
            "autoMerge": { "type": "boolean" },
            "title": { "type": "string" },
            "headRef": { "type": "string" },
            "headSha": { "type": "string" },
            "mergeCommitSha": { "type": "string" },
            "url": { "type": "string" }
          }
        }
      }
    },
    "statusError": {
      "type": "object",
      "additionalProperties": false,
      "required": ["mode", "error"],
      "properties": {
        "mode": { "enum": ["list", "app", "run", "pr"] },
        "error": { "type": "string", "minLength": 1 }
      }
    },
    "doctorCheck": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "status", "detail"],
      "properties": {
        "id": {
          "enum": [
            "gh-auth",
            "gh-owner",
            "gh-scopes",
            "bun",
            "kubeseal",
            "kubeconfig",
            "template-access",
            "template-scaffold-contract",
            "template-targetarch"
          ]
        },
        "status": { "enum": ["pass", "fail", "warn"] },
        "detail": { "type": "string", "minLength": 1 }
      }
    }
  }
}`;

const DEF_BY_VARIANT: Record<MutationVariantName, string> = {
  success: "mutationSuccess",
  failure: "mutationFailure",
  race: "mutationRace",
  pending: "mutationPending",
  superseded: "mutationSuperseded",
  "no-op": "mutationNoop",
};

// 행렬 분기 3형 — 형식(들여쓰기·인라인 스타일)이 곧 byte 계약이라 문자열 조립로만 만든다.
function mutationBranch(verb: string, variant: MutationVariantName, action: string, chain: boolean): string {
  const chainLine = chain
    ? '              { "type": "object", "required": ["chain"] }'
    : '              { "not": { "type": "object", "required": ["chain"] } }';
  return [
    "        {",
    '          "type": "object",',
    '          "properties": {',
    '            "verb": { "enum": ["' + verb + '"] },',
    '            "variant": { "enum": ["' + variant + '"] },',
    '            "result": { "allOf": [',
    '              { "$ref": "#/definitions/' + DEF_BY_VARIANT[variant] + '" },',
    '              { "type": "object", "properties": { "action": { "enum": ["' + action + '"] } } },',
    chainLine,
    "            ] }",
    "          }",
    "        }",
  ].join("\n");
}

function refusedFailureBranch(verb: string, action: string): string {
  return [
    "        {",
    '          "type": "object",',
    '          "properties": {',
    '            "verb": { "enum": ["' + verb + '"] },',
    '            "variant": { "enum": ["failure"] },',
    '            "result": { "oneOf": [',
    '              { "allOf": [',
    '                { "$ref": "#/definitions/mutationFailure" },',
    '                { "type": "object", "properties": { "action": { "enum": ["' + action + '"] } } },',
    '                { "type": "object", "required": ["chain"] }',
    "              ] },",
    '              { "$ref": "#/definitions/mutationRefused" }',
    "            ] }",
    "          }",
    "        }",
  ].join("\n");
}

function simpleBranch(verb: string, variants: readonly string[], ref: string): string {
  return [
    "        {",
    '          "type": "object",',
    '          "properties": {',
    '            "verb": { "enum": ["' + verb + '"] },',
    '            "variant": { "enum": [' + variants.map((v) => '"' + v + '"').join(", ") + "] },",
    '            "result": { "$ref": "#/definitions/' + ref + '" }',
    "          }",
    "        }",
  ].join("\n");
}

function memberZeroBranches(): string {
  const out: string[] = [];
  for (const row of CONTRACT_ROWS) {
    if (row.mutation) {
      // 기술자 내부 정합 — 계약 행의 action은 레인 행에 실재해야 한다(fail-closed).
      if (!(row.mutation.action in LANES)) throw new Error("계약 파손: 미지의 action — " + row.mutation.action);
      for (const v of row.mutation.variants) {
        out.push(v === "failure" && row.mutation.refusedOnFailure === true
          ? refusedFailureBranch(row.verb, row.mutation.action)
          : mutationBranch(row.verb, v, row.mutation.action, row.mutation.chain));
      }
    }
    for (const s of row.simple ?? []) out.push(simpleBranch(row.verb, s.variants, s.ref));
  }
  return out.join(",\n");
}

function verbEnumLine(): string {
  return '    "verb": { "enum": [' + CONTRACT_ROWS.map((r) => '"' + r.verb + '"').join(", ") + "] },";
}

export function generateSchema(): string {
  // 기술자 ↔ 수제 definitions 정합 단언 — mutation* 정의의 action enum(6곳)은 계약 행의
  // mutation action 목록(행 순서)과 같아야 한다. 행렬 분기만 생성되므로 이 단언이 없으면
  // 동사 추가 시 생성부는 맞고 definitions만 조용히 낡는다(열거끼리는 일치하고 레포와
  // 어긋나는 클래스 — 6은 손 앵커, defs가 늘면 의식적으로 갱신).
  const mutationActions = CONTRACT_ROWS.flatMap((r) => (r.mutation ? [r.mutation.action] : []));
  const actionEnumInline = '"action": { "enum": [' + mutationActions.map((a) => '"' + a + '"').join(", ") + "] }";
  const hits = DEFINITIONS.split(actionEnumInline).length - 1;
  if (hits !== 6) throw new Error("계약 파손: definitions의 action enum(" + hits + "곳)이 계약 행 mutation action 목록과 어긋난다(기대 6곳)");
  return HEADER_A + "\n" + verbEnumLine() + "\n" + HEADER_B + "\n" + memberZeroBranches() + "\n" + TAIL_MID + "\n" + DEFINITIONS + "\n";
}

function main(): void {
  // fail-loud argv — 파싱 SSOT(lib/cli.ts parseFlags)의 규약(unknown 거부·값 누락 거부)을 손으로
  // 따른다: cli.ts를 import하면 격리 재생성 증명(기술자 외 무참조)이 약해지기 때문이다.
  const args = process.argv.slice(2);
  let mode: "check" | "write" = "check";
  let target = fileURLToPath(new URL("./cli-result-schema.json", import.meta.url));
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--check") mode = "check";
    else if (a === "--write") mode = "write";
    else if (a === "--out") {
      const v = args[i + 1];
      if (v === undefined || v.startsWith("--")) { console.error("--out 값이 없다"); process.exit(2); }
      target = v;
      i++;
    } else {
      console.error("알 수 없는 인자: " + a + " (허용: --check | --write | --out <path>)");
      process.exit(2);
    }
  }
  const text = generateSchema();
  if (mode === "write") {
    writeFileSync(target, text);
    console.error("기록: " + target);
    return;
  }
  // --check — 드리프트 게이트. 대상 부재도 red(재생성 경로 안내), 성공은 한 줄로 보인다.
  let current: string;
  try { current = readFileSync(target, "utf8"); }
  catch {
    console.error("대상을 읽을 수 없다(재생성: --write): " + target);
    process.exit(1);
  }
  if (current !== text) {
    console.error("드리프트: " + target + " ≠ 생성 결과 — 기술자(lib/catalog-rows.ts)를 고치고 --write로 재생성하라");
    process.exit(1);
  }
  console.error("result-schema: 생성 결과와 byte 동일 OK");
}

main();
