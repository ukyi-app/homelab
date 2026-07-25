// 봉인 계약(sealed contract) 커널 — CONTEXT.md 용어 준수(봉인 계약·봉인 원본 바이트·checksum/secrets·배선·strict scope).
// 하나의 순수 함수 readSealed가 봉인 계약 전부를 소유한다: 6검증(kind·namespace·name·empty·UPPER_SNAKE·
// strict scope)의 **판정과 에러 문구** · checksum 식 · 이름 규약 · **디스크에 쓸 바이트**. create-app(그린필드
// 구성)·update-secrets(제자리 병합) 두 콜사이트가 같은 구현을 통과한다 — 형식이 갈리면 파드가 회전하지 않는
// 침묵 버그가 났다(#299: 재직렬화본 해시 vs 원본 바이트).
//
// image-pin.ts와 달리 에러 문구를 콜사이트에 남기지 않고 **커널이 소유**한다: 두 콜사이트가 같은 정책을
// 같은 문구로 판정하기 때문이다(image-pin은 콜사이트마다 결과가 달라 문구가 콜사이트 소유). 에러 모드는
// interface의 일부다(tools/README.md lib 절 단서 참고).
//
// 소유 경계 — 콜사이트가 소유: process.exit · `::error::<tool>:` 접두 · 파일 I/O · optionality ·
//   envFrom 병합 모드(신규 생성 vs 멱등 push) · kustomization 생성(toYaml) vs 편집(addResource).
//   why는 접두 없는 사유 문구만 — 콜사이트가 fail(r.why)로 자기 접두를 붙인다.
// 에러 모드: 봉인 계약 위반 = { ok:false, why }. **malformed YAML은 parseYaml이 throw하고 그대로 전파**한다
//   (두 콜사이트가 오늘도 미포착 — 크래시 동작 보존. image-pin.parseDescriptor의 throw-전파 규약과 동일).
import { createHash } from "node:crypto";
import { parse as parseYaml } from "yaml";

export type SealedFacts = {
  keys: string[];      // 정렬된 encryptedData 키(콜사이트 산출물 보고용)
  checksum: string;    // sha256(bytes) 앞 16자 — podAnnotations["checksum/secrets"]
  bytes: string;       // 디스크에 기록할 바로 그 바이트(= raw). checksum과 한 값에서 나와 갈라질 수 없다(#299)
  secretName: string;  // <app>-secrets
  sealedFile: string;  // <app>-secrets.sealed.yaml
};

// UPPER_SNAKE 키 규약 — 두 콜사이트 공통(바이트 동일 정규식이었다).
const KEY_RE = /^[A-Z][A-Z0-9_]*$/;

// strict scope(봉인 계약 6번째 조항, sealed-wiring #04 / design-r1 R-2) — kubeseal은 이 어노테이션으로
// 복호화 범위를 넓힌다. namespace==="prod" 등호는 scope를 함의하지 않는다: 기대 name·namespace를 그대로
// 두고 scope만 넓힌 봉인본은 5검증을 전부 통과하면서 아무 이름·아무 NS에서 복호화된다(암호문 재사용).
// patch(sealedsecrets.bitnami.com/patch)는 scope가 아니라 patch 모드라 대상이 아니다(argocd extras 선례).
const SCOPE_KEYS = [
  "sealedsecrets.bitnami.com/namespace-wide",
  "sealedsecrets.bitnami.com/cluster-wide",
] as const;

// scope 확대 어노테이션(truthy)이 metadata·spec.template.metadata 어느 쪽에든 있으면 그 키를 반환.
// value가 truthy("true", 따옴표·대소문자·bare bool 무관)일 때만 실 위험 — false/미설정은 strict라 통과.
// 두 위치를 **독립 검사**한다(merge 시 한쪽 false가 다른 쪽 true를 가리는 false-negative 방지).
// 키는 **대소문자 무시** 매치 — check-app-deploy.sh 게이트가 `grep -i`라, 두 adapter의 정책을
// 일치시켜야 rule-of-two가 성립한다(한쪽만 대문자 키를 잡으면 발산).
function scopeViolationKey(doc: any): string | null {
  const maps = [doc?.metadata?.annotations, doc?.spec?.template?.metadata?.annotations];
  for (const annos of maps) {
    if (!annos || typeof annos !== "object") continue;
    for (const [k, v] of Object.entries(annos)) {
      const kl = k.toLowerCase();
      if (SCOPE_KEYS.some((s) => s === kl) && String(v).toLowerCase() === "true") return k;
    }
  }
  return null;
}

export function readSealed(raw: string, app: string):
  | { ok: true; facts: SealedFacts }
  | { ok: false; why: string } {
  const secretName = `${app}-secrets`;
  const doc = parseYaml(raw); // malformed YAML은 여기서 throw(콜사이트 outer 미포착 = 크래시 보존)
  if (doc?.kind !== "SealedSecret") return { ok: false, why: "sealed 파일이 kind: SealedSecret이 아니다" };
  if (doc?.metadata?.namespace !== "prod") return { ok: false, why: `sealed namespace는 prod여야 한다(strict-scope): ${doc?.metadata?.namespace}` };
  if (doc?.metadata?.name !== secretName) return { ok: false, why: `sealed name은 ${secretName}여야 한다: ${doc?.metadata?.name}` };
  const keys = Object.keys(doc?.spec?.encryptedData ?? {}).sort();
  if (keys.length === 0) return { ok: false, why: "sealed encryptedData가 비어 있다" };
  const badKeys = keys.filter((k) => !KEY_RE.test(k));
  if (badKeys.length) return { ok: false, why: `sealed encryptedData 키는 UPPER_SNAKE여야 한다: ${badKeys.join(", ")}` };
  const scopeKey = scopeViolationKey(doc);
  if (scopeKey) return { ok: false, why: `sealed scope 확대 어노테이션 금지(strict scope): ${scopeKey}=true — 이름/네임스페이스 격리가 붕괴돼 암호문이 다른 Secret으로 재사용될 수 있다. kubeseal 기본(strict)로 재봉인 필요` };
  // checksum과 bytes를 **한 값에서** 낸다 — 콜사이트가 반드시 facts.bytes를 디스크에 쓰므로
  // "해시한 것 ≠ 디스크에 쓴 것"이 구조적으로 불가능(#299 클래스 소멸).
  const checksum = createHash("sha256").update(raw).digest("hex").slice(0, 16);
  return { ok: true, facts: { keys, checksum, bytes: raw, secretName, sealedFile: `${secretName}.sealed.yaml` } };
}
