// 시크릿 값은 이 객체로만 다닌다. 출력·argv·파일에 값을 두지 않는다(설계 C.7 "어떤 출력에도 시크릿 값이 없다").
// 문자열로 바뀌는 모든 길(toString, 템플릿 문자열, JSON.stringify, console의 inspect)은 값 대신 [secret]을 낸다.
// 그래도 원문이 다른 문자열에 섞일 수 있으므로(예: 실패한 자식의 stderr) 원문을 추적해 출력 계층이 마지막에 한 번 더 막는다.
const tracked = new Set<string>();
// 짧은 값(6자 미만)은 흔한 글자와 겹치므로 앞뒤가 영숫자가 아닐 때만 맞춘다. 그래도 길이 때문에 빼지는 않는다
// (#873 1라운드 P1: 짧은 앱 시크릿이 오류 출력으로 샜다). 겹치면 출력이 막힌다(새기보다 막는 쪽).
const shortTracked = new Set<string>();
const SHORT = 6;

// generatePassword는 엔진이 Step.apply()를 도는 동안만 허용한다(plan·read·재조회에서 부르면 실패).
let generationAllowed = false;

export class Secret {
  readonly #raw: string;

  constructor(raw: string) {
    this.#raw = raw;
    // 공백뿐인 값을 짧은 값으로 추적하면 줄바꿈이 있는 모든 출력이 막힌다. 그런 시크릿은 Infisical 쓰기도 거부한다.
    if (raw.trim().length === 0) return;
    const forms = [raw, JSON.stringify(raw).slice(1, -1), Buffer.from(raw).toString("base64")];
    // JSON 출력에서는 "·\ 등이 이스케이프된 꼴로, kubectl 출력에서는 Secret data의 base64 꼴로 나타난다.
    for (const f of forms) (f.length >= SHORT ? tracked : shortTracked).add(f);
  }

  // core 안에서만 쓴다(stdin 넘김, 해시). commands/에서 쓰면 정적 시험이 막는다.
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
  for (const raw of shortTracked) {
    const esc = raw.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    if (new RegExp(`(^|[^A-Za-z0-9])${esc}([^A-Za-z0-9]|$)`).test(text)) return true;
  }
  return false;
}

export function allowGeneration(on: boolean): void {
  generationAllowed = on;
}

const ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

// 영숫자만 쓴다(rotate.md 3c "32자 이상, 영숫자"). DATABASE_URL·.env 줄에 넣어도 이스케이프가 필요 없다.
export function generatePassword(length = 40): Secret {
  if (!generationAllowed) throw new Error("plan·읽기 모드에서 비밀번호를 만들려 했다(apply 안에서만 만든다)");
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
