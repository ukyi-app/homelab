// 시작할 때 잡아 둔 내장 함수(T12-01b, 사용자 결정 2026-10-23). core의 시크릿 판정·출력·해석은 이것만 쓴다.
// 명령 모듈이 실수로 전역을 바꿔도(예: JSON.stringify를 덮는 도우미) core는 바뀌기 전 함수를 쓴다.
// 같은 프로세스에서 일부러 전역을 바꾸는 코드는 막지 않는다(설계 C.7 위협 모델: 명령 코드는 리뷰받은 저장소 코드다).
// main.ts가 맨 먼저 import한다. ES 모듈은 import 순서대로 평가되므로 등록 표의 명령 모듈보다 먼저 돈다(정적 시험).
const apply = Reflect.apply;
const strIncludesRaw = String.prototype.includes;

export const jsonParse: (text: string) => any = JSON.parse;
export const jsonStringify: (value: unknown) => string = JSON.stringify;
export const freeze = Object.freeze;
export const entries = Object.entries;
export const isArray = Array.isArray;
export const strIncludes = (s: string, part: string): boolean => apply(strIncludesRaw, s, [part]);
