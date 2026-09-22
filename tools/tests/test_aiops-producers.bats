#!/usr/bin/env bats
# 실제 생산자 결과 작성기 → artifact 파일 → 수집 → 사건 조회.
bats_require_minimum_version 1.5.0
setup() { cd "$BATS_TEST_DIRNAME/../.." || exit 1; }

@test "the observation writer reports same-SHA warning and silent healthy without Telegram" {
  for drift in true false; do
    AIOPS_PRODUCER='tf-reconcile.yaml/reconcile' AIOPS_TARGET=cloudflare AIOPS_JOB_RESULT=success \
      AIOPS_STEPS="{\"drift\":{\"outcome\":\"success\",\"outputs\":{\"drift\":\"$drift\"}}}" \
      GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=1111111111111111111111111111111111111111 \
      GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_SOURCE_REVISION=1111111111111111111111111111111111111111 \
      bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/$drift.json"
  done
  jq -e '.status == "warning" and .completed == true and .target == "cloudflare"' "$BATS_TEST_TMPDIR/true.json"
  jq -e '.status == "healthy" and .completed == true and .revision == "1111111111111111111111111111111111111111"' "$BATS_TEST_TMPDIR/false.json"
  expected="$(sha256sum tools/aiops-producers-v1.json | cut -d ' ' -f 1)"
  jq -e --arg expected "$expected" '.contractVersion == 1 and .contractSha256 == $expected' "$BATS_TEST_TMPDIR/true.json"
}

@test "unregistered producers cannot emit apparently verified observations" {
  run env AIOPS_PRODUCER=unknown.yaml/check AIOPS_TARGET=test AIOPS_JOB_RESULT=success \
    AIOPS_STEPS='{"check":{"outcome":"success"}}' AIOPS_PRIMARY=check \
    GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_SOURCE_REVISION=1111111111111111111111111111111111111111 \
    bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/unknown.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Fq 'AIOps observation invalid or not written'
  [ ! -e "$BATS_TEST_TMPDIR/unknown.json" ]
}

@test "DNS transient and credential expiry remain distinct from a completed healthy check" {
  for transient in 0 1; do
    AIOPS_PRODUCER='dns-drift.yaml/check' AIOPS_TARGET=public-dns AIOPS_JOB_RESULT=success \
      AIOPS_STEPS="{\"check\":{\"outcome\":\"success\",\"outputs\":{\"count\":\"0\",\"transient\":\"$transient\"}}}" \
      GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=1111111111111111111111111111111111111111 \
      GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_SOURCE_REVISION=1111111111111111111111111111111111111111 \
      bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/dns-$transient.json"
  done
  jq -e '.status == "healthy" and .completed == true' "$BATS_TEST_TMPDIR/dns-0.json"
  jq -e '.status == "unobservable" and .completed == false' "$BATS_TEST_TMPDIR/dns-1.json"
  AIOPS_PRODUCER='credential-expiry.yaml/check' AIOPS_TARGET=credential-ledger AIOPS_JOB_RESULT=success \
    AIOPS_STEPS='{"exp":{"outcome":"success","outputs":{"rc":"1","body":"must-not-export"}}}' \
    GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_SOURCE_REVISION=1111111111111111111111111111111111111111 \
    bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/expiry.json"
  jq -e '.status == "warning" and .completed == true and (has("body") | not)' "$BATS_TEST_TMPDIR/expiry.json"
}

@test "every notification producer writes an independent observation including delegated notifications" {
  run bun -e '
    import {parse} from "yaml";import{readdirSync,readFileSync}from"node:fs";
    let count=0;const producers:string[]=[];
    for(const file of readdirSync(".github/workflows").filter(f=>f.endsWith(".yaml"))){
      const workflow=parse(readFileSync(".github/workflows/"+file,"utf8"));
      for(const [id,job]of Object.entries(workflow.jobs??{})){
        const steps=(job as any).steps??[];
        if(!steps.some((s:any)=>/(?:telegram|mutation)-notify/.test(s.uses??"")))continue;
        count++;
        producers.push(file+"/"+id);
        const observation=steps.find((s:any)=>s.uses==="./.github/actions/aiops-observation");
        if(!observation||observation.if!=="always()"||observation.with?.producer!==file+"/"+id)throw Error(file+"/"+id+": missing independent observation");
        if(steps.some((s:any)=>/mutation-notify/.test(s.uses??"")) && (job as any).if!=="always()")throw Error("delegated normal path missing");
        // revision은 checkout 직후 캡처(aiops-provenance)에서만 온다 — GITHUB_SHA 일괄 대체 금지.
        const source=observation.with?.["source-revision"];
        const match=typeof source==="string"?/^\$\{\{ steps\.([A-Za-z0-9_-]+)\.outputs\.source-revision \}\}$/.exec(source):null;
        if(!match)throw Error(file+"/"+id+": observation must take the captured provenance source-revision");
        const capture=steps.findIndex((s:any)=>s.uses==="./.github/actions/aiops-provenance"&&s.id===match[1]);
        if(capture<0)throw Error(file+"/"+id+": missing aiops-provenance capture step");
        const observationIndex=steps.indexOf(observation);
        const checkout=steps.findIndex((s:any)=>/(^|\/)actions\/checkout@/.test(s.uses??""));
        // 첫 checkout 바로 다음을 요구한다. 새 변이 명령을 정규식 목록에 빠뜨려도 늦은 캡처를 허용하지 않는다.
        if(checkout<0||capture!==checkout+1)throw Error(file+"/"+id+": capture must immediately follow checkout");
        if(capture>observationIndex)throw Error(file+"/"+id+": capture after observation");
        // 제안 축은 별도 스텝의 result=pr 게이트로만 — 출처와 같은 필드에 접지 않는다.
        if(observation.with?.["proposal-revision"]!==undefined){
          const reference=/^\$\{\{ steps\.([A-Za-z0-9_-]+)\.outputs\.revision \}\}$/.exec(observation.with["proposal-revision"]);
          const proposal=reference?steps.findIndex((s:any)=>s.id===reference[1]):-1;
          const mutation=steps.findIndex((s:any)=>s.id===observation.with["primary-step"]);
          if(mutation<0||proposal<=mutation||proposal>=observationIndex)throw Error(file+"/"+id+": proposal must follow mutation and precede observation");
          const condition=String(steps[proposal].if??"");
          if(!steps[mutation].id||!condition.includes("steps."+steps[mutation].id+".outputs.result == \u0027pr\u0027"))throw Error(file+"/"+id+": proposal axis must use the mutation result=pr");
          for(const ref of condition.matchAll(/steps\.([A-Za-z0-9_-]+)\./g))if(!steps.some((s:any)=>s.id===ref[1]))throw Error(file+"/"+id+": proposal guard references an absent step");
        }
      }
    }
    const contract=JSON.parse(readFileSync("tools/aiops-producers-v1.json","utf8"));
    if(contract.version!==1)throw Error("unsupported producer contract");
    const catalog=contract.producers;
    if(count<25 || JSON.stringify(producers.sort())!==JSON.stringify(Object.keys(catalog).sort()))throw Error("producer inventory mismatch");console.log(count);
  '
  if [ "$status" -ne 0 ]; then echo "$output"; fi
  [ "$status" -eq 0 ]
}

@test "the observation composite takes the captured source instead of re-reading ambient HEAD" {
  # 원 결함의 회귀 증인: composite가 관측 시점에 git rev-parse HEAD를 다시 읽으면 안 된다.
  # 판정은 write 스텝의 run 본문만 본다 — 주석의 설명 문구를 증인으로 오인하지 않는다.
  body="$(yq -r '.runs.steps[] | select(.id == "write") | .run' .github/actions/aiops-observation/action.yml)"
  grep -Fq 'bun tools/aiops-observation.ts' <<<"$body"
  run grep -F 'git rev-parse' <<<"$body"
  [ "$status" -eq 1 ]
  run grep -F 'AIOPS_REVISION' <<<"$body"
  [ "$status" -eq 1 ]
  grep -Fq 'AIOPS_SOURCE_REVISION: ${{ inputs.source-revision }}' .github/actions/aiops-observation/action.yml
  grep -Fq 'source-revision: { description:' .github/actions/aiops-observation/action.yml
  grep -Fq 'bash "${{ github.action_path }}/capture.sh"' .github/actions/aiops-provenance/action.yml
}

@test "DNS partial results preserve independent healthy and unobservable targets" {
  printf '[{"name":"ok","host":"ok.example.test","public":true,"active":true},{"name":"unknown","host":"unknown.example.test","public":true,"active":true}]' > "$BATS_TEST_TMPDIR/apps.json"
  bun tools/dns-drift-check.ts --apps "$BATS_TEST_TMPDIR/apps.json" --floor reserved=0 --fixture '{"ok.example.test":["192.0.2.1"],"unknown.example.test":"TRANSIENT"}' > "$BATS_TEST_TMPDIR/dns.json"
  AIOPS_PRODUCER='dns-drift.yaml/check' AIOPS_TARGET=public-dns AIOPS_JOB_RESULT=success \
    AIOPS_STEPS="$(jq -c '{check:{outcome:"success",outputs:{count:"0",transient:"1",observations:(.observations | tojson)}}}' "$BATS_TEST_TMPDIR/dns.json")" \
    GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_SOURCE_REVISION=1111111111111111111111111111111111111111 \
    bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/partial.json"
  jq -e '.observations | any(.target == "ok.example.test" and .status == "healthy" and .completed == true)' "$BATS_TEST_TMPDIR/partial.json"
  jq -e '.observations | any(.target == "unknown.example.test" and .status == "unobservable" and .completed == false)' "$BATS_TEST_TMPDIR/partial.json"
}
