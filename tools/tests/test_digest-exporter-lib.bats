#!/usr/bin/env bats
# digest-exporter APPS 편집 lib(create-app/teardown-app 공용) 단위: add/remove 멱등·이름 정렬·fail-loud.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; TMP="$(mktemp -d)"
  printf '            env:\n                - name: APPS\n                  value: ""\n' > "$TMP/de.txt"; }
teardown() { rm -rf "$TMP"; }
run_lib() { bun -e "
  import { addApp, removeApp } from '$ROOT/tools/lib/digest-exporter.ts';
  import { readFileSync } from 'node:fs';
  let t = readFileSync('$TMP/de.txt','utf8');
  $1
  process.stdout.write(t);
"; }
@test "addApp inserts a name=ref token, idempotent and name-sorted" {
  run run_lib "t = addApp(t,'trip-mate-api','ghcr.io/o/trip-mate-api:sha-b'); t = addApp(t,'page','ghcr.io/o/page:sha-a'); t = addApp(t,'page','ghcr.io/o/page:sha-a');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: "page=ghcr.io/o/page:sha-a trip-mate-api=ghcr.io/o/trip-mate-api:sha-b"'
}
@test "removeApp drops the token idempotently" {
  run run_lib "t = addApp(t,'page','ghcr.io/o/page:sha-a'); t = removeApp(t,'page'); t = removeApp(t,'page');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: ""'
}
@test "edit throws fail-loud when APPS value line is missing (format drift)" {
  echo 'no apps here' > "$TMP/de.txt"
  run run_lib "t = addApp(t,'page','x');"
  [ "$status" -ne 0 ]
}
