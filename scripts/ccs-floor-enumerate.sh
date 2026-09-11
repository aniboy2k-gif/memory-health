#!/bin/zsh
# ccs-floor-enumerate.sh — 열거자 계약(emit 모드)의 구현 (CSR #2262 · 설계 r4 §1 «enumerator contract» · §5.2)
#
# ────────────────────────────────────────────────────────────────────────────
# 무엇을 내는가 — **마지막 줄**에 센티넬 하나
#   CCS_FLOOR_JSON {"floor":N,"file_count":N,"unreadable":N,"composition_sha":"…","realpaths":[…]}
#   읽는 쪽은 **마지막 센티넬 줄**만 취한다. `/etc/zshenv` 등이 앞에 뭘 찍어도 파싱이 깨지지 않는다.
#
# ★ 왜 이 파일이 게이트 안이 아니라 여기 있는가 (정직)
#   설계는 `check-context-size.sh` 가 emit 모드를 갖는 그림을 그렸다. 그 파일은 **다른 저장소
#   (da-system/da-tools)** 에 있고 이 작업에서 나는 그 저장소를 수정하지 않았다. 그래서 계약을
#   **어댑터**로 구현한다 — 게이트의 기존 모드(`--print-floor-realpaths`, 실측 존재 M12b)와
#   기존 출력(`hard_tokens=`)만 쓰고 게이트를 고치지 않는다. 계약의 소비자는 이 파일의 경로를
#   `CCS_ENUMERATOR` 로 바꿔 끼울 수 있다(픽스처).
#
# ★ 반드시 zsh — floor 열거가 zsh 전용이다. bash 로 부르면 게이트가 `exit 3` 으로 죽고
#   **빈 집합**이 나온다. 빈 집합의 지문은 어떤 구성 변화도 감지하지 못한다.
#   (shipped 선례: ccs-window-sha.sh:24-28 이 같은 이유로 bash 를 거부한다.)
#
# ★ `composition_sha` 의 정의는 **한 곳**이어야 한다
#   여기 계산식은 `ccs-window-sha.sh:33-43` 과 같은 조리법이다(정렬 · 개행 결합 · count-free).
#   같다는 것을 약속으로 두지 않고 **probe 로 단언**한다 — tests/test-ccs-window-close.sh 의
#   `composition_sha 동치` 케이스가 두 산출을 대조한다. 어긋나면 빨갛다.
#
# ★ 게이트 종료코드 해석 (실측)
#   0 = 측정됨·캡 이내 · 1 = 측정됨·하드캡 초과(:678) · 2 = gov 오배치 · 3 = 비-zsh.
#   **1 은 정상 측정**이다 — 초과를 측정불가로 취급하면 예산이 나쁠수록 핀을 못 만든다(역방향).
#
# 사용: zsh ccs-floor-enumerate.sh
# 종료: 0 = 센티넬 1줄 출력 · 3 = 측정 불가(센티넬 없음). 조용히 빈 값을 내지 않는다.
# ────────────────────────────────────────────────────────────────────────────
set -u

if [ -z "${ZSH_VERSION:-}" ]; then
  echo "ERROR: 본 스크립트는 zsh 전용입니다 — bash 에서는 floor 열거가 빈 집합이 됩니다." >&2
  exit 3
fi

GATE="${CCS_GATE:-$HOME/.claude/da-tools/check-context-size.sh}"
[ -r "$GATE" ] || { echo "ERROR: 게이트 부재: $GATE" >&2; exit 3 }

# ── ⑴ 멤버십 — realpath 목록 (NUL 구분) ────────────────────────────────────
typeset -a paths
paths=(${(0)"$(zsh "$GATE" --print-floor-realpaths 2>/dev/null)"})
paths=(${paths:#})
if (( ${#paths} == 0 )); then
  echo "ERROR: floor 열거가 비었습니다 — 빈 집합의 지문은 아무것도 감지하지 못합니다." >&2
  exit 3
fi
paths=(${(o)paths})

# ── ⑵ 읽을 수 없는 파일 수 ─────────────────────────────────────────────────
# 게이트는 이 수를 내지 않는다. 여기서 센다 — 계약이 `unreadable` 을 요구하고,
# `unreadable > 0` 은 **낮게 측정된 floor** 를 뜻하므로 fail-closed 대상이다.
integer unreadable=0
typeset p
for p in $paths; do [ -r "$p" ] || (( unreadable++ )); done

# ── ⑶ floor — 게이트 전체 실행의 `hard_tokens=` 줄 ─────────────────────────
typeset out rc
out="$(zsh "$GATE" 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  echo "ERROR: 게이트 실행 rc=$rc — 측정이 아니다." >&2
  exit 3
fi
typeset floor
floor="$(printf '%s\n' "$out" | /usr/bin/grep -E '^hard_tokens=' | head -1 | sed -E 's/^hard_tokens=([0-9]+).*/\1/')"
case "$floor" in
  ''|*[!0-9]*) echo "ERROR: hard_tokens 를 파싱하지 못했습니다." >&2; exit 3 ;;
esac
[ "$floor" -gt 0 ] || { echo "ERROR: floor 가 양의 정수가 아닙니다: $floor" >&2; exit 3 }

# ── ⑷ composition_sha — 정렬·개행결합·count-free (ccs-window-sha.sh 와 같은 조리법) ──
typeset csha
csha="$(print -rl -- $paths | shasum -a 256 | cut -d' ' -f1)"
[ -n "$csha" ] || { echo "ERROR: 지문 계산 실패" >&2; exit 3 }

# ── ⑸ 센티넬 — **마지막 줄** ───────────────────────────────────────────────
FLOOR="$floor" FC="${#paths}" UNREAD="$unreadable" CSHA="$csha" \
python3 - "${(@)paths}" <<'PY'
import json, os, sys
row = {
    "floor": int(os.environ["FLOOR"]),
    "file_count": int(os.environ["FC"]),
    "unreadable": int(os.environ["UNREAD"]),
    "composition_sha": os.environ["CSHA"],
    "realpaths": sys.argv[1:],
}
print("CCS_FLOOR_JSON " + json.dumps(row, ensure_ascii=False, sort_keys=True))
PY
exit 0
