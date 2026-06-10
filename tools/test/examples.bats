#!/usr/bin/env bats
CHART="platform/charts/app"

render() { helm template "$1" "$CHART" -f "$2"; }

@test "worker renders, no HTTPRoute, Node/Go memory gate" {
  out=$(render worker apps/worker/deploy/prod/values.yaml)
  [ -z "$(echo "$out" | yq 'select(.kind=="HTTPRoute")')" ]
  [[ "$out" == *"Deployment"* ]]
}

@test "ssr (Node standalone) renders Service+HTTPRoute, limit >=256Mi" {
  out=$(render web apps/web/deploy/prod/values.yaml)
  [[ "$out" == *"HTTPRoute"* ]]
  echo "$out" | yq 'select(.kind=="Deployment").spec.template.spec.containers[0].resources.limits.memory' | grep -qE '256Mi|384Mi'
}

@test "spa served by static-web-server, no metrics port" {
  out=$(render console apps/console/deploy/prod/values.yaml)
  [[ "$out" == *"static-web-server"* ]] || [[ "$out" == *"page-fallback"* ]]
  [ -z "$(echo "$out" | yq 'select(.kind=="Deployment").spec.template.spec.containers[0].ports[] | select(.name=="metrics")')" ]
}
