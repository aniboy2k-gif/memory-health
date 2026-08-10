#!/usr/bin/env bash
# cap-boundary-probe.sh — MEMORY.md 캡의 '단위와 경계'를 행동으로 재확인한다 (CSR #1825)
#
# 왜 이 프로브가 필요한가:
#   캡 값을 문서·바이너리 문자열에서 읽는 것은 전부 **같은 축(문자열 읽기)** 이라 서로를 검증하지
#   못한다. CSR #1825 는 그 방식으로 "25KB → 25,600바이트" 라는 틀린 값을 2주간 확신했다.
#   실제 캡은 **200줄 OR 25,000문자**였고, 이 사실은 오직 행동 관측으로만 드러났다.
#   ⇒ 캡 상수를 재검증할 때는 `strings` 를 다시 읽지 말고 **이 프로브를 돌려라.**
#
# 원리:
#   스크래치 프로젝트 메모리의 맨 앞/맨 뒤에 카나리아를 심고 `claude -p` 로 무엇이 보이는지 묻는다.
#   꼬리 카나리아가 사라지면 = 그 크기에서 절단이 일어난 것.
#
# 사용법:
#   bash tests/cap-boundary-probe.sh            # 경계 2케이스 (기본)
#   bash tests/cap-boundary-probe.sh --astral   # 단위 판별(code point vs UTF-16) 1케이스 추가
#
# 정직 범위:
#   - `claude` CLI 와 네트워크가 필요하다. CI 무인 실행용이 아니라 **사람이 릴리스 시 돌리는 절차**다.
#   - 관측은 "모델이 꼬리 카나리아를 보고했는가" 이며, 절단이 아니라 주의 분산으로 못 볼 가능성은
#     0 이 아니다. 경계 직하/직상 쌍(24,900 / 25,100)이 함께 뒤집혀야만 절단으로 판정한다.

set -u

SLUG_DIR="$HOME/.claude/projects/-private-tmp-capprobe/memory"
WORK="/tmp/capprobe"
PROMPT='Look at your auto-memory MEMORY.md. Output ONLY the canary tokens you can actually see there, one per line. Nothing else.'
STASH="${TMPDIR:-/tmp}/capprobe-stash-$$"

mkdir -p "$SLUG_DIR" "$WORK"

cleanup() {
  mkdir -p "$STASH"
  [ -d "$HOME/.claude/projects/-private-tmp-capprobe" ] && \
    mv "$HOME/.claude/projects/-private-tmp-capprobe" "$STASH/" 2>/dev/null
  [ -d "$WORK" ] && mv "$WORK" "$STASH/" 2>/dev/null
  printf '\n정리: 프로브 산출물을 %s 로 이동했습니다(삭제 아님).\n' "$STASH"
}
trap cleanup EXIT

build() { # mode  target
  python3 - "$1" "$2" "$SLUG_DIR/MEMORY.md" <<'PY'
import sys
mode, target, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
head, tail = "CANARY_HEAD_7Q4Z\n", "CANARY_TAIL_9M2X\n"
budget = target - len(head) - len(tail)          # 채워야 할 code point 수
if mode == "astral":
    # astral(비-BMP) 문자는 code point 1개 = UTF-16 단위 2개.
    # target = code point 수 → UTF-16 단위는 약 2배가 된다.
    fill = "\U0001F7E2"       # 🟢 U+1F7E2
    per_line = 100
else:
    fill = "가나다라마바사아자차카타파하거너더러머버서어저처커터퍼허고노도로모보소오조초코토포호구누두루무부수우주추"
    per_line = 180
# ★ 목표 code point 수를 **정확히** 맞춘다. 줄 단위로 나눠 떨어뜨리면 목표에 미달해
#   "캡 직상" 케이스가 실제로는 캡 이하가 되어 프로브가 조용히 무효가 된다(CSR #1825 실측 실패).
body = (fill * ((budget // len(fill)) + 1))[:budget]
lines, i = [], 0
while i < len(body):
    chunk = body[i:i + per_line]
    i += per_line
    lines.append(chunk)
# 줄바꿈도 code point 1개다 → 줄바꿈 수만큼 본문에서 덜어낸다.
nl = len(lines)
if nl:
    body = body[:max(len(body) - nl, 0)]
    lines, i = [], 0
    while i < len(body):
        lines.append(body[i:i + per_line])
        i += per_line
with open(path, "w", encoding="utf-8") as f:
    f.write(head)
    for ln in lines:
        f.write(ln + "\n")
    f.write(tail)
PY
}

report() { # label
  python3 - "$SLUG_DIR/MEMORY.md" "$1" <<'PY'
import sys
path, label = sys.argv[1], sys.argv[2]
raw = open(path, "rb").read()
t = raw.decode("utf-8")
cp = len(t)
u16 = sum(2 if ord(c) > 0xFFFF else 1 for c in t)
print(f"───── {label}: {len(raw)}바이트 / 코드포인트 {cp} / UTF-16단위 {u16} / {t.count(chr(10))}줄")
PY
}

observe() {
  ( cd "$WORK" && timeout 180 claude -p "$PROMPT" 2>/dev/null )
}

verdict() { # out
  if printf '%s' "$1" | grep -q 'CANARY_TAIL_9M2X'; then printf 'TAIL=보임(로드됨)'; else printf 'TAIL=사라짐(절단)'; fi
}

echo "════════ 캡 경계 프로브 ════════"
for t in 24900 25100; do
  build bmp "$t"
  report "$t 문자"
  out="$(observe)"
  printf '      %s\n' "$(verdict "$out")"
done
echo "  기대: 24,900 = 로드 / 25,100 = 절단  → 문자 캡 25,000 확인"

if [ "${1:-}" = "--astral" ]; then
  echo ""
  echo "════════ 단위 판별 (code point vs UTF-16 code unit) ════════"
  # 코드포인트는 캡 이하, UTF-16 단위는 캡 초과가 되도록 구성한다.
  build astral 13000
  report "astral"
  out="$(observe)"
  printf '      %s\n' "$(verdict "$out")"
  echo "  해석: 절단되면 캡 단위 = UTF-16 code unit / 로드되면 캡 단위 = code point"
fi
