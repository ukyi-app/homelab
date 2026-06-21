# 공유 차트 fail-closed 하드닝 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 전-앱 SSOT 차트 `platform/charts/app`를 fail-closed로 — 스키마 타이포 거부·extraManifests 백도어 제거·미구현/가짜 추상화(caddy·worker metrics·바이너리 의존) 정합·방어 갭(SA토큰·strategy) 폐쇄.

**Architecture:** 인레포 앱 0개라 차트는 라이브 미사용 → 순수 chart-test(helm template + kubeconform + bats) 정적 검증, 라이브 위험 0, 단일 PR. 5개 그룹 커밋(스키마·static·worker·프로브바이너리·방어갭). 동작보존=3 fixture(service/worker/static) 전수 렌더 통과 + 기존 7 bats 유지.

**Tech Stack:** Helm(go template), JSON Schema(draft-07, values.schema.json), kustomize/kubeconform, bats.

**설계 SSOT:** `docs/plans/2026-06-20-shared-chart-fail-closed-design.md`.

---

## 실행 모델

- **워크트리** `feat+shared-chart-fail-closed`. 단일 feature 브랜치, 단일 PR(라이브 위험 0이라 테마1 같은 배치-머지 불필요).
- **각 Task = 그룹 커밋**. 연속 실행 OK(STOP 조건 없음).
- **검증**: `bash platform/charts/app/tests/render.sh`(3 fixture helm template + kubeconform) + `bats platform/charts/app/tests/`. gate 재현은 `make chart-test`.
- **bats 규약**: `@test` 영어, 한국어 주석, bash 3.2(중간 단언은 `grep -q` 단순명령). 기존 `dep()` 패턴 재사용.
- **스키마 순서 불변식**: Task 1이 `additionalProperties:false`를 도입하므로, 이후 Task가 values.yaml에 새 키를 추가할 땐 **같은 Task에서 schema properties에도 등재**해야 helm template이 reject 안 한다.

---

## Task 1: 스키마 fail-closed + extraManifests 제거

**Files:**
- Modify: `platform/charts/app/values.schema.json`
- Modify: `platform/charts/app/values.yaml` (extraManifests 제거)
- Modify: `platform/charts/app/templates/deployment.yaml` (extraManifests range 블록 제거)
- Test: `platform/charts/app/tests/test_schema_fail_closed.bats` (신규)

**Step 1: 실패 테스트 작성** — `tests/test_schema_fail_closed.bats`

```bash
#!/usr/bin/env bats
# 스키마 fail-closed 회귀 (additionalProperties:false + 전수등재 + extraManifests 제거)
CHART="${BATS_TEST_DIRNAME}/.."
C="--set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
   --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
   --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
   --set route.host=x.example.com"

@test "schema rejects an unknown top-level key (typo'd security/probe keys cannot pass silently)" {
  run helm template t "$CHART" $C --set kind=service --set securtyContext.foo=bar
  [ "$status" -ne 0 ]
}

@test "schema rejects extraManifests (removed; extra manifests go via kustomize source#3)" {
  run helm template t "$CHART" $C --set kind=service --set 'extraManifests[0].kind=Pod'
  [ "$status" -ne 0 ]
}

@test "all three fixtures still render under the tightened schema (behavior-preserving)" {
  for k in service worker static; do
    run helm template t "$CHART" -f "$CHART/tests/fixtures/$k.yaml"
    [ "$status" -eq 0 ]
  done
}

@test "deployment template no longer emits an extraManifests range block" {
  run grep -q "extraManifests" "$CHART/templates/deployment.yaml"
  [ "$status" -ne 0 ]
}

@test "db.host override stays schema-valid and is consumed by the migrate Job (no contract regression)" {
  # migrate-job.yaml:50이 .Values.db.host를 default와 함께 소비한다 → additionalProperties:false가
  # db.host를 거부하면 기존 계약 회귀. schema에 host 등재 + 렌더 소비 확인. (plan 리뷰 Pass1 #2)
  run helm template t "$CHART" $C --set kind=service --set db.enabled=true --set db.host=custom.db.svc
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'custom.db.svc'
}
```

**Step 2: 실패 확인**

Run: `bats platform/charts/app/tests/test_schema_fail_closed.bats`
Expected: FAIL — 현 schema는 additionalProperties 없어 unknown 키/extraManifests를 통과시키고, deployment에 extraManifests 블록이 있다.

**Step 3: values.schema.json 교체** — 전 top키 등재 + `additionalProperties: false`(top + 구조적 object). passthrough(podSecurityContext·securityContext·resources)는 제외.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "additionalProperties": false,
  "required": ["image", "kind", "resources"],
  "properties": {
    "image": {
      "type": "object", "additionalProperties": false, "required": ["repo"],
      "properties": {
        "repo": { "type": "string", "minLength": 1 },
        "tag": { "type": "string", "pattern": "^$|^sha-[0-9a-f]{7,40}$|^[a-z0-9][a-z0-9._-]*$" },
        "digest": { "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" },
        "pullPolicy": { "type": "string", "enum": ["IfNotPresent", "Always", "Never"] }
      },
      "anyOf": [
        { "required": ["digest"] },
        { "required": ["tag"], "properties": { "tag": { "minLength": 1 } } }
      ]
    },
    "kind": { "type": "string", "enum": ["service", "worker", "static"] },
    "replicas": { "type": "integer", "minimum": 1, "maximum": 3 },
    "nameOverride": { "type": "string" },
    "imagePullSecrets": { "type": "array", "items": { "type": "object" } },
    "podAnnotations": { "type": "object", "additionalProperties": { "type": "string" } },
    "gateway": {
      "type": "object", "additionalProperties": false,
      "properties": { "name": { "type": "string", "minLength": 1 }, "namespace": { "type": "string", "minLength": 1 } }
    },
    "resources": {
      "type": "object", "required": ["requests", "limits"],
      "properties": {
        "requests": { "type": "object", "required": ["cpu", "memory"], "properties": { "cpu": { "type": "string", "minLength": 1 }, "memory": { "type": "string", "minLength": 1 } } },
        "limits":   { "type": "object", "required": ["cpu", "memory"], "properties": { "cpu": { "type": "string", "minLength": 1 }, "memory": { "type": "string", "minLength": 1 } } }
      }
    },
    "env": { "type": "array", "items": { "type": "object" } },
    "envFrom": { "type": "array", "items": { "type": "object" } },
    "route": {
      "type": "object", "additionalProperties": false,
      "properties": { "host": { "type": "string" }, "paths": { "type": "array", "items": { "type": "string" } }, "public": { "type": "boolean" } }
    },
    "homepage": {
      "type": "object", "additionalProperties": false,
      "properties": { "enabled": { "type": "boolean" }, "name": { "type": "string" }, "group": { "type": "string" }, "icon": { "type": "string" } }
    },
    "db": {
      "type": "object", "additionalProperties": false,
      "properties": { "enabled": { "type": "boolean" }, "host": { "type": "string" }, "migrateCmd": { "type": "array", "items": { "type": "string" } } }
    },
    "probes": {
      "type": "object", "additionalProperties": false,
      "properties": {
        "liveness": { "type": "object", "additionalProperties": false, "properties": { "path": { "type": "string" } } },
        "readiness": { "type": "object", "additionalProperties": false, "properties": { "path": { "type": "string" } } }
      }
    },
    "static": {
      "type": "object", "additionalProperties": false,
      "properties": { "server": { "type": "string", "enum": ["sws"] } }
    },
    "ports": {
      "type": "object", "additionalProperties": false,
      "properties": { "http": { "type": "integer" }, "metrics": { "type": "integer" } }
    },
    "metrics": {
      "type": "object", "additionalProperties": false,
      "properties": { "enabled": { "type": "boolean" } }
    },
    "podSecurityContext": { "type": "object" },
    "securityContext": { "type": "object" },
    "terminationGracePeriodSeconds": { "type": "integer" },
    "preStopSleepSeconds": { "type": "integer", "minimum": 0 }
  }
}
```

(주의 1: `strategy`·`automountServiceAccountToken`·`livenessProbe`는 Task 4·5에서 values.yaml 추가와 **함께** 이 schema에 등재한다. 여기선 아직 values.yaml에 없으므로 미등재가 정합.)

(주의 2 — Pass1 #2: additionalProperties:false는 **values.yaml 키뿐 아니라 템플릿이 `default`로 소비하는 키**까지 전수 등재해야 한다. `grep -rhoE '\.Values\.[a-zA-Z.]+' templates/`로 확인한 결과 `db.host`(migrate-job.yaml:50, default `pg-rw.database.svc`)가 values.yaml엔 없지만 템플릿이 소비 → **db 스키마에 `host` 포함**(위 db 블록). 다른 8개 strict object는 전수 커버 확인됨.)

**Step 4: values.yaml에서 extraManifests 제거** — 마지막 블록(escape hatch 주석 + `extraManifests: []`)을 삭제하고 대체 안내 주석 추가:

```yaml
# 추가 매니페스트(NetworkPolicy/ConfigMap 등)는 앱의 deploy 디렉토리(appset source#3,
# apps/<name>/deploy/prod kustomization)로. ⚠️ source#3는 별도 경로라 임의 kind 주입이 여전히
# 가능하다 — 테마2 성과는 "닫음"이 아니라 **차트가 toYaml로 임의 객체를 방출하던 무검증 백도어를
# 차트에서 제거(fail-closed)"한 것이다. source#3 자체의 kind 경계는 테마1 apps AppProject
# namespaceResourceWhitelist 머지 후 적용(현 origin/main은 project:default라 미적용); PSA는 Pod에만.
```

**Step 5: deployment.yaml에서 extraManifests range 블록 제거** — 파일 끝 블록 삭제:

```
{{- with .Values.extraManifests }}
{{- range . }}
---
{{ toYaml . }}
{{- end }}
{{- end }}
```

**Step 6: 통과 확인**

Run: `bats platform/charts/app/tests/test_schema_fail_closed.bats`
Expected: PASS (4 tests).
Run: `bash platform/charts/app/tests/render.sh`
Expected: 3 kind 전부 렌더 + kubeconform 통과(exit 0).
Run: `bats platform/charts/app/tests/test_schema.bats platform/charts/app/tests/test_deployment.bats`
Expected: PASS (기존 단언 무파괴).

**Step 7: Commit**

```bash
git add platform/charts/app/values.schema.json platform/charts/app/values.yaml platform/charts/app/templates/deployment.yaml platform/charts/app/tests/test_schema_fail_closed.bats
git commit -m "feat: 공유 차트 스키마 fail-closed (additionalProperties:false + 전수등재) + extraManifests 제거"
```

---

## Task 2: static — caddy enum 제거 + 프로브 /health

**Files:**
- Modify: `platform/charts/app/values.yaml` (static 주석)
- Modify: `platform/charts/app/templates/deployment.yaml` (static 프로브 /health 분기)
- Modify: `tools/app-config-schema.json` (static.server enum sws-only — Pass2 #2)
- Test: `platform/charts/app/tests/test_static.bats` (신규)
- Test: `tools/tests/test_app-config.bats` (caddy 거부 단언 추가)

(차트 values.schema.json의 static.server enum=sws 단일은 Task 1에서 이미 작성. 여기선 프로브·주석 + **외부
create-app 계약(app-config-schema.json)도 sws-only로** 동기화 — 안 하면 caddy 앱이 create-app 통과 후 Helm
렌더 실패하는 계약 skew.)

**Step 1: 실패 테스트 작성** — `tests/test_static.bats`

```bash
#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "static.server rejects caddy (enum is sws-only)" {
  run helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
    --set route.host=s.example.com --set kind=static --set static.server=caddy
  [ "$status" -ne 0 ]
}

@test "static probes hit the SWS health endpoint (/health), not service /healthz·/readyz" {
  out=$(dep --set kind=static --set route.host=s.example.com)
  echo "$out" | grep -q 'path: /health'
  run grep -q 'path: /healthz' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'path: /readyz' <<<"$out"; [ "$status" -ne 0 ]
}

@test "service probes keep /healthz·/readyz (unchanged)" {
  out=$(dep --set kind=service --set route.host=a.example.com)
  echo "$out" | grep -q 'path: /healthz'
  echo "$out" | grep -q 'path: /readyz'
}
```

**Step 2: 실패 확인**

Run: `bats platform/charts/app/tests/test_static.bats`
Expected: caddy 거부는 Task1 schema로 PASS일 수 있으나, static 프로브 /health 단언은 FAIL(현재 static도 /healthz·/readyz).

**Step 3: deployment.yaml static 프로브 분기** — 서빙 프로브 블록(현 line 64-72)을 kind=static일 때 `/health`로:

```yaml
          {{- if include "app.isServed" . }}
          {{- $live := .Values.probes.liveness.path }}
          {{- $ready := .Values.probes.readiness.path }}
          {{- if eq .Values.kind "static" }}
          {{- /* static-web-server는 --health로 /health만 노출 (서비스용 /healthz·/readyz 부재) */}}
          {{- $live = "/health" }}
          {{- $ready = "/health" }}
          {{- end }}
          livenessProbe:
            httpGet: { path: {{ $live }}, port: http }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: {{ $ready }}, port: http }
            initialDelaySeconds: 3
            periodSeconds: 5
          {{- else }}
          # worker 블록(Task 4에서 override 추가)
          livenessProbe:
            exec: { command: ["/bin/true"] }
            periodSeconds: 30
          {{- end }}
```

**Step 4: values.yaml static 주석 정합** — `static.server` 주석을 sws 단일로(caddy 언급 제거).

**Step 4-b: 외부 app-config 계약도 sws-only** (Pass2 #2) — 먼저 `tools/tests/test_app-config.bats`에 단언 추가:

```bash
@test "static.server enum is sws-only (chart contract: caddy removed)" {
  run jq -e '.properties.static.properties.server.enum == ["sws"]' "$S"
  [ "$status" -eq 0 ]
}
```

실패 확인: `bats tools/tests/test_app-config.bats -f "sws-only"` → FAIL(현재 `["sws","caddy"]`).
그다음 `tools/app-config-schema.json:77`의 static.server enum `["sws", "caddy"]` → `["sws"]`로 수정.
통과 확인: `bats tools/tests/test_app-config.bats` → PASS.

(외부 `ukyi-app/homelab-app-template`의 app-config-schema 사본은 수동 동기화 — CI 미강제([[homelab-app-template-sync]]).
후속으로 템플릿 레포도 sws-only 반영. 본 plan은 in-repo 계약만.)

**Step 5: 통과 확인**

Run: `bats platform/charts/app/tests/test_static.bats tools/tests/test_app-config.bats`
Expected: PASS.
Run: `bash platform/charts/app/tests/render.sh && bats platform/charts/app/tests/test_deployment.bats`
Expected: PASS.

**Step 6: Commit**

```bash
git add platform/charts/app/templates/deployment.yaml platform/charts/app/values.yaml platform/charts/app/tests/test_static.bats tools/app-config-schema.json tools/tests/test_app-config.bats
git commit -m "fix: static 차트 caddy 제거(sws 단일·차트+app-config 계약) + 프로브 SWS /health"
```

---

## Task 3: worker — 가짜 http/metrics 포트·scrape 제거

**Files:**
- Modify: `platform/charts/app/templates/deployment.yaml` (포트 블록 isServed 가드 + scrape annotation eq service)
- Test: `platform/charts/app/tests/test_worker_ports.bats` (신규)

**Step 1: 실패 테스트 작성** — `tests/test_worker_ports.bats`

```bash
#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "worker emits no http/metrics container ports and no scrape annotation (not served)" {
  out=$(dep --set kind=worker)
  run grep -q 'name: http' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'name: metrics' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'prometheus.io/scrape' <<<"$out"; [ "$status" -ne 0 ]
}

@test "service keeps http + metrics ports and scrape annotation" {
  out=$(dep --set kind=service --set route.host=a.example.com)
  echo "$out" | grep -q 'name: http'
  echo "$out" | grep -q 'name: metrics'
  echo "$out" | grep -q 'prometheus.io/scrape'
}

@test "static keeps http port but no metrics (serves files, no /metrics)" {
  out=$(dep --set kind=static --set route.host=s.example.com)
  echo "$out" | grep -q 'name: http'
  run grep -q 'name: metrics' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'prometheus.io/scrape' <<<"$out"; [ "$status" -ne 0 ]
}
```

**Step 2: 실패 확인**

Run: `bats platform/charts/app/tests/test_worker_ports.bats`
Expected: FAIL — 현재 worker가 http 포트(항상)+metrics(ne static)+scrape(ne static) 방출, static도 metrics+scrape.

**Step 3: deployment.yaml 포트 블록 + scrape annotation 수정**

포트 블록(현 line 47-53)을 served-gate + service-only-metrics로:

```yaml
          {{- if include "app.isServed" . }}
          ports:
            - name: http
              containerPort: {{ .Values.ports.http }}
            {{- if eq .Values.kind "service" }}
            - name: metrics
              containerPort: {{ .Values.ports.metrics }}
            {{- end }}
          {{- end }}
```

scrape annotation(현 line 19-23)을 `metrics.enabled AND eq kind service`로:

```yaml
        {{- if and .Values.metrics.enabled (eq .Values.kind "service") }}
        prometheus.io/scrape: "true"
        prometheus.io/port: "{{ .Values.ports.metrics }}"
        prometheus.io/path: "/metrics"
        {{- end }}
```

**Step 4: 통과 확인**

Run: `bats platform/charts/app/tests/test_worker_ports.bats`
Expected: PASS (3 tests).
Run: `bash platform/charts/app/tests/render.sh && bats platform/charts/app/tests/test_deployment.bats`
Expected: PASS (service scrape 단언 유지, worker httpGet 부재 유지).

**Step 5: Commit**

```bash
git add platform/charts/app/templates/deployment.yaml platform/charts/app/tests/test_worker_ports.bats
git commit -m "fix: worker가 안 서빙하는 http/metrics 포트·scrape annotation 제거 (service-only)"
```

---

## Task 4: liveness·preStop 바이너리 독립 (polyglot/distroless)

**Files:**
- Modify: `platform/charts/app/values.schema.json` (livenessProbe 등재)
- Modify: `platform/charts/app/values.yaml` (livenessProbe + preStopSleepSeconds 주석)
- Modify: `platform/charts/app/templates/deployment.yaml` (liveness override + preStop 조건)
- Test: `platform/charts/app/tests/test_probe_override.bats` (신규)

**Step 1: 실패 테스트 작성** — `tests/test_probe_override.bats`

```bash
#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "livenessProbe override replaces the default (distroless: no /bin/true exec)" {
  out=$(dep --set kind=worker --set livenessProbe.grpc.port=9000 --set livenessProbe.periodSeconds=20)
  echo "$out" | grep -q 'grpc'
  run grep -q '/bin/true' <<<"$out"; [ "$status" -ne 0 ]
}

@test "default worker liveness is exec /bin/true when no override (unchanged)" {
  out=$(dep --set kind=worker)
  echo "$out" | grep -q '/bin/true'
}

@test "preStopSleepSeconds=0 omits the preStop block (distroless: no /bin/sleep)" {
  out=$(dep --set kind=service --set route.host=a.example.com --set preStopSleepSeconds=0)
  run grep -q 'preStop' <<<"$out"; [ "$status" -ne 0 ]
}

@test "default preStop still uses /bin/sleep (unchanged)" {
  out=$(dep --set kind=service --set route.host=a.example.com)
  echo "$out" | grep -q 'sleep'
}
```

**Step 2: 실패 확인**

Run: `bats platform/charts/app/tests/test_probe_override.bats`
Expected: FAIL — override·preStopSleepSeconds:0 미지원(+ additionalProperties:false라 `--set livenessProbe.*`가 schema 거부 → Step 3 등재 필수).

**Step 3: schema에 livenessProbe 등재** — values.schema.json properties에 추가(passthrough):

```json
    "livenessProbe": { "type": "object" },
```

**Step 4: deployment.yaml liveness override + worker 블록 + preStop 조건**

served/worker liveness에 override 분기(Task2에서 만든 served 블록의 livenessProbe + worker 블록):

```yaml
          {{- if include "app.isServed" . }}
          {{- $live := .Values.probes.liveness.path }}{{- $ready := .Values.probes.readiness.path }}
          {{- if eq .Values.kind "static" }}{{- $live = "/health" }}{{- $ready = "/health" }}{{- end }}
          {{- if .Values.livenessProbe }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
          {{- else }}
          livenessProbe:
            httpGet: { path: {{ $live }}, port: http }
            initialDelaySeconds: 5
            periodSeconds: 10
          {{- end }}
          readinessProbe:
            httpGet: { path: {{ $ready }}, port: http }
            initialDelaySeconds: 3
            periodSeconds: 5
          {{- else }}
          # worker: 기본 exec /bin/true; distroless는 livenessProbe로 오버라이드
          {{- if .Values.livenessProbe }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
          {{- else }}
          livenessProbe:
            exec: { command: ["/bin/true"] }
            periodSeconds: 30
          {{- end }}
          {{- end }}
```

preStop 블록(현 line 79-82)을 조건부로:

```yaml
          {{- if gt (int .Values.preStopSleepSeconds) 0 }}
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sleep", "{{ .Values.preStopSleepSeconds }}"]
          {{- end }}
```

**Step 5: values.yaml livenessProbe 추가 + 주석**

```yaml
# liveness override (raw probe spec). 비면 기본(served=httpGet, worker=exec /bin/true).
# distroless(Rust static/scratch) 이미지는 /bin/true가 없으니 grpc/tcpSocket 등으로 오버라이드.
livenessProbe: {}
```
`preStopSleepSeconds` 주석에 "0이면 preStop 생략(distroless drain은 terminationGracePeriod+readiness)" 추가.

**Step 6: 통과 확인**

Run: `bats platform/charts/app/tests/test_probe_override.bats`
Expected: PASS (4 tests).
Run: `bash platform/charts/app/tests/render.sh && bats platform/charts/app/tests/test_deployment.bats platform/charts/app/tests/test_static.bats`
Expected: PASS.

**Step 7: Commit**

```bash
git add platform/charts/app/values.schema.json platform/charts/app/values.yaml platform/charts/app/templates/deployment.yaml platform/charts/app/tests/test_probe_override.bats
git commit -m "feat: liveness/preStop 바이너리 의존 제거 — livenessProbe override + preStopSleepSeconds:0 생략"
```

---

## Task 5: 방어 갭 — SA 토큰 + Deployment strategy

**Files:**
- Modify: `platform/charts/app/values.schema.json` (automountServiceAccountToken·strategy 등재)
- Modify: `platform/charts/app/values.yaml` (기본값)
- Modify: `platform/charts/app/templates/deployment.yaml` (pod spec·deployment spec)
- Modify: `platform/charts/app/templates/migrate-job.yaml` (Job 파드 spec automount — Pass2 #1)
- Test: `platform/charts/app/tests/test_defense.bats` (신규)

**Step 1: 실패 테스트 작성** — `tests/test_defense.bats`

```bash
#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "pods do not automount the ServiceAccount token by default (apps need no k8s API)" {
  out=$(dep --set kind=worker)
  echo "$out" | grep -q 'automountServiceAccountToken: false'
}

@test "automountServiceAccountToken can be opted in for API-using apps" {
  out=$(dep --set kind=worker --set automountServiceAccountToken=true)
  echo "$out" | grep -q 'automountServiceAccountToken: true'
}

@test "migration Job pod also defaults to no SA token automount (Pass2 #1: second pod template)" {
  # db.enabled면 migrate-job.yaml이 앱 이미지+envFrom 시크릿으로 Job 파드를 렌더한다 — 별도 파드 spec이라
  # deployment fix가 안 닿는다. Job 파드도 토큰 미마운트여야 공격표면이 진짜 닫힌다.
  out=$(helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
    --set kind=service --set route.host=a.example.com --set db.enabled=true | yq 'select(.kind=="Job")')
  echo "$out" | grep -q 'automountServiceAccountToken: false'
}

@test "migration Job honors automount opt-in too" {
  out=$(helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
    --set kind=service --set route.host=a.example.com --set db.enabled=true \
    --set automountServiceAccountToken=true | yq 'select(.kind=="Job")')
  echo "$out" | grep -q 'automountServiceAccountToken: true'
}

@test "Deployment strategy defaults to Recreate (single-node RWO deadlock safety)" {
  out=$(dep --set kind=service --set route.host=a.example.com)
  echo "$out" | grep -q 'type: Recreate'
}

@test "strategy can be overridden to RollingUpdate for multi-replica stateless apps" {
  out=$(dep --set kind=service --set route.host=a.example.com --set strategy.type=RollingUpdate)
  echo "$out" | grep -q 'type: RollingUpdate'
}
```

**Step 2: 실패 확인**

Run: `bats platform/charts/app/tests/test_defense.bats`
Expected: FAIL — 미지원(+ additionalProperties:false라 `--set`이 거부될 수 있어 Step 3 등재 필수).

**Step 3: schema 등재** — values.schema.json properties에 추가:

```json
    "automountServiceAccountToken": { "type": "boolean" },
    "strategy": {
      "type": "object", "additionalProperties": false,
      "properties": {
        "type": { "type": "string", "enum": ["Recreate", "RollingUpdate"] },
        "rollingUpdate": { "type": "object" }
      }
    },
```

**Step 4: values.yaml 기본값 추가**

```yaml
# SA 토큰: 앱은 차트가 RBAC를 0 부여하므로 k8s API 불요 → 토큰 미마운트. API 쓰는 앱만 true.
automountServiceAccountToken: false

# 배포 전략: 단일노드 + RWO PVC면 RollingUpdate가 두 파드의 볼륨 경합으로 교착 → 기본 Recreate.
# 멀티레플리카 stateless는 { type: RollingUpdate }로 무중단 배포 opt-in.
strategy:
  type: Recreate
```

**Step 5: deployment.yaml — pod spec + deployment spec**

deployment `spec`(현 line 9-10 부근)에 strategy 추가:

```yaml
spec:
  replicas: {{ .Values.replicas }}
  strategy:
    {{- toYaml .Values.strategy | nindent 4 }}
```

pod `spec`(현 terminationGracePeriodSeconds 위)에 automount 추가:

```yaml
    spec:
      automountServiceAccountToken: {{ .Values.automountServiceAccountToken }}
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
```

**Step 5-b: migrate-job.yaml 파드 spec에도 automount** (Pass2 #1) — `templates/migrate-job.yaml`의 Job 파드 `spec:`(현 line 29, `restartPolicy: Never` 위)에 추가:

```yaml
    spec:
      automountServiceAccountToken: {{ .Values.automountServiceAccountToken }}
      restartPolicy: Never
```

(strategy는 Job에 없으니 deployment에만. migrate Job은 앱 이미지+envFrom 시크릿을 실행하는 2번째 파드라 SA토큰 fix가 여기도 닿아야 한다.)

**Step 6: 통과 확인**

Run: `bats platform/charts/app/tests/test_defense.bats`
Expected: PASS (6 tests — Deployment 2 automount + 2 strategy + Job 2 automount).
Run: `make chart-test`
Expected: 전체 chart-test green(3 kind 렌더 + kubeconform + 전 bats).

**Step 7: Commit**

```bash
git add platform/charts/app/values.schema.json platform/charts/app/values.yaml platform/charts/app/templates/deployment.yaml platform/charts/app/templates/migrate-job.yaml platform/charts/app/tests/test_defense.bats
git commit -m "feat: 공유 차트 방어 갭 — SA 토큰 automount false(Deployment+migrate Job) + strategy 기본 Recreate"
```

---

## 전체 검증 (최종)

```bash
make chart-test                 # 3 kind 렌더 + kubeconform + 전 bats green
bats platform/charts/app/tests/ # 신규 5 + 기존 7 전부 PASS
```

기존 7 bats(test_deployment/route/migrate/schema/image-digest/db-consume/wave0) 무파괴 — service 단언(/healthz·/readyz·scrape·sleep)은 service 불변이라 생존.

## 동작 비파괴 요약

- 인레포 앱 0개라 차트는 라이브 미사용 → 전 변경이 chart-test로만 검증, 라이브 워크로드 무영향.
- 동작 default 변경은 strategy(→Recreate) 하나뿐 — 0앱이라 무영향, 향후 앱은 명시 opt-in.
- 나머지(스키마 엄격화·extraManifests/caddy/worker포트 제거·SA토큰·liveness/preStop override)는 가산 또는 0앱 무영향.
- 롤백=단일 PR revert.

## 완료 조건 (acceptance — Pass3 #2)

본 plan(in-repo)이 끝나도 **caddy 제거는 외부 계약이 동기화되기 전엔 미완**이다:

- **owner-local 차단 항목**: `ukyi-app/homelab-app-template`의 app-config-schema 사본을 `static.server` sws-only로
  동기화한다(별도 레포, CI 미강제 — [[homelab-app-template-sync]]). 안 하면 템플릿서 생성한 새 앱이
  `static.server: caddy`로 템플릿 검증을 통과한 뒤 homelab create-app/렌더에서 막혀 onboarding이 멈춘다.
- 검증: 템플릿 레포의 `onboard-app.mjs --dry-run`(또는 app-config 검증)이 caddy를 거부하는지 확인.
- 이 격차는 **비차단 후속이 아니라 caddy 제거의 승인기준**이다 — in-repo PR 머지 후 owner가 즉시 처리.

## 범위 밖 (후속)

worker 진짜 metrics opt-in·caddy 재도입은 필요 시 후속. 테마3(tools CLI lib SSOT)~8.

## Adversarial review dispositions

codex 적대 plan 리뷰 **3패스**(3패스 cap) — 총 **6 발견 전부 Accept·반영**. 발견은 매 패스 새것(반복 0),
코드/테스트 결함(Pass1) → 추가 표면(Pass2) → cross-boundary 주장 정직성(Pass3)으로 연성화·수렴.

- **Pass1** (needs-attention, 2건, **전부 Accept**): ① `grep -qv` 부재 단언이 false-green(멀티라인서 늘 통과)
  → `run grep -q + [status≠0]`으로 교체(실제 bats 스모크로 회귀 포착 검증). ② additionalProperties:false가
  템플릿이 default로 소비하는 `db.host`(migrate-job.yaml:50)를 거부하는 계약 회귀 → db 스키마에 host 추가 +
  회귀 테스트(전 strict object의 nested 키 전수 확인, db.host가 유일 누락이었음).
- **Pass2** (needs-attention, 2건, **전부 Accept**): ① migrate Job(2번째 파드, 앱이미지+시크릿)에 SA 토큰
  automount가 남음 → Task5에 migrate-job.yaml automount + Job 렌더 bats. ② 차트만 caddy 제거하고 외부
  app-config-schema.json은 stale → Task2에 app-config-schema sws-only + tools 테스트.
- **Pass3** (needs-attention, 2건, **전부 Accept**): ① source#3 안전 주장이 과함(테마1 미머지라 apps appset은
  project:default) → 주장 정직화(차트 백도어 제거가 성과, source#3 경계는 테마1 의존)·설계문서 동반 정정.
  ② 외부 템플릿 동기화를 비차단 후속→owner-local 승인기준으로 격상.

**최종 패스(Pass3) verdict** = `needs-attention`, summary "still leaves a bypass path and knowingly creates
cross-repo contract skew" — 그 2건을 **본 plan에 반영 완료**한 뒤(주장 정정 + 승인기준 격상), 사용자가 cap(3패스)에서
finalize 승인(**미해결 high/critical 0건** — 6건 전부 Accept·적용). 잔여 cross-repo(템플릿)는 위 '완료 조건'의
owner-local 승인기준으로 추적.

## Execution directives

- **Skill:** `executing-plans`로 구현 — **별도 세션, 이 워크트리(`feat+shared-chart-fail-closed`)에서**.
- **연속 실행 OK**: 인레포 앱 0개라 차트는 라이브 미사용 → **라이브 게이트·배치 STOP 없음**(테마1과 다름).
  5개 Task를 연속 구현·커밋해 단일 PR로 만든다. STOP은 executing-plans 일반 조건(의존성 누락·반복 실패·모순·
  critical gap)에서만.
- **Commits — 규칙 직접 적용, `Skill(commit)` 호출 금지**:
  - 한국어, AI 마커 금지(`🤖`·`Co-Authored-By` 등).
  - `<type>(<scope>): 한국어 설명`. type ∈ {feat, fix, refactor, docs, style, test, chore}만.
  - 그룹핑: 각 Task의 `Commit` 스텝 `git add` 목록 그대로(같은 목적 묶음).
  - 위치: 각 plan `Commit` 스텝에서 현재 feature-branch 워크트리에 직접 커밋(이미 main 밖).
- **owner-local 후속(머지 후)**: '완료 조건' 절 — 외부 homelab-app-template app-config-schema sws-only 동기화.
