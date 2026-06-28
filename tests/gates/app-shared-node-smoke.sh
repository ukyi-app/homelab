#!/usr/bin/env bash
# app-shared .mts를 bun 없이 node strip-types(>=22.18)로 실제 seal 경로까지 실행 —
# 앱 레포 `pnpm secret:seal` 경로 증명(A.5 F1 안전망). node_modules(yaml)는 bun install이 채운다.
set -euo pipefail
node --version
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# kubeseal stub — 실제 호출 없이 seal 경로(spawnSync stdin→stdout)를 node에서 검증(test_seal-secret.bats와 동일 패턴)
mkdir -p "$tmp/bin"
cat > "$tmp/bin/kubeseal" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null            # stdin(평문 Secret manifest) 소비
printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nspec:\n  encryptedData:\n    TOKEN: AgXstub\n'
STUB
chmod +x "$tmp/bin/kubeseal"
cat > "$tmp/.app-config.yml" <<'EOF'
name: smoke-app
kind: service
EOF
printf 'TOKEN=x\n' > "$tmp/.env"
# 실제 seal 경로(--app/--out + kubeseal spawnSync)를 node strip-types로 — 출력 파일 단언
PATH="$tmp/bin:$PATH" node tools/seal-secret.mts --config "$tmp/.app-config.yml" --env "$tmp/.env" --app smoke-app --out "$tmp/sealed.yaml"
[ -s "$tmp/sealed.yaml" ] || { echo "sealed output missing"; exit 1; }
node tools/env-example.mts --config "$tmp/.app-config.yml" --sealed "$tmp/sealed.yaml" --out "$tmp/.env.example"
[ -s "$tmp/.env.example" ] || { echo "env-example output missing"; exit 1; }
grep -q '^TOKEN=' "$tmp/.env.example" || { echo "env-example key missing"; exit 1; }
echo "app-shared node smoke OK"
