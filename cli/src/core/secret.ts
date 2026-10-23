// 시크릿 값은 이 객체로만 다닌다. 출력·argv·파일에 값을 두지 않는다(설계 C.7 "어떤 출력에도 시크릿 값이 없다").
// 문자열로 바뀌는 모든 길(toString, 템플릿 문자열, JSON.stringify, console의 inspect)은 값 대신 [secret]을 낸다.
// 명령은 이 모듈을 import할 수 없다(정적 시험). Secret은 core 어댑터가 만들고 명령은 불투명하게 넘기기만 한다.
//
// 원문 추적(출력·argv의 마지막 방어선)은 16자 이상만 한다. 사용자 결정(2026-10-23, #873 3라운드): 짧은 값을 추적하면
// 고정 옵션(--expand=false)·JSON 키("mode")와 겹쳐 정상 출력이 깨지고, 경계 조건으로 줄이면 붙은 원문이 샌다.
// 대신 시크릿 입력은 16자 이상만 받고(MIN_SECRET), 기존의 짧은 값은 Secret 객체로만 들고 출력에 오지 않는 구조로 막는다.
export const MIN_SECRET = 16;

const tracked = new Set<string>();

export class Secret {
  readonly #raw: string;

  constructor(raw: string) {
    this.#raw = raw;
    if (raw.length < MIN_SECRET) return;
    // JSON 출력에서는 "·\ 등이 이스케이프된 꼴로, kubectl 출력에서는 Secret data의 base64 꼴로 나타난다.
    for (const f of [raw, JSON.stringify(raw).slice(1, -1), Buffer.from(raw).toString("base64")]) tracked.add(f);
  }

  // core 안에서만 쓴다(stdin 넘김, 해시).
  reveal(): string {
    return this.#raw;
  }

  get length(): number {
    return this.#raw.length;
  }

  // 같은지 볼 때 쓰는 해시 앞부분. rotate.md의 `sha256sum | cut -c1-12`와 같은 길이.
  sha256Prefix(n = 12): string {
    return new Bun.CryptoHasher("sha256").update(this.#raw).digest("hex").slice(0, n);
  }

  equals(other: Secret): boolean {
    return this.#raw === other.#raw;
  }

  toString(): string {
    return "[secret]";
  }

  toJSON(): string {
    return "[secret]";
  }

  [Symbol.for("nodejs.util.inspect.custom")](): string {
    return "[secret]";
  }
}

export function isSecret(x: unknown): x is Secret {
  return x instanceof Secret;
}

// 추적 중인 원문이 text에 들어 있는지. 출력과 argv 검사에 쓴다.
export function containsTracked(text: string): boolean {
  for (const raw of tracked) if (text.includes(raw)) return true;
  return false;
}

const ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

// 영숫자만 쓴다(rotate.md 3c "32자 이상, 영숫자"). DATABASE_URL·.env 줄에 넣어도 이스케이프가 필요 없다.
// 부르는 곳은 runtime.ts의 쓰기 문맥 하나다(정적 시험). 명령은 apply 안에서 w.generatePassword()로만 얻는다.
export function newPassword(length = 40): Secret {
  // 62의 배수 아래 값만 써 치우침을 없앤다.
  const limit = 256 - (256 % ALNUM.length);
  let out = "";
  while (out.length < length) {
    for (const b of crypto.getRandomValues(new Uint8Array(length * 2))) {
      if (b < limit && out.length < length) out += ALNUM[b % ALNUM.length];
    }
  }
  return new Secret(out);
}
