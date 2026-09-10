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
#   ★ 의도적으로 좁다: 상수·제수·임계·토크나이저 본문만 덮는다. 그 밖의 의미 변화는 못 잡는다
#     (설계 R-5 로 명명됨). 넓혀서 게이트 전체를 해싱하면 주석 한 줄에도 핀이 무효화돼
#     운영자가 `ref_reason=metric` 을 무시하도록 훈련시킨다 — 그쪽이 더 나쁘다.
#
# 사용: zsh ccs-window-sha.sh {composition|metric|both}
# 종료: 0 성공 · 3 측정 불가(빈 열거·게이트 부재) — 조용히 빈 값을 내지 않는다
set -u

if [ -z "${ZSH_VERSION:-}" ]; then
  echo "ERROR: 본 스크립트는 zsh 전용입니다 — bash 에서는 floor 열거가 빈 집합이 되어" >&2
  echo "       어떤 구성 변화도 감지 못 하는 지문을 만들게 됩니다." >&2
  exit 3
fi

GATE="${CCS_GATE:-$HOME/.claude/da-tools/check-context-size.sh}"
[ -r "$GATE" ] || { echo "ERROR: 게이트 부재: $GATE" >&2; exit 3 }

_composition() {
  local -a paths
  paths=(${(0)"$(zsh "$GATE" --print-floor-realpaths 2>/dev/null)"})
  paths=(${paths:#})
  if (( ${#paths} == 0 )); then
    echo "ERROR: floor 열거가 비었습니다 — 빈 집합의 지문은 아무것도 감지하지 못합니다." >&2
    return 3
  fi
  # 정렬 후 개행 결합. 개수는 지문에 넣지 않는다(count-free).
  print -rl -- ${(o)paths} | shasum -a 256 | cut -d' ' -f1
}

_metric() {
  # 게이트 소스에서 측정 의미론만 뽑는다. 값이 아니라 **정의**를 해싱한다.
  {
    grep -E '^(PER_FILE_CAP_TOKENS|TOTAL_HARD_TOKENS|TOTAL_SOFT_TOKENS)=' "$GATE"
    grep -E '^(KO_THRESHOLD|KO_FACTOR_HARD|EN_FACTOR_HARD)=' "$GATE"
    # 토크나이저 본문 — `_tokens` 정의부. 없으면 그 사실 자체가 지문에 들어간다.
    awk '/^def _tokens\(/,/^$/' "$GATE" 2>/dev/null || true
  } | shasum -a 256 | cut -d' ' -f1
}

case "${1:-both}" in
  composition) _composition ;;
  metric)      _metric ;;
  both)        printf 'composition_sha=%s\n' "$(_composition)" || exit 3
               printf 'metric_sha=%s\n' "$(_metric)" ;;
  count)       # 진단 전용 — **단언에 쓰지 말 것**
               local -a p; p=(${(0)"$(zsh "$GATE" --print-floor-realpaths 2>/dev/null)"}); p=(${p:#})
               print -r -- ${#p} ;;
  *) echo "usage: ccs-window-sha.sh {composition|metric|both|count}" >&2; exit 2 ;;
esac
