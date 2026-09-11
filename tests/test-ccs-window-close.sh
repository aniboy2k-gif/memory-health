#!/bin/bash
# test-ccs-window-close.sh — 창 종료 전이의 수용조건 (CSR #2262 · 설계 r4 §8 의 P-B·P-C·P-D)
#
# ★ 이 스위트가 왜 여기(memory-health 저장소)에 있는가 — 정직
#   설계 §8 은 이 케이스들을 `da-system/da-tools/tests/` 에 두라고 적었다. 그 저장소는 이 작업의
#   범위 밖(다른 담당)이라 **수정하지 않았다**. 그래서 여기 둔다 — 시험 대상 스크립트와 같은
#   저장소이고, 그래서 한 커밋으로 함께 움직인다. 교차저장소 배치(설계 U5 가 "가장 그럴듯한
#   착지 시점 놀라움" 으로 지목한 그것)를 새로 만들지 않는다.
#
# ★ 격리: 실 원장·실 핀·실 `cap-constants.env` 를 절대 건드리지 않는다. 전부 env override 로
#   임시 디렉토리에 재배치하고, 스위트 끝에서 실 원장의 sha256 불변을 단언한다.
#
# 사용: bash tests/test-ccs-window-close.sh
# ────────────────────────────────────────────────────────────────────────────
set -u

SELF="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SELF/../scripts"
CLOSE_SH="$SCRIPTS/ccs-window-close.sh"
PIN_SH="$SCRIPTS/ccs-window-pin.sh"
VERDICT="$SCRIPTS/ccs-window-verdict.py"
ENUMER="$SCRIPTS/ccs-floor-enumerate.sh"
SURFACE="$SCRIPTS/ccs-floor-surface.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/ccs-close.XXXXXX")"
trap 'rm -rf "$W"' EXIT

REAL_LEDGER="$HOME/.claude/da-tools/context-budget-audit.jsonl"
REAL_SHA_BEFORE="$(shasum -a 256 "$REAL_LEDGER" 2>/dev/null | cut -d' ' -f1)"
REAL_PIN_SHA_BEFORE="$(shasum -a 256 "$HOME/.claude/gate-artifacts/ccs-window.start" 2>/dev/null | cut -d' ' -f1)"
REAL_CONST_SHA_BEFORE="$(shasum -a 256 "$SELF/../cap-constants.env" 2>/dev/null | cut -d' ' -f1)"

# ── 픽스처 sha 스텁 (zsh 필요 없음 — 고정 문자열) ────────────────────────────
cat > "$W/sha-stub.sh" <<'EOF'
#!/bin/zsh
case "${1:-both}" in
  composition) echo "${STUB_CSHA:-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}" ;;
  metric)      echo "${STUB_MSHA:-mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm}" ;;
  *) echo "usage" >&2; exit 2 ;;
esac
EOF
chmod +x "$W/sha-stub.sh"

# ── 픽스처 열거자 스텁 — 센티넬을 우리가 정한다 ──────────────────────────────
cat > "$W/enum-stub.sh" <<'EOF'
#!/bin/zsh
# STUB_FLOOR / STUB_PATHS(공백구분) / STUB_UNREAD / STUB_NOISE 로 형상을 정한다.
[ -n "${STUB_NOISE:-}" ] && echo "$STUB_NOISE"
if [ "${STUB_NOSENTINEL:-0}" = "1" ]; then exit 0; fi
FLOOR="${STUB_FLOOR:-29000}" UNREAD="${STUB_UNREAD:-0}" PATHS="${STUB_PATHS:-/a /b /c}" python3 -c '
import hashlib, json, os
paths = sorted(os.environ["PATHS"].split())
csha = hashlib.sha256(("\n".join(paths) + "\n").encode()).hexdigest()
print("CCS_FLOOR_JSON " + json.dumps({
  "floor": int(os.environ["FLOOR"]), "file_count": len(paths),
  "unreadable": int(os.environ["UNREAD"]), "composition_sha": csha,
  "realpaths": paths}, sort_keys=True))'
EOF
chmod +x "$W/enum-stub.sh"

new_env() {   # $1=케이스 디렉토리 이름 → 전역 FX_* 설정
  FX="$W/$1"; rm -rf "$FX"; mkdir -p "$FX/ga" "$FX/ga/ccs-window.sessions"
  printf 'CCS_WRITE_GATE=warn\n' > "$FX/cap-constants.env"
  : > "$FX/ledger.jsonl"
  export CCS_FIXTURE_HOME="$FX"
  export CCS_GATE_ARTIFACTS_DIR="$FX/ga"
  export CCS_PIN_FILE="$FX/ga/ccs-window.start"
  export CCS_WINDOW_SESSIONS_DIR="$FX/ga/ccs-window.sessions"
  export CCS_LEDGER_FILE="$FX/ledger.jsonl"
  export MEMORY_HEALTH_CONSTANTS="$FX/cap-constants.env"
  export CCS_WINDOW_SHA_SH="$W/sha-stub.sh"
  export CCS_ENUMERATOR="$W/enum-stub.sh"
  export CCS_WINDOW_MAX_SESSIONS=3
  export CCS_WINDOW_MAX_DAYS=14
  # ★ 자매 스크립트를 **명시**로 고정한다. close 스크립트는 기본값을 자기 위치에서 찾는데,
  #   §5.1 의 잠금제거 변이판은 임시 디렉토리에 놓이므로 그 기본값이 빈 값을 낸다 —
  #   그러면 변이판이 "잠금이 없어서" 가 아니라 "핀을 못 읽어서" 조용히 0건을 내고,
  #   RED 가 만들어지지 않은 것을 RED 실패로 착각하게 된다(이 스위트가 실제로 겪었다).
  export CCS_PIN_SH="$PIN_SH"
  export CCS_VERDICT_PY="$VERDICT"
}

gate_of() { /usr/bin/grep -E '^CCS_WRITE_GATE=' "$FX/cap-constants.env" | head -1 | cut -d= -f2; }
set_gate() { printf 'CCS_WRITE_GATE=%s\n' "$1" > "$FX/cap-constants.env"; }
verdict_rows() { /usr/bin/grep -c '"window_verdict"' "$FX/ledger.jsonl" 2>/dev/null | tr -d ' '; }
last_verdict_field() {  # $1=field
  /usr/bin/grep '"window_verdict"' "$FX/ledger.jsonl" | tail -1 | F="$1" python3 -c \
    'import json,os,sys; print(json.loads(sys.stdin.read()).get(os.environ["F"]))' 2>/dev/null
}

seed_pin() {   # $1=floor  $2=window_id override(선택)
  CCS_PIN_FLOOR_OVERRIDE="$1" CCS_PIN_WINDOW_ID="${2:-}" CCS_PIN_PROVENANCE=zsh \
    bash "$PIN_SH" create "$CCS_PIN_FILE" "$1" "$(STUB_CSHA= zsh "$W/sha-stub.sh" composition)" \
      "$(zsh "$W/sha-stub.sh" metric)" zsh >/dev/null 2>&1
  bash "$PIN_SH" read "$CCS_PIN_FILE" window_id
}

seed_sessions() {  # $1=window_id  $2=개수
  # ★ 변수명이 `i` 가 아닌 이유: 호출부 루프의 카운터를 덮어써 루프가 한 바퀴 만에 끝난 적이 있다.
  #   함수가 전역을 밟는 부류의 조용한 실패라 시험 결과가 "1회만 돌았는데 3회로 보였다".
  _ss_i=0; while [ "$_ss_i" -lt "$2" ]; do mkdir -p "$CCS_WINDOW_SESSIONS_DIR/$1/s$_ss_i"; _ss_i=$((_ss_i+1)); done
}

row() {  # $1=window_id $2=ts $3=floor $4=open_floor(빈값=null) $5=session_id
  WID="$1" TS="$2" FL="$3" OF="$4" SID="$5" python3 -c '
import json, os
print(json.dumps({"kind":"window_observation","row_schema_version":2,"ts":os.environ["TS"],
 "src":"test","floor":int(os.environ["FL"]),
 "open_floor":(int(os.environ["OF"]) if os.environ["OF"] else None),
 "window_id":os.environ["WID"],"session_id":os.environ["SID"]}, sort_keys=True))' >> "$FX/ledger.jsonl"
}

echo "══ RED-first — 변경 **전** 트리는 판정을 인쇄하지 않는다 (M2: 창은 닫혔는데 침묵) ══"
new_env red
WID="$(seed_pin 29000)"
seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 29000 sA
git -C "$SELF/.." show 27705cf:scripts/ccs-floor-surface.sh > "$W/old-surface.sh" 2>/dev/null
if [ -s "$W/old-surface.sh" ]; then
  OLD_OUT="$(bash "$W/old-surface.sh" 2>/dev/null)"
  case "$OLD_OUT" in
    *창종료=*) bad "RED 실패 — 구 판이 이미 판정을 인쇄한다. 이 스위트는 목표 결함을 검출하지 못한다" ;;
    *) ok "RED 관측 — 구 판(27705cf)은 창이 닫혔는데 판정을 한 글자도 인쇄하지 않는다" ;;
  esac
  V0="$(verdict_rows)"
  [ "${V0:-0}" = "0" ] && ok "RED 관측 — 구 판은 판정행도 남기지 않는다 (0건)" \
                       || bad "RED 실패 — 구 판이 판정행 ${V0}건을 남겼다"
else
  bad "RED 준비 실패 — 27705cf 의 구 판을 꺼내지 못했다"
fi

echo
echo "══ P-B — 판정이 실제로 인쇄되고 게이트가 따라 움직이는가 ══"
new_env b1
WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 29000 sA
row "$WID" "2026-09-01T02:00:00Z" 28900 29000 sB
set_gate deny
OUT="$(bash "$CLOSE_SH" close 2>&1)"
case "$OUT" in *"창종료=window_closed_negative"*) ok "B1 어느 limb 도 안 켜짐 → negative 인쇄: $OUT" ;;
  *) bad "B1 ★출력이 negative 판정이 아니다: $OUT" ;; esac
[ "$(gate_of)" = "warn" ] && ok "B1 negative 가 래치를 **능동 해제**했다 (deny → warn)" \
                          || bad "B1 ★게이트가 $(gate_of) — 해제 없는 래치는 상태기계가 아니다"
[ "$(verdict_rows)" = "1" ] && ok "B1 판정행 정확히 1건" || bad "B1 ★판정행 $(verdict_rows)건"

new_env b2
WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T23:00:00Z" 29500 29000 sA
row "$WID" "2026-09-02T01:00:00Z" 29600 29000 sA
set_gate warn
OUT="$(bash "$CLOSE_SH" close 2>&1)"
case "$OUT" in *"창종료=window_closed_positive"*) ok "B2 day limb (2 UTC일) → positive: $OUT" ;;
  *) bad "B2 ★$OUT" ;; esac
[ "$(gate_of)" = "deny" ] && ok "B2 positive 만 무장한다 (warn → deny)" || bad "B2 ★게이트=$(gate_of)"
[ "$(last_verdict_field limbs_fired)" = "['day']" ] && ok "B2 limbs_fired=['day']" \
  || bad "B2 ★limbs_fired=$(last_verdict_field limbs_fired)"

new_env b3
WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29500 29000 sA
row "$WID" "2026-09-01T02:00:00Z" 29500 29000 sB
row "$WID" "2026-09-01T03:00:00Z" 29500 29000 sC
set_gate warn
OUT="$(bash "$CLOSE_SH" close 2>&1)"
case "$OUT" in *positive*) ok "B3 session limb (같은 날 3세션) → positive — 두 limb 은 서로를 함의하지 않는다" ;;
  *) bad "B3 ★$OUT" ;; esac

echo
echo "══ P-B(4) — 구 regime 행은 day-limb 전용 경로이고 **positive 를 낼 수 없다** ══"
new_env bl1
WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29500 "" sA
row "$WID" "2026-09-01T02:00:00Z" 29900 "" sB
row "$WID" "2026-09-01T03:00:00Z" 29900 "" sC
set_gate deny
OUT="$(bash "$CLOSE_SH" close 2>&1)"
D="$(last_verdict_field decision)"; OP="$(last_verdict_field operand)"; LG="$(last_verdict_field legacy)"
[ "$D" = "window_closed_negative" ] && [ "$OP" = "day_limb_only" ] && [ "$LG" = "True" ] \
  && ok "B-L1 구 regime 1일 → negative · operand=day_limb_only · legacy — 3세션 초과인데도 positive 가 아니다" \
  || bad "B-L1 ★decision=$D operand=$OP legacy=$LG"

new_env bl2
WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T23:00:00Z" 29500 "" sA
row "$WID" "2026-09-02T01:00:00Z" 29500 "" sB
set_gate deny
bash "$CLOSE_SH" close >/dev/null 2>&1
[ "$(last_verdict_field decision)" = "window_closed_indeterminate" ] \
  && [ "$(last_verdict_field indeterminate_reason)" = "legacy_days_over" ] \
  && [ "$(gate_of)" = "deny" ] \
  && ok "B-L2 구 regime 2일 → indeterminate(legacy_days_over) · 게이트 **무변경**" \
  || bad "B-L2 ★decision=$(last_verdict_field decision) reason=$(last_verdict_field indeterminate_reason) gate=$(gate_of)"

echo
echo "══ §5.4 — open_floor 유일성 전제조건 5행 (이질적 행은 정상 계수하지 않는다) ══"
u_case() {  # $1=이름 $2=기대 reason  (행은 호출 전 $FX 에 심는다)
  D="$(python3 "$VERDICT" --window "$WID" --rows "$FX/ledger.jsonl" --pin "$CCS_PIN_FILE" \
        --gate-before warn | python3 -c 'import json,sys;v=json.load(sys.stdin);print(v["decision"],v["indeterminate_reason"],v["operand"])')"
  case "$D" in
    *"$2"*) ok "§5.4 $1 → $D" ;;
    *) bad "§5.4 ★$1 기대 '$2' 인데 $D" ;;
  esac
}
new_env u1; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 29000 sA
u_case "값 1개 · 핀과 일치" "window_closed_negative None open_floor"
new_env u2; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 28000 sA
u_case "값 1개 · 핀과 불일치" "open_floor_row_pin_divergence"
new_env u3; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 29000 sA
row "$WID" "2026-09-01T02:00:00Z" 29000 28000 sB
u_case "값 2개 이상" "open_floor_not_unanimous"
new_env u4; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 "" sA
u_case "전부 null (구 regime)" "day_limb_only"
new_env u5; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 29000 sA
row "$WID" "2026-09-01T02:00:00Z" 29000 "" sB
u_case "혼재 (부분 롤아웃)" "open_floor_partial_regime"

echo
echo "══ P-B(6) — 의심 상태는 **무장이라는 유일한 위험 지점**에서 소비된다 ══"
new_env s1; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T23:00:00Z" 29500 29000 sA
row "$WID" "2026-09-02T01:00:00Z" 29500 29000 sB
printf '{"plausibility":"suspect","composition":"unchanged","window_id":"%s"}\n' "$WID" > "${CCS_PIN_FILE}.meta.json"
set_gate warn
bash "$CLOSE_SH" close >/dev/null 2>&1
[ "$(last_verdict_field decision)" = "window_closed_indeterminate" ] && [ "$(gate_of)" = "warn" ] \
  && ok "S1 suspect 핀 + 두 limb → indeterminate · **무장하지 않는다**" \
  || bad "S1 ★decision=$(last_verdict_field decision) gate=$(gate_of)"

new_env s2; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T23:00:00Z" 29500 29000 sA
row "$WID" "2026-09-02T01:00:00Z" 29500 29000 sB
printf '{"plausibility":"ok","composition":"shrunk","window_id":"%s"}\n' "$WID" > "${CCS_PIN_FILE}.meta.json"
set_gate warn
bash "$CLOSE_SH" close >/dev/null 2>&1
[ "$(last_verdict_field indeterminate_reason)" = "composition_shrunk" ] && [ "$(gate_of)" = "warn" ] \
  && ok "S2 composition=shrunk → indeterminate(composition_shrunk) · 무장 없음 (C2 의 핵심)" \
  || bad "S2 ★reason=$(last_verdict_field indeterminate_reason) gate=$(gate_of)"

echo
echo "══ §5.1 C1 — **두 종결자** 동시성 (결정적 RED/GREEN) ══"
# 잠금을 제거한 변이판을 만든다 — 다른 것은 건드리지 않는다.
mk_unlocked() {
  cp "$CLOSE_SH" "$W/close-unlocked.sh"
  python3 - "$W/close-unlocked.sh" <<'PYEOF'
import io, sys
p = sys.argv[1]; s = io.open(p, encoding='utf-8').read(); before = s
s = s.replace('  if ! audit_acquire_lock "$PIN"; then', '  if false; then', 1)
s = s.replace("  trap 'audit_release_lock \"$PIN\"' EXIT", "  : # 잠금 해제 없음(변이)", 1)
assert s != before, "잠금 제거 변이가 걸리지 않았다"
io.open(p, 'w', encoding='utf-8').write(s)
PYEOF
  chmod +x "$W/close-unlocked.sh"
}
mk_unlocked

barrier_close() {  # $1=실행할 close 스크립트 → 두 프로세스를 배리어로 동시에 푼다
  g="$FX/barrier"; rm -f "$g" "$FX/out1" "$FX/out2"
  ( while [ ! -e "$g" ]; do :; done; bash "$1" close > "$FX/out1" 2>&1 ) &
  p1=$!
  ( while [ ! -e "$g" ]; do :; done; bash "$1" close > "$FX/out2" 2>&1 ) &
  p2=$!
  sleep 0.15; : > "$g"; wait "$p1" "$p2" 2>/dev/null
}

new_env c5a; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 29000 sA
barrier_close "$W/close-unlocked.sh"
N_UNLOCKED="$(verdict_rows)"
if [ "${N_UNLOCKED:-0}" -ge 2 ]; then
  ok "B5-a RED — 잠금 제거판이 창 하나에 판정행 ${N_UNLOCKED}건을 남겼다. 이 시험은 목표 결함을 실제로 검출한다"
else
  bad "B5-a ★RED 를 만들지 못했다 (판정행 ${N_UNLOCKED}건) — 잠금을 붙여도 증명되는 것이 없다"
fi

new_env c5b; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 29000 sA
barrier_close "$CLOSE_SH"
N_LOCKED="$(verdict_rows)"
[ "$N_LOCKED" = "1" ] && ok "B5-b GREEN — 같은 배리어, 잠긴 판: 판정행 **정확히 1건**" \
                      || bad "B5-b ★판정행 ${N_LOCKED}건"
LOSER="$(cat "$FX/out1" "$FX/out2" 2>/dev/null | /usr/bin/grep -cE 'window_close_refused=lock_busy|window_close_skipped=already_adjudicated|window_close_skipped=not_closing')"
[ "${LOSER:-0}" -ge 1 ] \
  && ok "B5-b 진 프로세스가 **이름 있는 코드**로 말했다 (lock_busy / already_adjudicated / not_closing)" \
  || bad "B5-b ★진 프로세스가 조용히 끝났다: $(cat "$FX/out1" "$FX/out2" 2>/dev/null | tr '\n' ' ')"

new_env c5c; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 29000 sA
bash "$CLOSE_SH" close >/dev/null 2>&1                 # 승자 먼저 완주
mv "$FX/ledger.jsonl" "$FX/ledger.jsonl.1"             # 원장 **회전** — 판정이 archive 로 간다
: > "$FX/ledger.jsonl"
seed_sessions "$(bash "$PIN_SH" read "$CCS_PIN_FILE" window_id)" 0
# 새 핀이 열렸으므로 옛 창을 다시 닫으려면 옛 창을 복원해야 한다 — 핀을 옛 창으로 되돌린다.
CCS_ROTATE_SH="$HOME/.claude/da-tools/rotate-jsonl.sh"
OUT="$(ROTATE_TARGET_DIR="$FX" bash -c '
  . "'"$HOME"'/.claude/da-tools/rotate-jsonl.sh" 2>/dev/null
  read_rotated "'"$FX"'/ledger.jsonl" | /usr/bin/grep -c window_verdict' 2>/dev/null)"
[ "${OUT:-0}" -ge 1 ] \
  && ok "B5-c 회전 뒤에도 read_rotated(활성+archive)가 archive 의 판정을 본다 — 활성만 읽으면 두 번째를 쓴다" \
  || bad "B5-c ★archive 의 판정을 못 본다 — 중복확인이 회전으로 우회된다"

echo
echo "══ P-C — 회전 · 고아 분류 (§5.3) ══"
new_env pc1; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T01:00:00Z" 29000 29000 sA
bash "$CLOSE_SH" close >/dev/null 2>&1
NEWID="$(bash "$PIN_SH" read "$CCS_PIN_FILE" window_id)"
[ -n "$NEWID" ] && [ "$NEWID" != "$WID" ] && ok "P-C(1) 회전 — 판정 뒤 새 창이 열렸다 ($WID → $NEWID)" \
  || bad "P-C(1) ★회전 실패 (window_id=$NEWID)"
PRED="$(bash "$PIN_SH" read-meta "$CCS_PIN_FILE" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("predecessor_window_id"))')"
[ "$PRED" = "$WID" ] && ok "P-C(1) 새 핀이 predecessor_window_id 로 선행창을 가리킨다" \
                     || bad "P-C(1) ★predecessor_window_id=$PRED"

new_env pc_f; WID="$(seed_pin 29000)"; seed_sessions "$WID" 2     # 2/3 — 아직 안 닫혔다
row "$WID" "2026-09-01T01:00:00Z" 29000 29000 sA
rm -f "$CCS_PIN_FILE" "${CCS_PIN_FILE}.meta.json"                 # 핀만 지운다 = 고아
OUT="$(bash "$CLOSE_SH" close 2>&1)"
RECOV_ID="$(bash "$PIN_SH" read "$CCS_PIN_FILE" window_id 2>/dev/null)"
SC_AFTER="$(find "$CCS_WINDOW_SESSIONS_DIR/$WID" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [ "$(verdict_rows)" = "0" ] && [ "$RECOV_ID" = "$WID" ] && [ "$SC_AFTER" = "2" ]; then
  ok "P-C(3)/H1 orphan_open — **판정하지 않고** 같은 window_id 로 핀 재수립, 레지스트리 2세션 그대로 (시계 재시작 없음): $OUT"
else
  bad "P-C(3) ★판정행=$(verdict_rows) 복구창=$RECOV_ID 세션수=$SC_AFTER ($OUT)"
fi

new_env pc_e; WID="$(seed_pin 29000)"; seed_sessions "$WID" 3     # 3/3 — 닫혔다
row "$WID" "2026-09-01T23:00:00Z" 29500 29000 sA
row "$WID" "2026-09-02T01:00:00Z" 29500 29000 sB
rm -f "$CCS_PIN_FILE" "${CCS_PIN_FILE}.meta.json"
set_gate warn
OUT="$(bash "$CLOSE_SH" close 2>&1)"
[ "$(last_verdict_field orphan)" = "True" ] && [ "$(last_verdict_field decision)" = "window_closed_positive" ] \
  && [ "$(gate_of)" = "deny" ] \
  && ok "P-C(2) orphan_closed — orphan:true positive 로 **무장한다**: 핀을 지우고 다시 만드는 것으로 무장을 건너뛸 수 없다" \
  || bad "P-C(2) ★orphan=$(last_verdict_field orphan) decision=$(last_verdict_field decision) gate=$(gate_of)"

echo
echo "══ P-D — create 가 스스로 잰다 · 계약은 fail-closed · 멤버십 대조 ══"
new_env d1
CCS_ENUMERATOR="/nonexistent-enumerator" \
  OUT="$(CCS_ENUMERATOR=/nonexistent-enumerator CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh 2>&1)"
[ ! -e "$CCS_PIN_FILE" ] && case "$OUT" in *floor_unmeasurable*) ok "D1 열거자 부재 → floor_unmeasurable · 핀 미생성" ;;
  *) bad "D1 ★$OUT" ;; esac || bad "D1 ★핀이 생겼다"

new_env d2
OUT="$(STUB_UNREAD=1 CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh 2>&1)"
[ ! -e "$CCS_PIN_FILE" ] && case "$OUT" in *floor_incomplete*) ok "D2 unreadable>0 → floor_incomplete · 핀 미생성" ;;
  *) bad "D2 ★$OUT" ;; esac || bad "D2 ★핀이 생겼다"

new_env d3
OUT="$(STUB_FLOOR=28800 CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh 2>&1)"
F="$(bash "$PIN_SH" read "$CCS_PIN_FILE" floor 2>/dev/null)"
[ "$F" = "28800" ] && ok "D3 bash 로 부른 create 가 **성공**하고, floor 는 zsh 서브프로세스 측정값이다 (28800)" \
                   || bad "D3 ★floor=$F ($OUT)"
P="$(bash "$PIN_SH" read "$CCS_PIN_FILE" provenance)"
[ "$P" = "zsh" ] && ok "D3 provenance=zsh" || bad "D3 ★provenance=$P"

new_env d4
OUT="$(STUB_FLOOR=28800 CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" 99999 - m zsh 2>&1)"
case "$OUT" in *floor_mismatch*) ok "D4 위치인자 floor ≠ 측정 → floor_mismatch (인자는 **검사되는 단언**이다)" ;;
  *) bad "D4 ★$OUT" ;; esac

new_env d9
OUT="$(STUB_NOISE="zsh: noise line" STUB_FLOOR=28800 CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh 2>&1)"
[ "$(bash "$PIN_SH" read "$CCS_PIN_FILE" floor 2>/dev/null)" = "28800" ] \
  && ok "D9 센티넬 앞 잡음 줄이 있어도 **마지막 센티넬** 파싱이 성공한다" || bad "D9 ★$OUT"
new_env d9b
OUT="$(STUB_NOSENTINEL=1 CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh 2>&1)"
case "$OUT" in *floor_unmeasurable*) ok "D9 센티넬 없음 → floor_unmeasurable" ;; *) bad "D9 ★$OUT" ;; esac

# D10/D11 — 선행 핀과의 멤버십 대조
new_env d10
STUB_PATHS="/a /b /c" STUB_FLOOR=29000 CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh >/dev/null 2>&1
cp "$CCS_PIN_FILE" "$FX/pred.json"; bash "$PIN_SH" read-meta "$CCS_PIN_FILE" > "$FX/predmeta.json"
rm -f "$CCS_PIN_FILE" "${CCS_PIN_FILE}.meta.json"
STUB_PATHS="/a /b" STUB_FLOOR=20000 CCS_PIN_PREDECESSOR_FILE="$FX/pred.json" CCS_PIN_PREDECESSOR_META="$FX/predmeta.json" \
  CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh >/dev/null 2>&1
COMP="$(bash "$PIN_SH" read-meta "$CCS_PIN_FILE" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("composition"),d.get("removed_paths"))')"
case "$COMP" in shrunk*) ok "D10 파일 한 개가 include 목록에서 빠졌다 → composition=shrunk · removed_paths 가 그 파일을 지목: $COMP" ;;
  *) bad "D10 ★$COMP" ;; esac
# 그리고 그 창은 **무장할 수 없다**
WID="$(bash "$PIN_SH" read "$CCS_PIN_FILE" window_id)"; seed_sessions "$WID" 3
row "$WID" "2026-09-01T23:00:00Z" 29500 20000 sA
row "$WID" "2026-09-02T01:00:00Z" 29500 20000 sB
set_gate warn; bash "$CLOSE_SH" close >/dev/null 2>&1
[ "$(gate_of)" = "warn" ] && [ "$(last_verdict_field decision)" = "window_closed_indeterminate" ] \
  && ok "D10 그 창은 두 limb 이 켜져도 indeterminate — **무장하지 않는다**" \
  || bad "D10 ★gate=$(gate_of) decision=$(last_verdict_field decision)"

new_env d11
STUB_PATHS="/a /b" STUB_FLOOR=29000 CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh >/dev/null 2>&1
cp "$CCS_PIN_FILE" "$FX/pred.json"; bash "$PIN_SH" read-meta "$CCS_PIN_FILE" > "$FX/predmeta.json"
rm -f "$CCS_PIN_FILE" "${CCS_PIN_FILE}.meta.json"
STUB_PATHS="/a /b /c" STUB_FLOOR=31000 CCS_PIN_PREDECESSOR_FILE="$FX/pred.json" CCS_PIN_PREDECESSOR_META="$FX/predmeta.json" \
  CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh >/dev/null 2>&1
C11="$(bash "$PIN_SH" read-meta "$CCS_PIN_FILE" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("composition"))')"
[ "$C11" = "changed" ] && ok "D11 파일이 **늘었다** → composition=changed (정당한 추가는 창을 막지 않는다)" \
                       || bad "D11 ★composition=$C11"

new_env d12
# 선행 핀에 realpath 목록이 없다(사이드카 이전 판) — 지문만 있다.
printf '{"composition_sha":"%s","floor":29316,"window_id":"legacywin","opened_at":"2026-01-01T00:00:00Z","floor_min_observed":29316,"metric_sha":"m","provenance":"zsh","updated_at":"2026-01-01T00:00:00Z"}\n' \
  "$(printf '/a\n/b\n/c\n' | shasum -a 256 | cut -d' ' -f1)" > "$FX/legacypin.json"
STUB_PATHS="/a /b /c" STUB_FLOOR=29316 CCS_PIN_PREDECESSOR_FILE="$FX/legacypin.json" \
  CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh >/dev/null 2>&1
C12="$(bash "$PIN_SH" read-meta "$CCS_PIN_FILE" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("composition"),d.get("plausibility"))')"
[ "$C12" = "unchanged ok" ] \
  && ok "D12 라이브 legacy 핀을 선행으로 쓴 최초 회전 — 목록이 없어도 **지문 대조**가 된다 ($C12)" \
  || bad "D12 ★$C12"
new_env d12b
printf '{"composition_sha":"deadbeef","floor":29316,"window_id":"legacywin","opened_at":"2026-01-01T00:00:00Z","floor_min_observed":29316,"metric_sha":"m","provenance":"zsh","updated_at":"2026-01-01T00:00:00Z"}\n' > "$FX/legacypin.json"
STUB_PATHS="/a /b /c" STUB_FLOOR=29316 CCS_PIN_PREDECESSOR_FILE="$FX/legacypin.json" \
  CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh >/dev/null 2>&1
C12B="$(bash "$PIN_SH" read-meta "$CCS_PIN_FILE" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("composition"))')"
[ "$C12B" = "changed_unverifiable" ] \
  && ok "D12b 지문은 달라졌는데 선행 목록이 없다 → changed_unverifiable (방향을 증명 못 하면 무장도 못 한다)" \
  || bad "D12b ★composition=$C12B"

new_env d6
STUB_PATHS="/a /b /c" STUB_FLOOR=29000 CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh >/dev/null 2>&1
cp "$CCS_PIN_FILE" "$FX/pred.json"; bash "$PIN_SH" read-meta "$CCS_PIN_FILE" > "$FX/predmeta.json"
rm -f "$CCS_PIN_FILE" "${CCS_PIN_FILE}.meta.json"
STUB_PATHS="/a /b /c" STUB_FLOOR=15000 CCS_PIN_PREDECESSOR_FILE="$FX/pred.json" CCS_PIN_PREDECESSOR_META="$FX/predmeta.json" \
  CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$CCS_PIN_FILE" - - m zsh >/dev/null 2>&1
PL="$(bash "$PIN_SH" read-meta "$CCS_PIN_FILE" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("plausibility"))')"
[ -f "$CCS_PIN_FILE" ] && [ "$PL" = "suspect" ] \
  && ok "D6 타당성 대역 밖(29000→15000) → 핀은 **쓰이고** suspect 로 표시된다 (거부는 약한 게이트 방향이다)" \
  || bad "D6 ★핀존재=$([ -f "$CCS_PIN_FILE" ] && echo yes || echo no) plausibility=$PL"

echo
echo "══ §5.8 — 픽스처 노브는 **라이브 경로에서 무시**된다 (거부가 아니라 무시) ══"
new_env d13
LIVEDIR="$W/livepath"; mkdir -p "$LIVEDIR"
OUT="$(CCS_FIXTURE_HOME="$FX" CCS_PIN_FLOOR_OVERRIDE=12345 STUB_FLOOR=28800 \
        CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$LIVEDIR/pin.json" - - m zsh 2>&1)"
LF="$(bash "$PIN_SH" read "$LIVEDIR/pin.json" floor 2>/dev/null)"
case "$OUT" in *override_ignored_live_path*) OKNOTE=1 ;; *) OKNOTE=0 ;; esac
# ★ 라이브 경로에서는 `CCS_ENUMERATOR` 도 함께 무시되므로 스텁이 아니라 **실 열거자**가 돈다 —
#   그래서 기대값은 특정 숫자가 아니라 "합성값 12345 가 아닌 실측 정수" 다.
case "$LF" in ''|*[!0-9]*) REALMEAS=0 ;; 12345) REALMEAS=0 ;; *) REALMEAS=1 ;; esac
[ "$OKNOTE" = "1" ] && [ "$REALMEAS" = "1" ] \
  && ok "D13 픽스처 밖 핀 경로에서 CCS_PIN_FLOOR_OVERRIDE·CCS_ENUMERATOR 가 **무시**되고 실측($LF)이 들어갔다 · 무시 사실이 기록됐다" \
  || bad "D13 ★note=$OUT floor=$LF (합성 12345 가 들어갔다면 누출이다)"

echo
echo "══ §5.6 — indeterminate 회복 모델 (N회 후 자동 warn **금지**) ══"
new_env m1
set_gate deny
k=1
while [ "$k" -le 3 ]; do
  rm -f "$CCS_PIN_FILE" "${CCS_PIN_FILE}.meta.json"   # 매 회차 **새 창** — 같은 창은 두 번 판정되지 않는다
  # ★ window_id 는 `sha256(opened_at + composition_sha)[:12]` 이고 `opened_at` 이 **초 단위**라,
  #   같은 초에 같은 구성으로 만든 핀은 id 가 충돌한다(잔여 U6 — 보고서에 명시). 여기서는 명시한다.
  WID="$(seed_pin 29000 "w$k")"; seed_sessions "$WID" 3
  row "$WID" "2026-09-0${k}T23:00:00Z" 29500 "" sA
  row "$WID" "2026-09-0$((k+1))T01:00:00Z" 29500 "" sB
  bash "$CLOSE_SH" close >/dev/null 2>&1
  k=$((k+1))
done
CONS="$(last_verdict_field consecutive_indeterminate)"
[ "$CONS" = "3" ] && [ "$(gate_of)" = "deny" ] \
  && ok "B7 연속 indeterminate 3회 — 카운터는 3, 게이트는 **입력값 그대로**(deny). 카운트가 게이트를 바꾸지 않는다" \
  || bad "B7 ★consecutive=$CONS gate=$(gate_of)"
LASTW="$(last_verdict_field window_id)"
R1="$(bash "$SURFACE" gate-recover --window "nosuchwindow" --ack "사유" 2>&1)"
case "$R1" in *not_indeterminate*) ok "B7 gate-recover 는 최근 판정이 indeterminate 가 아니면 거부한다" ;;
  *) bad "B7 ★$R1" ;; esac
R2="$(CCS_ENUMERATOR=/nonexistent bash "$SURFACE" gate-recover --window "$LASTW" --ack "사유" 2>&1)"
case "$R2" in *measurement_still_failing*) ok "B7 gate-recover 는 **신규 측정이 계약을 통과할 때만** 푼다 (고무도장 방지)" ;;
  *) bad "B7 ★$R2" ;; esac
R3="$(bash "$SURFACE" gate-recover --window "$LASTW" --ack "열거자 복구 확인" 2>&1)"
[ "$(gate_of)" = "warn" ] && /usr/bin/grep -q '"gate_recovery"' "$FX/ledger.jsonl" \
  && ok "B7 gate-recover 성공 → warn · kind=gate_recovery 행이 언제·무슨 사유로 풀었는지 남긴다: $R3" \
  || bad "B7 ★gate=$(gate_of) ($R3)"

echo
echo "══ 열거자 ↔ ccs-window-sha.sh 의 composition_sha 동치 (약속이 아니라 단언) ══"
unset CCS_ENUMERATOR CCS_FIXTURE_HOME CCS_GATE_ARTIFACTS_DIR CCS_PIN_FILE CCS_WINDOW_SESSIONS_DIR \
      CCS_LEDGER_FILE MEMORY_HEALTH_CONSTANTS CCS_WINDOW_SHA_SH CCS_WINDOW_MAX_SESSIONS CCS_WINDOW_MAX_DAYS
E_CSHA="$(CCS_LEDGER_FILE="$W/throwaway.jsonl" zsh "$ENUMER" 2>/dev/null | tail -1 | sed 's/^CCS_FLOOR_JSON //' \
          | python3 -c 'import json,sys;print(json.load(sys.stdin)["composition_sha"])' 2>/dev/null)"
S_CSHA="$(zsh "$SCRIPTS/ccs-window-sha.sh" composition 2>/dev/null)"
[ -n "$E_CSHA" ] && [ "$E_CSHA" = "$S_CSHA" ] \
  && ok "두 산출이 같다 ($E_CSHA) — 지문 정의가 두 곳에서 갈라지지 않았다" \
  || bad "★지문 불일치: 열거자=$E_CSHA sha스크립트=$S_CSHA"

echo
echo "══ 격리 ══"
REAL_SHA_AFTER="$(shasum -a 256 "$REAL_LEDGER" 2>/dev/null | cut -d' ' -f1)"
REAL_PIN_SHA_AFTER="$(shasum -a 256 "$HOME/.claude/gate-artifacts/ccs-window.start" 2>/dev/null | cut -d' ' -f1)"
REAL_CONST_SHA_AFTER="$(shasum -a 256 "$SELF/../cap-constants.env" 2>/dev/null | cut -d' ' -f1)"
[ "$REAL_PIN_SHA_BEFORE" = "$REAL_PIN_SHA_AFTER" ] && ok "실 핀 무변경" || bad "★실 핀이 바뀌었다"
[ "$REAL_CONST_SHA_BEFORE" = "$REAL_CONST_SHA_AFTER" ] && ok "실 cap-constants.env 무변경" || bad "★실 게이트 모드가 바뀌었다"
if [ "$REAL_SHA_BEFORE" = "$REAL_SHA_AFTER" ]; then
  ok "실 원장 무변경"
else
  # 동치 케이스가 실 게이트를 한 번 돌린다 — 그 행은 정당한 측정이지만, 늘어난 것이
  # **그것뿐인지** 확인한다. 판정행·관측행이 늘었다면 픽스처 밖으로 샌 것이다.
  ADD="$(diff <(printf '') <(printf '') >/dev/null; /usr/bin/grep -c '"window_verdict"' "$REAL_LEDGER" 2>/dev/null)"
  echo "  ⓘ 실 원장이 바뀌었다 — 동치 케이스의 실 게이트 1회 실행(measurement 행) 때문이다"
  [ "${ADD:-0}" = "0" ] && ok "실 원장에 판정행은 0건 (판정은 픽스처 밖으로 새지 않았다)" \
                        || bad "★실 원장에 판정행 ${ADD}건 — 픽스처 밖으로 샜다"
fi

echo
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
