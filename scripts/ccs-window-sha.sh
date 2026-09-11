#!/bin/zsh
# ccs-window-sha.sh — 창 핀의 두 지문을 계산한다 (CSR #2262 Action 1 / H-9)
#
# ★ 반드시 zsh — floor 열거(`--print-floor-realpaths`)가 zsh 전용이기 때문이다.
#   bash 로 부르면 게이트가 `exit 3` 으로 죽고 **빈 집합**이 나온다. 빈 집합의 sha 를 지문으로
#   삼으면 어떤 구성 변화도 감지하지 못한다 — 그래서 아래에서 **비어 있으면 실패**한다.
#
# composition_sha = 멤버십 — sha256( 정렬된 floor realpath 목록을 개행으로 이은 것 )
#   ★★ **count-free**. 설계 정본은 다섯 곳에서 "16 floor files" 라고 적었으나 실측은 **13**이다
#      (#2253 이 3파일을 조건부 로드로 옮겼고, 이 티켓 댓글 c#7774 가 이미 그 사실을 적어 두었다).
#      그래서 이 지문의 정의에 **개수를 넣지 않는다** — 어떤 고정 개수도 낡는다.
#      개수는 진단으로 **인쇄**할 수는 있어도 **동등성 단언**에 넣지 않는다.
#
# metric_sha = 측정 의미론 — 같은 13경로여도 제수·상수·토크나이저가 바뀌면 값이 통약 불가해진다.
#   멤버십 sha 는 "어느 파일인가"에 답하고, 이것은 "어떻게 쟀는가"에 답한다.
#   ★ 게이트 쪽은 여전히 좁다: 상수·제수·임계·게이트 안 토크나이저 정의부만 덮는다. 게이트 전체를
#     해싱하면 주석 한 줄에도 핀이 무효화돼 운영자가 `ref_reason=metric` 을 무시하도록 훈련시킨다.
#   ★ 그러나 **공유 모듈 `lib/ccs-tokenize.py` 는 전체 파일 sha256 으로 덮는다**(CSR #2273 (b), Q2).
#     이쪽만 넓힌 이유: 모듈의 산술이 바뀌어도 지문이 그대로면 핀이 "유효"라고 거짓 보고한다.
#     대가(모듈 주석 한 줄이 핀을 무효화)는 감수하되, 무효화와 고장을 구별할 수 있게
#     실패는 조용한 빈 값이 아니라 `CCS_METRIC_UNAVAILABLE reason=…` + rc 3 으로 낸다.
#
# 사용: zsh ccs-window-sha.sh {composition|metric|both}
# 종료: 0 성공 · 3 측정 불가(빈 열거 · 게이트 부재 · 게이트 토크나이저 앵커 부재 ·
#       모듈 판독 불가 · `CCS_TOKENIZER` 불일치 · **모듈 해싱 실패/부적격**(`tokenizer_hash_failed`) ·
#       **지문 해싱 실패/부적격**(`metric_hash_failed`)) — 조용히 빈 값을 내지 않는다
#   ★ 뒤 둘은 CSR #2288 에서 추가됐다. 그 전까지 `_metric` 의 두 다이제스트 지점은 실패를
#     전파하지 않았다(파이프라인 rc 는 최우측 명령의 것 — zsh PIPE_FAIL 기본 off).
#   ★ 범위 경고 — 이 열거는 `_metric` 에 대해서만 완전하다. `_composition()` 의 `shasum` 실패는
#     **여전히 rc 를 전파하지 않아** 이 목록에 없다(CSR #2288 범위 밖).
#     이 주석을 "스크립트 전체의 rc 3 전건"으로 읽지 말 것 — 그렇게 읽으면 이 주석 자신이
#     이 티켓이 고치는 부류의 거짓 문장이 된다.
#   ★ 위 `사용:`·`종료:` 두 줄은 `count` 서브커맨드와 rc 2(미지원 인자)를 빠뜨린다 — **기존 결함이며
#     이 티켓 범위 밖**이다. 완전하다고 읽지 말 것. (고치지 않고 이름만 댄다: 이 변경과 무관하다.)
#   ★ 이 파일의 주석에는 **줄번호를 쓰지 않는다**. 줄번호는 다음 편집 한 번에 조용히 거짓이 되고,
#     그것이 바로 이 티켓의 결함이다. 함수명·`reason=` 토큰으로 가리킨다.
set -u

if [ -z "${ZSH_VERSION:-}" ]; then
  echo "ERROR: 본 스크립트는 zsh 전용입니다 — bash 에서는 floor 열거가 빈 집합이 되어" >&2
  echo "       어떤 구성 변화도 감지 못 하는 지문을 만들게 됩니다." >&2
  exit 3
fi

GATE="${CCS_GATE:-$HOME/.claude/da-tools/check-context-size.sh}"
[ -r "$GATE" ] || { echo "ERROR: 게이트 부재: $GATE" >&2; exit 3 }

# H-4: 공유 토크나이저 모듈의 경로는 **게이트 위치에서 파생**한다(게이트 내부 `${0:A:h}` 와 같은 식).
#      환경변수가 아니라 파생이어야 하는 이유: metric_sha 는 게이트와 **다른 프로세스**에서 계산되므로,
#      각자 환경을 따로 읽으면 핀이 파일 X 를 증명하는데 게이트는 파일 Y 를 읽는 상태가 가능해진다.
_TOKENIZER_DERIVED="${GATE:A:h}/lib/ccs-tokenize.py"
# `CCS_TOKENIZER` 는 이 파일에 정의돼 있지 않았다(`set -u` 아래 참조하면 parameter not set).
# 이제 읽기는 하되 **확인형으로만** — 다른 파일을 가리키면 리다이렉트가 아니라 실패다.
if [ -n "${CCS_TOKENIZER:-}" ] && [ "${CCS_TOKENIZER:A}" != "${_TOKENIZER_DERIVED:A}" ]; then
  echo "CCS_METRIC_UNAVAILABLE reason=tokenizer_path_mismatch env=${CCS_TOKENIZER} derived=${_TOKENIZER_DERIVED}" >&2
  exit 3
fi

_composition() {
  local -a paths
  # LOW-3: 게이트의 rc 를 **명시적으로** 본다. 빈 열거라는 *부작용*에만 기대지 않는다
  #        (게이트가 exit 3 을 내는 경로가 늘어나므로, 계약 의존이 부작용 의존보다 낫다).
  paths=(${(0)"$(zsh "$GATE" --print-floor-realpaths 2>/dev/null)"}) || return 3
  paths=(${paths:#})
  if (( ${#paths} == 0 )); then
    echo "ERROR: floor 열거가 비었습니다 — 빈 집합의 지문은 아무것도 감지하지 못합니다." >&2
    return 3
  fi
  # 정렬 후 개행 결합. 개수는 지문에 넣지 않는다(count-free).
  print -rl -- ${(o)paths} | shasum -a 256 | cut -d' ' -f1
}

# ★ `case` 형태를 의도적으로 쓴다 — zsh 글롭 `[[ $1 == [0-9a-f](#c64) ]]` 는
#   `setopt extended_glob`(파일 전역 옵션 변경)을 요구한다. 1차 출처(zsh 매뉴얼 zshexpn):
#   "There are various flags which affect any text to their right … they require the
#   EXTENDED_GLOB option." 두 형태는 5종 입력에서 동일하다(실측).
_is_sha256() { case "$1" in (*[!0-9a-f]*) return 1;; esac; [ ${#1} -eq 64 ] }

_metric() {
  # 게이트 소스에서 측정 의미론을 뽑고, 거기에 **공유 모듈 전체의 sha256** 을 더해 해싱한다.
  # ★ `local` 과 대입을 **분리**해야 한다 — `local v="$(cmd)"` 는 `local` 의 rc 를 주므로
  #   아래 rc 포착이 통째로 무효가 된다(실측: 합친 형태 rc=0 / 분리 형태 rc=5).
  local _tok_body _mod_sha _sha_out _out _rc
  # 게이트 안 토크나이저 정의부. D1 이후 앵커(`_load_tokenizer`)를 먼저, 그 다음 D1 이전 앵커(`_tokens`).
  # ★ 이전 주석("없으면 그 사실 자체가 지문에 들어간다")은 **거짓이었다** — 실측상 패턴이 없으면
  #   awk 출력이 0바이트라 지문이 상수부만으로 조용히 줄어든다. 그래서 이제 **둘 다 없으면 멈춘다**.
  _tok_body="$(awk '/^def _load_tokenizer\(/,/^$/' "$GATE" 2>/dev/null)"
  [ -n "$_tok_body" ] || _tok_body="$(awk '/^def _tokens\(/,/^$/' "$GATE" 2>/dev/null)"
  if [ -z "$_tok_body" ]; then
    echo "CCS_METRIC_UNAVAILABLE reason=gate_loader_missing gate=$GATE" >&2
    return 3
  fi
  if [ ! -r "$_TOKENIZER_DERIVED" ]; then
    echo "CCS_METRIC_UNAVAILABLE reason=tokenizer_unreadable path=$_TOKENIZER_DERIVED" >&2
    return 3
  fi
  # ★ 파이프를 없앴다 — 생산자 rc 를 직접 본다(canon-A 조건 2 의 "pipeline safety" 절반).
  #   1차 출처(zsh 매뉴얼 Options/PIPE_FAIL, 기본 off): "the exit status … reflects that of the
  #   rightmost element of a pipeline" — 그래서 `"$(shasum … | cut …)" || return 3` 은 발동하지 않는다.
  _sha_out="$(shasum -a 256 "$_TOKENIZER_DERIVED")"; _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "CCS_METRIC_UNAVAILABLE reason=tokenizer_hash_failed path=$_TOKENIZER_DERIVED rc=$_rc" >&2
    return 3
  fi
  _mod_sha="${_sha_out%% *}"          # `cut -d' ' -f1` 과 동일 바이트
  if ! _is_sha256 "$_mod_sha"; then   # ★ "hash validation" 절반 — rc 포착으로는 못 잡는다
    echo "CCS_METRIC_UNAVAILABLE reason=tokenizer_hash_failed path=$_TOKENIZER_DERIVED" >&2
    return 3
  fi
  # ★ `pipefail` 은 치환 서브셸 안에만 건다 — 파일 전역 옵션이 아니므로 `_composition` 에 닿지 않는다
  #   (POSIX: 치환은 서브셸 환경에서 실행되고 "shall not remain in effect after the list finishes";
  #    실측: 안 rc=1 / 밖 rc=0 / 부모 옵션 미오염).
  #   파이프를 그대로 두는 이유: shasum 에 들어가는 바이트열이 변하면 metric_sha 가 회전해
  #   살아 있는 핀이 무효화된다(#2273 본문). 입력 스트림은 한 바이트도 건드리지 않는다.
  _sha_out="$( set -o pipefail; {
    grep -E '^(PER_FILE_CAP_TOKENS|TOTAL_HARD_TOKENS|TOTAL_SOFT_TOKENS)=' "$GATE"
    grep -E '^(KO_THRESHOLD|KO_FACTOR_HARD|EN_FACTOR_HARD)=' "$GATE"
    print -r -- "$_tok_body"
    print -r -- "$_mod_sha"          # ← (b): 공유 모듈 **전체**가 지문 안으로
  } | shasum -a 256 )"; _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "CCS_METRIC_UNAVAILABLE reason=metric_hash_failed rc=$_rc" >&2
    return 3
  fi
  _out="${_sha_out%% *}"
  if ! _is_sha256 "$_out"; then
    echo "CCS_METRIC_UNAVAILABLE reason=metric_hash_failed" >&2
    return 3
  fi
  print -r -- "$_out"
}

case "${1:-both}" in
  composition) _composition ;;
  metric)      _metric ;;
  both)        # ★ 기존 `printf … "$(_composition)" || exit 3` 은 **무효**였다 — 단순 명령에서 `$?` 는
               #   printf 의 상태이고 치환의 상태는 버려진다(실측: `rc_after=0`, `CAUGHT` 없음).
               #   rc 를 전파하는 형태는 변수 대입뿐이다(훅 `ccs-write-gate.sh:133` 과 같은 모양).
               _CSHA="$(_composition)" || exit 3
               _MSHA="$(_metric)"      || exit 3
               printf 'composition_sha=%s\n' "$_CSHA"
               printf 'metric_sha=%s\n'      "$_MSHA" ;;
  count)       # 진단 전용 — **단언에 쓰지 말 것**
               local -a p; p=(${(0)"$(zsh "$GATE" --print-floor-realpaths 2>/dev/null)"}); p=(${p:#})
               print -r -- ${#p} ;;
  *) echo "usage: ccs-window-sha.sh {composition|metric|both|count}" >&2; exit 2 ;;
esac
