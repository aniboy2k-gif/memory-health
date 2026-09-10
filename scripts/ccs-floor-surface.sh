#!/bin/bash
# ccs-floor-surface.sh — 자동로드 예산 floor 를 **기존 SessionStart 채널**에 한 줄로 표면화한다.
#
# CSR #2262 Action 1. 설계 정본 da #1049 §10 · 착지 설계 da #1054 · grounding #696.
#
# ────────────────────────────────────────────────────────────────────────────
# 이 파일이 존재하는 이유 (한 문단)
#   게이트는 26일간 903회 돌며 숫자를 계산했고 **사람 눈에 닿은 것은 2회(0.2%)** 였다. 결함은
#   "advisory 통제가 실패한다" 가 아니라 **"계속 계산되는 신호에 수신자가 없다"** 였다.
#   그래서 이 파일은 새 hook 을 만들지 않는다 — **이미 등록·작동 중인** SessionStart 채널
#   (`hooks/memory-line-check.sh` → `skills/memory-health/scripts/memory-line-check.sh`)에
#   한 줄을 얹는다. `settings.json` 은 **건드리지 않는다**(16번째 hook 신설 아님).
#
# ★ 출력 계약: **정확히 한 줄** (정본 §10.4). 그 한 줄의 바이트 길이를 관측행에 기록한다(§10.5) —
#   주입 컨텍스트는 게이트가 셀 수 없는 비용이므로, 최소한 **보이게는** 만든다.
#
# ★ floor 를 어디서 읽는가 — 그리고 왜 여기서 게이트를 돌리지 않는가
#   정본 §10.4: 캐시에서 읽고 **인라인 재계산은 하지 않는다**. 캐시 = 게이트가 매 실행 남기는
#   `context-budget-audit.jsonl` 의 최신 `kind=measurement` 행이다.
#   ★★ 그 행의 provenance 가 `zsh` 인 것은 **구조적으로 보증된다** — 게이트는 non-zsh 에서
#      어떤 출력·기록보다 먼저 `exit 3` 으로 죽는다(check-context-size.sh:16-21). 따라서 원장에
#      행이 있다는 사실 자체가 그 측정이 zsh 산이라는 뜻이다. 이것이 핀 하향의 provenance
#      가드(C-6/H-7)를 만족시키는 근거이며, 우리가 별도로 표시를 심을 필요가 없는 이유다.
#
# ★ 알려진 한계 — 숨기지 않고 적는다
#   게이트는 `ok` 대역에서 **원장 행을 아예 쓰지 않는다**(append 호출 지점이 :655·:668 둘뿐).
#   즉 예산이 좋아질수록 캐시가 낡는다. 그래서 아래는 캐시 나이를 재서 TTL 을 넘으면
#   **핀을 내리지 않고** 그 사실을 적는다(낡은 측정으로 래칫을 돌리지 않는다).
#   ⚠ 이 침묵의 근본 수리는 게이트 `ok` 분기에 원장 append 한 줄을 더하는 것이고, 그것은
#     **stdout 을 바꾸지 않는다**(append 와 `ccs_run=` echo 는 별개 호출이라 실측 확인).
#     `#2035` 부수결함 6 소관이며 이 티켓의 범위 밖이라 **하지 않았다**.
#
# ★ 정직 범위
#   이 파일은 **표면화**이지 집행이 아니다. 한 줄을 읽는 사람이 무엇을 할지는 강제하지 않는다.
#   #1961 계승: 이것이 만드는 것은 **부재의 관측 가능성**이지 품질 보증이 아니다.
#
# 계약: 항상 exit 0 (SessionStart 를 절대 막지 않는다) · stdout 은 0줄 또는 **정확히 1줄**
# ────────────────────────────────────────────────────────────────────────────
set -u

_SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CONST_FILE="${MEMORY_HEALTH_CONSTANTS:-${_SELF_DIR}/../cap-constants.env}"
LEDGER="${CCS_LEDGER_FILE:-$HOME/.claude/da-tools/context-budget-audit.jsonl}"
GATE_ARTIFACTS="${CCS_GATE_ARTIFACTS_DIR:-$HOME/.claude/gate-artifacts}"
PIN="${CCS_PIN_FILE:-$GATE_ARTIFACTS/ccs-window.start}"
PIN_SH="${CCS_PIN_SH:-$_SELF_DIR/ccs-window-pin.sh}"
SESSIONS_ROOT="${CCS_WINDOW_SESSIONS_DIR:-$GATE_ARTIFACTS/ccs-window.sessions}"
OBS_HELPER="${CCS_AUDIT_APPEND:-$HOME/.claude/scripts/append-audit-event.sh}"

# 상수는 source 하지 않는다(외부 파일의 코드 실행 회피). 정수만 허용, 실패 시 내장값.
read_const() {
  ck_key="$1"; ck_def="$2"; ck_val=""
  if [ -r "$CONST_FILE" ]; then
    ck_val="$(grep -E "^${ck_key}=" "$CONST_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')"
  fi
  case "$ck_val" in
    '' | *[!0-9]*) printf '%s' "$ck_def" ;;
    *)             printf '%s' "$ck_val" ;;
  esac
}

FLOOR_HARD_CAP="$(read_const FLOOR_HARD_CAP 30000)"
FLOOR_SOFT="$(read_const FLOOR_SOFT 27000)"
FLOOR_CACHE_TTL_MIN="$(read_const FLOOR_CACHE_TTL_MIN 60)"

# ── 캐시 읽기 (인라인 재계산 없음) ──────────────────────────────────────────
# 최신 measurement 행에서 floor·ts 를 꺼낸다. 실패는 전부 "미상" 으로 흡수한다.
CACHE="$(LEDGER="$LEDGER" python3 - <<'PY' 2>/dev/null || true
import io, json, os, sys
from datetime import datetime, timezone
p = os.environ.get('LEDGER', '')
if not p or not os.path.isfile(p):
    print(''); raise SystemExit(0)
last = None
try:
    with io.open(p, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line or '"measurement"' not in line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue          # 손상 줄은 건너뛴다 — 조용히 실패하지 않고 무시만 한다
            if r.get('kind') == 'measurement' and isinstance(r.get('floor'), int):
                last = r
except OSError:
    print(''); raise SystemExit(0)
if not last:
    print(''); raise SystemExit(0)
age = ''
try:
    t = datetime.strptime(last['ts'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    age = str(int((datetime.now(timezone.utc) - t).total_seconds() // 60))
except Exception:
    age = ''
print('%s|%s|%s' % (last['floor'], age, last.get('state', '')))
PY
)"

FLOOR=""; AGE_MIN=""; STATE=""
if [ -n "$CACHE" ]; then
  FLOOR="${CACHE%%|*}"; _rest="${CACHE#*|}"; AGE_MIN="${_rest%%|*}"; STATE="${_rest#*|}"
fi

# ── 세션 등록 (directory-per-key — 잠금 불요·멱등) ──────────────────────────
# 근거: hooks/lib/session-ledger.sh:30 "STORE = directory-per-OID … presence=test -e."
# ★ source=env 만 계수한다. 같은 cwd 를 쓰는 두 세션이 hint 를 공유해 **충돌**할 수 있기 때문이다
#   (session-ledger.sh:18-20). 과소계수 방향 = 창이 더 **오래** 열림(짧아지지 않음)이고,
#   14일 상한이 무조건 종료시키므로 창이 불멸이 되지는 않는다. 보수적 방향이라 택했다.
SID="${CLAUDE_CODE_SESSION_ID:-}"
SID_SRC="env"
[ -n "$SID" ] || { SID=""; SID_SRC="none"; }

WINDOW_ID=""
SESSION_COUNT=""
PIN_NOTE=""

if [ -r "$PIN" ]; then
  WINDOW_ID="$(bash "$PIN_SH" read "$PIN" window_id 2>/dev/null)"
fi

if [ -n "$WINDOW_ID" ]; then
  if [ -n "$SID" ]; then
    mkdir -p "$SESSIONS_ROOT/$WINDOW_ID/$SID" 2>/dev/null || true
  else
    PIN_NOTE="session_count_skipped=$SID_SRC"
  fi
  SESSION_COUNT="$(find "$SESSIONS_ROOT/$WINDOW_ID" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
fi

# ── 핀 하향 (평가 후 하향 — C-4 순서 증명) ──────────────────────────────────
# ★ 순서가 고정이다: 되돌릴 조건을 **먼저** 평가하고 **그 다음에** 내린다.
#   내림은 floor < pin 일 때만 일어나므로 어느 순서든 판정은 같다(증명은 설계 C-4).
#   결정성을 위해 순서를 못박는다.
# ── C-3 「단일 값, 두 소비자」 — 규칙을 여기 두지 않고 **공유 해소기**를 부른다 ──────
#
# ★ 착지 감사(CSR #2262)가 잡은 결함: 구 판은 `window_id` 가 비어 있지 않으면
#   `floor_min_observed` 를 그대로 REFERENCE 로 썼다 — **두 sha 도 창 경계도 검사하지 않았다.**
#   그래서 같은 무효 핀에 대해 이 소비자는 `ref_leg=2 ref_stale=0`(거짓 건강 신호)을,
#   write 게이트는 `ref_leg=3 ref_stale=1 ref_reason=composition` 을 냈다(픽스처 실증).
#   중대한 이유: 설계 §10 의 **되돌릴 조건이 아래 관측행의 그 두 필드에 결박**돼 있어,
#   무조건 2/0 을 쓰는 소비자는 그 조건을 **구조적으로 발동 불가능**하게 만든다.
#
# ★ sha 를 못 구하면(비-zsh·게이트 부재) 빈 값이 되어 해소기가 불일치로 판정한다 —
#   즉 **검증 못 하면 유효하다고 주장하지 않는다**(엄격한 방향).
RESOLVER="${CCS_REFERENCE_RESOLVER:-$_SELF_DIR/ccs-reference-resolve.py}"
SHA_SH="${CCS_WINDOW_SHA_SH:-$_SELF_DIR/ccs-window-sha.sh}"

REFERENCE=""; REF_LEG=3; REF_STALE=1; REF_REASON="pin_absent"
if [ -r "$PIN" ] && [ -r "$RESOLVER" ] && [ -n "$FLOOR" ]; then
  _CSHA="$(zsh "$SHA_SH" composition 2>/dev/null)" || _CSHA=""
  _MSHA="$(zsh "$SHA_SH" metric 2>/dev/null)" || _MSHA=""
  _RES="$(python3 "$RESOLVER" "$PIN" "$FLOOR" "$FLOOR_HARD_CAP" \
            "$_CSHA" "$_MSHA" "$SESSIONS_ROOT" 2>/dev/null)" || _RES=""
  if [ -n "$_RES" ]; then
    REFERENCE="${_RES%%|*}"; _r="${_RES#*|}"
    REF_LEG="${_r%%|*}";     _r="${_r#*|}"
    REF_STALE="${_r%%|*}";   REF_REASON="${_r#*|}"
    # leg 3 은 "참조가 current_floor 로 떨어졌다" 는 뜻이다 — 화면에는 그 사실을 보인다.
    [ "$REF_LEG" = "3" ] && PIN_NOTE="${PIN_NOTE:+$PIN_NOTE }ref_stale=${REF_REASON:-unknown}"
  fi
fi

if [ -n "$FLOOR" ] && [ -n "$AGE_MIN" ] && [ -n "$WINDOW_ID" ]; then
  if [ "$AGE_MIN" -le "$FLOOR_CACHE_TTL_MIN" ] 2>/dev/null; then
    # 원장에 행이 있다는 것이 곧 zsh 산 측정이라는 뜻이다(위 헤더 근거).
    _OUT="$(CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" lower "$PIN" "$FLOOR" zsh 2>&1)" || true
    case "$_OUT" in
      pin_lower_refused=*) PIN_NOTE="${PIN_NOTE:+$PIN_NOTE }${_OUT}" ;;
    esac
  else
    PIN_NOTE="${PIN_NOTE:+$PIN_NOTE }pin_lower_refused=cache_stale:${AGE_MIN}m"
  fi
fi

# ── M-g: 지속 측정불가 latch (파생 — 쓰기 경로가 카운터를 올리지 않는다) ─────
# 설계 v4 §5 M-g. write 게이트가 연달아 측정에 실패하면 그 통제는 기능적으로 비보호 상태인데
# 개별 결정은 저마다 정당하다("허용했고 사유도 남겼다"). 행 하나하나는 텔레메트리이지 건강이
# 아니다. 그래서 **여기서** 그 행들을 읽어 유도한다.
# ★ 두 번째 줄을 만들지 않는다 — 아래 한 줄 안의 **필드**로만 얹는다(정본 §10.4 한 줄 상한).
DEGRADED=0; DEGRADED_SINCE=""; DEGRADED_RUN=0
if [ -r "$_SELF_DIR/ccs-degraded-latch.py" ]; then
  _MG="$(LEDGER="$LEDGER" python3 "$_SELF_DIR/ccs-degraded-latch.py" 2>/dev/null)" || _MG="0||0"
  DEGRADED="${_MG%%|*}"; _rest2="${_MG#*|}"
  DEGRADED_SINCE="${_rest2%%|*}"; DEGRADED_RUN="${_rest2#*|}"
  case "$DEGRADED" in 0|1) ;; *) DEGRADED=0 ;; esac
fi

# ── 표면화 줄을 **먼저 조립한다** (관측행에 그 바이트 길이를 싣기 위해) ─────
# 정본 §10.5: 게이트는 파일을 센다. SessionStart stdout 은 **진짜 주입 컨텍스트인데 계측기가
#   셀 수 없다**. 그 비용을 없앨 수는 없으므로 최소한 **보이게** 만든다 — 이 한 줄의 바이트
#   길이를 관측행에 싣는다. 그래서 줄 조립이 행 기록보다 앞에 온다.
if [ -z "$FLOOR" ]; then
  LINE="CCS_FLOOR: 미상(캐시 없음) — 자동로드 예산을 읽지 못했습니다. 확인: zsh ~/.claude/da-tools/check-context-size.sh"
else
  HEADROOM=$(( FLOOR_HARD_CAP - FLOOR ))
  SUFFIX=""
  [ -n "$AGE_MIN" ] && [ "$AGE_MIN" -gt "$FLOOR_CACHE_TTL_MIN" ] 2>/dev/null && SUFFIX=" (캐시 ${AGE_MIN}분 전)"
  [ -n "$REFERENCE" ] && SUFFIX="$SUFFIX ref=$REFERENCE"
  [ -n "$SESSION_COUNT" ] && SUFFIX="$SUFFIX 창세션=$SESSION_COUNT/20"
  # M-g — 같은 줄 안의 필드. 정상일 때는 아무것도 붙이지 않는다(조용한 성공).
  [ "$DEGRADED" = "1" ] && SUFFIX="$SUFFIX ⚠write게이트측정불가=${DEGRADED_RUN}연속"
  [ -n "$PIN_NOTE" ] && SUFFIX="$SUFFIX [$PIN_NOTE]"
  if [ "$FLOOR" -gt "$FLOOR_HARD_CAP" ] 2>/dev/null; then
    LINE="CCS_FLOOR: ${FLOOR} — 하드캡 ${FLOOR_HARD_CAP} 초과 ${HEADROOM#-}${SUFFIX}"
  elif [ "$FLOOR" -gt "$FLOOR_SOFT" ] 2>/dev/null; then
    LINE="CCS_FLOOR: ${FLOOR} — 하드캡까지 ${HEADROOM}${SUFFIX}"
  else
    LINE="CCS_FLOOR: ${FLOOR} — 캡 이내(여유 ${HEADROOM})${SUFFIX}"
  fi
fi
LINE_BYTES=$(printf '%s\n' "$LINE" | wc -c | tr -d ' ')

# ── 관측행 (C-4: 되돌릴 조건의 유일한 정직한 반송자) ────────────────────────
# ★ 직접 `>>` 로 쓰지 않는다 — 444 모드 감사 로그는 직접 append 를 **조용히 삼킨다**
#   (rules/hook-troubleshooting 사고 4). 헬퍼가 잠금·모드 복원까지 한다.
if [ -x "$OBS_HELPER" ] && [ -n "$FLOOR" ]; then
  ROW="$(TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" FLOOR="$FLOOR" REF="${REFERENCE:-}" \
        REFLEG="${REF_LEG:-3}" REFSTALE="${REF_STALE:-1}" REFREASON="${REF_REASON:-}" \
        WID="${WINDOW_ID:-}" SC="${SESSION_COUNT:-}" SID="$SID" SIDSRC="$SID_SRC" \
        LB="${LINE_BYTES:-}" DEG="${DEGRADED:-0}" DEGSINCE="${DEGRADED_SINCE:-}" \
        DEGRUN="${DEGRADED_RUN:-0}" \
        AGE="${AGE_MIN:-}" NOTE="${PIN_NOTE:-}" STATE="${STATE:-}" python3 - <<'PY' 2>/dev/null
import json, os
row = {
    "kind": "window_observation", "row_schema_version": 1,
    "ts": os.environ["TS"], "src": "ccs-floor-surface",
    "floor": int(os.environ["FLOOR"]),
    "gate_state": os.environ.get("STATE") or None,
    "cache_age_min": int(os.environ["AGE"]) if os.environ.get("AGE","").isdigit() else None,
    # ★ 이 세 필드는 **공유 해소기**(ccs-reference-resolve.py)가 낸 값을 그대로 싣는다.
    #   구 판은 `2 if REF.isdigit() else 3` — 즉 "핀 파일을 읽을 수 있었나" 하나로만 정했고,
    #   composition·metric·창 경계 셋 다 검사하지 않았다. 설계 §10 의 되돌릴 조건이 바로
    #   이 두 필드에 결박돼 있으므로, 그 규칙은 자신이 명명한 실패모드를 보고할 수 없었다.
    "reference": int(os.environ["REF"]) if os.environ.get("REF","").isdigit() else None,
    "ref_leg": int(os.environ["REFLEG"]) if os.environ.get("REFLEG","").isdigit() else 3,
    "ref_stale": int(os.environ["REFSTALE"]) if os.environ.get("REFSTALE","").isdigit() else 1,
    "ref_reason": os.environ.get("REFREASON") or None,
    "window_id": os.environ.get("WID") or None,
    "session_id": os.environ.get("SID") or None,
    "session_id_source": os.environ.get("SIDSRC") or None,
    "session_count": int(os.environ["SC"]) if os.environ.get("SC","").isdigit() else None,
    "note": os.environ.get("NOTE") or None,
    # 정본 §10.5 — 계측기가 못 세는 주입 비용을 최소한 보이게 만든다.
    "injected_line_bytes": int(os.environ["LB"]) if os.environ.get("LB","").isdigit() else None,
    # 설계 v4 §5 M-g — 파생 latch. 이 값은 쓰기 경로가 아니라 여기서 만들어진다.
    "degraded": 1 if os.environ.get("DEG") == "1" else 0,
    "degraded_since": os.environ.get("DEGSINCE") or None,
    "degraded_run": int(os.environ["DEGRUN"]) if os.environ.get("DEGRUN","").isdigit() else 0,
}
print(json.dumps(row, ensure_ascii=False, sort_keys=True))
PY
)"
  [ -n "$ROW" ] && printf '%s\n' "$ROW" | AUDIT_LOG="$LEDGER" "$OBS_HELPER" >/dev/null 2>&1 || true
fi

# ── 표면화: 정확히 한 줄 ────────────────────────────────────────────────────
# 줄은 위에서 이미 조립됐다(바이트 길이를 관측행에 싣기 위해). 여기서는 인쇄만 한다.
printf '%s\n' "$LINE"
exit 0
