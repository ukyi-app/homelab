// 배포 핀(deployment pin) 형식 커널 — CONTEXT.md 용어 준수(인라인 핀·descriptor·autoDeploy).
// 순수 함수만 둔다: 파일 I/O·YAML 변이·traversal 가드·TOCTOU·에러 문구·process.exit는 전부
// 콜사이트(poll-ghcr/bump-tag/create-app) 소유다 — 이 커널은 "형식 판정과 왕복"만 안다.
//
// SSOT: 배포 핀 tag/digest 정규식과 인라인 핀 파싱을 여기 한 곳에서만 정의한다. 콜사이트마다
// 정규식이 갈리면 apps 레인과 베스포크 레인이 서로 다른 형식 경계를 갖는 오배포 표면이 생긴다.
const TAG_BODY = String.raw`sha-[0-9a-f]{7,40}`;
const DIGEST_BODY = String.raw`sha256:[0-9a-f]{64}`;

// 배포 핀 tag 형식: `sha-` + 7..40 소문자 hex. 앵커(^…$) 완전일치 — 대문자·길이초과·부분일치 거부.
export const TAG_RE = new RegExp(`^${TAG_BODY}$`);
// 배포 핀 digest 형식: `sha256:` + 정확히 64 소문자 hex. 앵커 완전일치 — 63/65·대문자 거부.
export const DIGEST_RE = new RegExp(`^${DIGEST_BODY}$`);

export type InlinePin = { repo: string; tag: string; digest: string };
// 인라인 핀 스칼라 `<repo>:<tag>@<digest>`. repo는 non-greedy(.+?)라 마지막 `:sha-` 경계에서
// 끊긴다 — 포트 포함 repo(reg.io:443/…)도 앵커($)가 tag/digest 꼬리를 강제해 콜론을 보존한다.
const INLINE_RE = new RegExp(`^(.+?):(${TAG_BODY})@(${DIGEST_BODY})$`);

// 인라인 핀 파싱. 에러 모드: 형식 불량 = **null**(throw 금지). 콜사이트가 정책을 각자 소유한다 —
//   poll-ghcr는 null을 refuse 사유로, bump-tag는 exit 2로 처리(커널이 exit/문구를 결정하지 않는다).
export function parseInlinePin(scalar: string): InlinePin | null {
  const m = INLINE_RE.exec(scalar);
  if (!m) return null;
  const [, repo, tag, digest] = m;
  return { repo, tag, digest };
}

// parseInlinePin의 역함수. 불변식(왕복 항등): 정준 스칼라 s에 대해
//   formatInlinePin(parseInlinePin(s)!) === s. 정규화·검증 없음(콜사이트가 이미 정준 보장).
export function formatInlinePin(pin: InlinePin): string {
  return `${pin.repo}:${pin.tag}@${pin.digest}`;
}

export type PinDescriptor = { file: string; path: (string | number)[]; autoDeploy?: unknown };
// descriptor(.image-pin.json) 파싱 — JSON.parse + 타입 캐스트뿐, 정규화 0.
//   에러 모드: 불량 JSON은 JSON.parse가 **throw**하고 그대로 전파(콜사이트 outer catch가 refuse로
//   흡수). throw 지점·필드 접근을 콜사이트의 기존 인라인 JSON.parse와 바이트 동일하게 유지한다.
export function parseDescriptor(raw: string): PinDescriptor {
  return JSON.parse(raw) as PinDescriptor;
}

// autoDeploy 승인 정책 원자 — fail-closed. 불변식: 정확히 boolean true만 true를 반환한다.
//   false·누락·null·undefined·비불린은 전부 false(수동 승인). null-안전(d?.autoDeploy === true).
//   apps 레인(.bindings.json)과 베스포크 레인(descriptor)이 이 한 함수를 공유해 해석을 일치시킨다.
export function descriptorAutoDeploy(d: { autoDeploy?: unknown } | null | undefined): boolean {
  return d?.autoDeploy === true;
}
