#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
R="--set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
   --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"
tpl() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 $R "$@"; }

@test "web gets Service and HTTPRoute referencing the shared Gateway" {
  out=$(tpl --set kind=web --set route.host=api.example.com --set route.public=true)
  echo "$out" | yq 'select(.kind=="Service")' | grep -q "port: 8080"
  rt=$(echo "$out" | yq 'select(.kind=="HTTPRoute")')
  [[ "$rt" == *"name: homelab"* ]]
  [[ "$rt" == *"namespace: gateway"* ]]
  [[ "$rt" == *"sectionName: web-public"* ]]
  [[ "$rt" == *"api.example.com"* ]]
}

@test "internal app binds to the internal HTTPS listener" {
  rt=$(tpl --set kind=web --set route.host=admin.home.example.com --set route.public=false | yq 'select(.kind=="HTTPRoute")')
  [[ "$rt" == *"sectionName: web-internal-tls"* ]]
}

@test "worker has no Service and no HTTPRoute" {
  out=$(tpl --set kind=worker)
  [ -z "$(echo "$out" | yq 'select(.kind=="Service")')" ]
  [ -z "$(echo "$out" | yq 'select(.kind=="HTTPRoute")')" ]
}

@test "homepage discovery annotations gate on homepage.enabled" {
  tpl --set kind=web --set route.host=api.example.com > "$BATS_TEST_TMPDIR/off.yaml"
  run grep -q 'gethomepage.dev/enabled' "$BATS_TEST_TMPDIR/off.yaml"; [ "$status" -ne 0 ]
  tpl --set kind=web --set route.host=api.example.com --set homepage.enabled=true --set homepage.icon=mdi-test > "$BATS_TEST_TMPDIR/on.yaml"
  run grep -q 'gethomepage.dev/enabled: "true"' "$BATS_TEST_TMPDIR/on.yaml"; [ "$status" -eq 0 ]
  run grep -q 'gethomepage.dev/group: "Apps"' "$BATS_TEST_TMPDIR/on.yaml"; [ "$status" -eq 0 ]
  run grep -q 'gethomepage.dev/icon: "mdi-test"' "$BATS_TEST_TMPDIR/on.yaml"; [ "$status" -eq 0 ]
  run grep -q 'gethomepage.dev/pod-selector: "app.kubernetes.io/instance=t"' "$BATS_TEST_TMPDIR/on.yaml"; [ "$status" -eq 0 ]
}
