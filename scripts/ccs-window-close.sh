#!/bin/bash
# ccs-window-close.sh — 창 종료를 **하나의 직렬화된 전이**로 수행한다
#                       (CSR #2262 · 설계 r4 §5.1 C1 · §5.3 H1 · §5.6 M1 · P-B · P-C)
#
# ────────────────────────────────────────────────────────────────────────────
# 이 파일이 존재하는 이유 — 한 문단
#   창 `ceea9f87052b` 는 2026-09-10 에 이미 닫혔다(세션 22/20, 그 뒤로 `ref_stale=sessions`).
#   그런데 **판정문이 한 줄도 인쇄되지 않았다.** 설계 v5:200-201 축자는
#   *"SILENCE IS IMPOSSIBLE: the window cannot close without a printed verdict"* 다.
#   침묵의 원인은 판정 규칙이 어려워서가 아니라 **아무도 그것을 호출하지 않아서**였다
#   (`ccs-floor-surface.sh` 는 `read`·`lower` 만 부른다 — 실측).
#
# ★ 왜 "전이" 인가 — 여러 걸음이면 두 종결자가 서로 다른 판정을 낸다 (§5.1 C1)
#   회전만 CAS 로 지키면 **판정**과 **게이트 쓰기**는 보호되지 않는다. 동시 SessionStart 둘이
#   같은 닫히는 창을 보고, **서로 다른 행집합**을 스냅샷하고, **서로 다른 판정**을 내고, 둘 다
#   그럴듯한 판정행을 남기고, 둘 다 게이트를 쓴다 — 전역 상태를 스케줄러가 정하게 된다.
#   그래서 재읽기 → 중복확인 → 행집합 동결 → 단일 판정 → 내구 append → 게이트 → 회전을
#   **하나의 리스 안**에서 한다.
#
# ★ 새 잠금을 만들지 않는다 — 출하된 것을 재사용한다
#   `~/.claude/scripts/lib/audit-append-lock.sh` 의 `audit_acquire_lock` 은 **임의 파일 경로를
#   키로** 받는다(`_audit_lock_dir(){ echo "${1}.rotate.lock.d"; }`). 그래서 창별 리스에 새
#   기구가 필요 없다.
#   ★ 리스 키 = **핀 경로**. 임의 선택이 아니라 **유일하게 맞는 선택**이다 — `cmd lower` 가 이미
#     `"$PIN"` 으로 잠그므로(`ccs-window-pin.sh:101`), 다른 키로 잠그면 동시 `lower` 를 배제하지
#     못해 상호배제가 반쪽이 된다. 잠금 디렉토리는 형제 경로 `${PIN}.rotate.lock.d` 라 핀을
#     갈아끼우는 `mv` 를 넘어 살아남고, `lower`·종료·회전을 관통하는 **하나의 안정된 키**다.
#   ★ 고아(핀 없음) 경로도 **같은 핀 경로 리스**를 쓴다. `ccs-window.sessions/` 안에 잠금
#     디렉토리를 만들면 고아 스캔이 그것을 창 id 로 오인한다.
#
# ★ 리스 순서 불변식 (`lease_order`)
#   이 전이는 **핀 경로** 리스를 잡고, 그 안에서 append 헬퍼가 **원장 경로** 리스를 잡는다.
#   순서는 언제나 핀 → 원장이고 그 역은 없다. append 헬퍼는 핀 리스를 절대 잡지 않으므로
#   wait-for 그래프에 순환이 없다 = 이 둘 사이에 교착은 도달 불가능하다.
#
# ★ busy 경로의 실패 **방향** — 숨기지 않고 적는다
#   `audit_acquire_lock` 이 1 을 반환하면 **아무것도 쓰지 않는다**(판정행도, 게이트도, 회전도).
#   `window_close_refused=lock_busy` 를 이름으로 찍고 비영 종료한다. 창은 열린 채 남고
#   **다음 SessionStart 가 재시도**한다 — 지연은 "세션 시작 한 번" 으로 유계다.
#   방향: 게이트는 이전 값을 유지한다. `warn` 이었다면 positive 판정이 **늦어지고**(느슨·유계),
#   `deny` 였다면 `deny` 로 남는다(엄격). 이것은 `cmd lower` 가 이미 택하고 적어 둔 거래이고,
#   이유도 같다 — 리스 없이 쓰면 **어떤 후속 세션도 고칠 수 없는** 불변식이 깨지지만,
#   안 쓰면 다음 세션 시작에서 자가 교정된다.
#
# ★ append 실패를 **삼키지 않는다**
#   관측행 호출부(`ccs-floor-surface.sh:255`)는 `>/dev/null 2>&1 || true` 로 append 헬퍼의
#   fail-loud 종료를 버린다. 판정행은 그 관용구를 **복사하지 않는다** — append 가 비영으로
#   끝나면 게이트도 회전도 하지 않고 `verdict_append_failed` 로 죽는다. (clause `verdict_append_failloud`)
#
# ★ 원장 회전 때문에 중복확인은 **활성 파일만 읽으면 안 된다**
#   "이 창의 판정이 이미 있나" 를 활성 jsonl 에서만 찾으면, 회전으로 archive 에 간 판정을 못 보고
#   **두 번째 판정**을 쓴다. 그래서 `rotate-jsonl.sh` 의 `read_rotated`(활성 + 최신 archive)를 쓴다.
#
# ★ 정직 범위 (rules/hook-classification.md Decision Rule)
#   리스는 **협조적**이다 — 라이브러리가 스스로 "cooperative … not a security boundary" 라고
#   밝힌다. 핀을 손으로 고치거나, 리스를 안 잡는 종료 경로를 돌리거나, 잠금 디렉토리를 지우는
#   행위자는 배제되지 않는다. 성립하는 것은 딱 이것이다 — **이 코드 경로를 도는 프로세스들
#   사이에서 창 하나당 판정은 정확히 하나이고, 진 프로세스는 아무것도 쓰지 않으며 자기가
#   졌다는 것을 이름으로 말한다.** 협조하는 집합 위의 정합성이지 경계가 아니다.
#   그리고 `rm -r ccs-window.sessions/<id>/` 는 고아 판정도 §5.3 분류도 무력화한다 — 여기서
#   탐지되지 않는다.
#
# 사용:
#   ccs-window-close.sh close                      # 적격이면 전이 수행, 아니면 조용히 0
#   ccs-window-close.sh gate-recover --window <id> --ack "<사유>"
# 종료: 0 = 전이 완료 또는 비적격 · 1 = 거부(사유는 stdout `window_close_refused=…`) · 2 = 인자 오류
# stdout: 0줄 또는 `창종료=<decision>` / `window_close_*=<code>` 한 줄
# ────────────────────────────────────────────────────────────────────────────
set -u

_SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE_ARTIFACTS="${CCS_GATE_ARTIFACTS_DIR:-$HOME/.claude/gate-artifacts}"
PIN="${CCS_PIN_FILE:-$GATE_ARTIFACTS/ccs-window.start}"
SESSIONS_ROOT="${CCS_WINDOW_SESSIONS_DIR:-$GATE_ARTIFACTS/ccs-window.sessions}"
LEDGER="${CCS_LEDGER_FILE:-$HOME/.claude/da-tools/context-budget-audit.jsonl}"
CONST_FILE="${MEMORY_HEALTH_CONSTANTS:-${_SELF_DIR}/../cap-constants.env}"
PIN_SH="${CCS_PIN_SH:-$_SELF_DIR/ccs-window-pin.sh}"
VERDICT_PY="${CCS_VERDICT_PY:-$_SELF_DIR/ccs-window-verdict.py}"
SHA_SH="${CCS_WINDOW_SHA_SH:-$_SELF_DIR/ccs-window-sha.sh}"
LOCK_LIB="${CCS_PIN_LOCK_LIB:-$HOME/.claude/scripts/lib/audit-append-lock.sh}"
ROTATE_SH="${CCS_ROTATE_SH:-$HOME/.claude/da-tools/rotate-jsonl.sh}"
# ★ 일반 event 용 헬퍼를 쓴다. 자매 `append-gate-audit.sh` 는 skip-approval 스키마
#   (gate/skip_reason/user_explicit_approval)를 **강제**하므로 판정행을 거부한다.
#   두 헬퍼는 같은 잠금 라이브러리·같은 fail-loud(exit 3) 계약을 쓴다.
APPEND="${CCS_AUDIT_APPEND:-$HOME/.claude/scripts/append-audit-event.sh}"

MAX_SESSIONS="${CCS_WINDOW_MAX_SESSIONS:-20}"
MAX_DAYS="${CCS_WINDOW_MAX_DAYS:-14}"

_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_sha_file() { [ -f "$1" ] && shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || echo ""; }

_read_gate() {
  _g=""
  [ -r "$CONST_FILE" ] && _g="$(/usr/bin/grep -E '^CCS_WRITE_GATE=' "$CONST_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')"
  case "$_g" in off|warn|deny) printf '%s' "$_g" ;; *) printf 'warn' ;; esac
}

# 게이트 모드 줄만 **원자적으로** 교체한다 (같은 디렉토리 임시파일 + mv).
_write_gate() {  # $1=새 모드
  NEWMODE="$1" CF="$CONST_FILE" python3 - <<'PY'
import io, os, sys, tempfile
cf, new = os.environ["CF"], os.environ["NEWMODE"]
try:
    src = io.open(cf, encoding="utf-8").read().splitlines(True)
except OSError:
    sys.exit(1)
out, hit = [], False
for line in src:
    if line.startswith("CCS_WRITE_GATE="):
        out.append("CCS_WRITE_GATE=%s\n" % new); hit = True
    else:
        out.append(line)
if not hit:
    out.append("CCS_WRITE_GATE=%s\n" % new)
d = os.path.dirname(cf) or "."
fd, tmp = tempfile.mkstemp(dir=d)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("".join(out))
    os.replace(tmp, cf)
except BaseException:
    try: os.unlink(tmp)
    except OSError: pass
    raise
PY
}

# 원장 읽기 — **활성 + 최신 archive**. 활성만 열면 회전이 판정 중복확인을 우회시킨다.
_read_ledger() {
  if [ -r "$ROTATE_SH" ]; then
    # shellcheck source=/dev/null
    . "$ROTATE_SH" 2>/dev/null
    if command -v read_rotated >/dev/null 2>&1; then read_rotated "$LEDGER"; return 0; fi
  fi
  [ -f "$LEDGER" ] && cat "$LEDGER" 2>/dev/null
  return 0
}

_session_count() {  # $1=window_id
  find "$SESSIONS_ROOT/$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

_age_days() {  # $1=ISO8601Z → 소수 일 (파싱 실패 시 빈 값)
  TS="$1" python3 -c '
import calendar, os, time
try:
    t = time.strptime(os.environ["TS"], "%Y-%m-%dT%H:%M:%SZ")
    print("%.4f" % ((time.time() - calendar.timegm(t)) / 86400.0))
except Exception:
    print("")
' 2>/dev/null
}

_ge() { python3 -c 'import sys;print("1" if float(sys.argv[1])>=float(sys.argv[2]) else "0")' "$1" "$2" 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════
# gate-recover (§5.6) — **어떤 카운트도 게이트를 바꾸지 않는다.** 사람이 명령을 돌린다.
# ════════════════════════════════════════════════════════════════════════════
cmd_gate_recover() {
  RWIN=""; RACK=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --window) RWIN="${2:-}"; shift 2 ;;
      --ack)    RACK="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$RWIN" ] || { echo "gate_recover_refused=window_required"; return 2; }
  [ -n "$RACK" ] || { echo "gate_recover_refused=ack_required"; return 2; }

  # (a) 그 창의 **가장 최근 판정**이 indeterminate 일 때만.
  LASTDEC="$(_read_ledger | WIN="$RWIN" python3 -c '
import json, os, sys
w = os.environ["WIN"]; last = None
for line in sys.stdin:
    line = line.strip()
    if not line or "window_verdict" not in line: continue
    try: r = json.loads(line)
    except Exception: continue
    if r.get("kind") == "window_verdict" and r.get("window_id") == w: last = r
print((last or {}).get("decision", ""))
print((last or {}).get("consecutive_indeterminate", 0))
' 2>/dev/null)"
  DEC="$(printf '%s\n' "$LASTDEC" | sed -n '1p')"
  CONSEC="$(printf '%s\n' "$LASTDEC" | sed -n '2p')"
  if [ "$DEC" != "window_closed_indeterminate" ]; then
    echo "gate_recover_refused=not_indeterminate:${DEC:-none}"
    return 1
  fi

  # (b) **신규 측정이 계약을 지금 통과할 때만.** 측정 건강은 주장이 아니라 시연이어야 한다 —
  #     이 조건이 이 명령을 고무도장이 아니게 만드는 유일한 것이다.
  SENT="$(mktemp "${TMPDIR:-/tmp}/ccs-recover.XXXXXX")" || return 2
  "${CCS_PIN_ZSH_BIN:-/bin/zsh}" "${CCS_ENUMERATOR:-$_SELF_DIR/ccs-floor-enumerate.sh}" > "$SENT" 2>>"$SENT"
  if ! python3 "$_SELF_DIR/ccs-pin-create-plan.py" --sentinel "$SENT" >/dev/null 2>&1; then
    rm -f "$SENT"
    echo "gate_recover_refused=measurement_still_failing"
    return 1
  fi
  rm -f "$SENT"

  GB="$(_read_gate)"
  ROW="$(TS="$(_now)" WIN="$RWIN" ACK="$RACK" CONSEC="${CONSEC:-0}" GB="$GB" python3 -c '
import json, os
print(json.dumps({
  "kind": "gate_recovery", "row_schema_version": 1,
  "ts": os.environ["TS"], "src": "ccs-window-close",
  "window_id": os.environ["WIN"], "reason": os.environ["ACK"],
  "consecutive_indeterminate": int(os.environ["CONSEC"]) if os.environ["CONSEC"].isdigit() else 0,
  "gate_before": os.environ["GB"], "gate_after": "warn",
}, ensure_ascii=False, sort_keys=True))')"
  if ! printf '%s\n' "$ROW" | AUDIT_LOG="$LEDGER" "$APPEND" >/dev/null; then
    echo "gate_recover_refused=append_failed"
    return 1
  fi
  _write_gate warn || { echo "gate_recover_refused=gate_write_failed"; return 1; }
  [ "$(_read_gate)" = "warn" ] || { echo "gate_recover_refused=arming_write_failed"; return 1; }
  echo "gate_recovered=$RWIN gate_before=$GB gate_after=warn"
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# 전이 본체
# ════════════════════════════════════════════════════════════════════════════

# 판정 → 원장 → 게이트 (§5.1 6~8). 전역: VERDICT_JSON, DECISION, GATE_AFTER
_adjudicate_and_apply() {   # $1=window_id $2=pin경로또는빈값 $3=meta경로또는빈값 $4=orphan(0|1) $5=adjudicated_pin_sha
  AW="$1"; APIN="$2"; AMETA="$3"; AORPH="$4"; ASHA="$5"
  GATE_BEFORE="$(_read_gate)"

  ROWS_TMP="$(mktemp "${TMPDIR:-/tmp}/ccs-rows.XXXXXX")" || return 2
  _read_ledger > "$ROWS_TMP"

  # 5. 행집합 **동결** — 이 파일이 판정의 유일한 입력이다. 판정행에 `row_count`·`rows_through`
  #    를 실어, 나중에 읽는 사람이 어느 행들이 이 판정을 만들었는지 재구성할 수 있게 한다.
  set -- --window "$AW" --rows "$ROWS_TMP" --gate-before "$GATE_BEFORE"
  [ -n "$APIN" ] && set -- "$@" --pin "$APIN"
  [ -n "$AMETA" ] && set -- "$@" --meta "$AMETA"
  [ "$AORPH" = "1" ] && set -- "$@" --orphan

  VERDICT_JSON="$(python3 "$VERDICT_PY" "$@" 2>&1)" || {
    rm -f "$ROWS_TMP"; echo "window_close_refused=verdict_compute_failed"; return 1; }
  rm -f "$ROWS_TMP"

  VERDICT_JSON="$(printf '%s' "$VERDICT_JSON" | TS="$(_now)" PSHA="$ASHA" python3 -c '
import json, os, sys
v = json.load(sys.stdin)
v["ts"] = os.environ["TS"]
v["src"] = "ccs-window-close"
v["adjudicated_pin_sha"] = os.environ.get("PSHA") or None
print(json.dumps(v, ensure_ascii=False, sort_keys=True))')" || {
    echo "window_close_refused=verdict_stamp_failed"; return 1; }

  DECISION="$(printf '%s' "$VERDICT_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["decision"])')"
  GATE_AFTER="$(printf '%s' "$VERDICT_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["gate_after"])')"

  # 7. **내구 append — 종료코드를 검사한다.** 실패하면 게이트도 회전도 하지 않는다.
  if ! printf '%s\n' "$VERDICT_JSON" | AUDIT_LOG="$LEDGER" "$APPEND" >/dev/null; then
    echo "window_close_refused=verdict_append_failed"
    return 1
  fi

  # 8. 게이트 적용 + **되읽기**. indeterminate 는 아무것도 쓰지 않는다.
  #    래치에 해제가 없으면 상태기계가 아니다 — negative 는 **능동 해제**(warn)한다.
  if [ "$DECISION" = "window_closed_indeterminate" ]; then
    if [ "$(_read_gate)" != "$GATE_BEFORE" ]; then
      echo "window_close_refused=gate_changed_under_indeterminate"
      return 1
    fi
  else
    _write_gate "$GATE_AFTER" || { echo "window_close_refused=gate_write_failed"; return 1; }
    # `cap-constants.env` 는 444 로 조용히 실패할 수 있다 — 원장이 그럴 수 있는 것과 똑같이.
    if [ "$(_read_gate)" != "$GATE_AFTER" ]; then
      echo "window_close_refused=arming_write_failed"
      return 1
    fi
  fi
  return 0
}

# 9. 회전 — CAS + 같은 디렉토리 임시파일 + mv (P-C(1))
_rotate_pin() {   # $1=adjudicated_pin_sha
  CUR="$(_sha_file "$PIN")"
  if [ "$CUR" != "$1" ]; then
    echo "pin_rotate_refused=pin_changed"
    return 1
  fi
  PRED_PIN="$(mktemp "${TMPDIR:-/tmp}/ccs-predpin.XXXXXX")"
  PRED_META="$(mktemp "${TMPDIR:-/tmp}/ccs-predmeta.XXXXXX")"
  cat "$PIN" > "$PRED_PIN" 2>/dev/null
  bash "$PIN_SH" read-meta "$PIN" > "$PRED_META" 2>/dev/null

  # ★ `composition_sha` 는 여기서 재지 않는다 — create 안의 열거자가 **권위**이고, 그 값이
  #   핀에 들어간다. 밖에서 따로 재어 단언으로 넘기면 같은 것을 두 번 재는 셈이고, 두 측정이
  #   갈라지는 순간 회전이 이유 없이 거부된다. 모르는 값은 `-`(단언 안 함)로 넘긴다.
  #   `metric_sha` 는 열거자가 내지 않으므로 여기서 잰다.
  MSHA="$(zsh "$SHA_SH" metric 2>/dev/null)" || MSHA=""
  if [ -z "$MSHA" ]; then
    rm -f "$PRED_PIN" "$PRED_META"
    echo "pin_rotate_refused=sha_unmeasurable"
    return 1
  fi
  NEWPIN="${PIN}.new.$$"
  rm -f "$NEWPIN" "${NEWPIN}.meta.json"
  OUT="$(CCS_PIN_PREDECESSOR_FILE="$PRED_PIN" CCS_PIN_PREDECESSOR_META="$PRED_META" \
         CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$NEWPIN" "-" "-" "$MSHA" zsh 2>&1)"
  RC=$?
  rm -f "$PRED_PIN" "$PRED_META"
  if [ "$RC" -ne 0 ] || [ ! -f "$NEWPIN" ]; then
    rm -f "$NEWPIN" "${NEWPIN}.meta.json"
    echo "pin_rotate_refused=create_failed:$(printf '%s' "$OUT" | head -1)"
    return 1
  fi
  # 사이드카 먼저, 핀 나중 — 핀만 있고 정황이 없으면 `unknown` 으로 흡수되지만,
  # 정황만 있고 핀이 없으면 다음 create 가 남의 창 정황을 읽을 수 있다.
  [ -f "${NEWPIN}.meta.json" ] && mv -f "${NEWPIN}.meta.json" "${PIN}.meta.json"
  mv -f "$NEWPIN" "$PIN"
  echo "pin_rotated=$(bash "$PIN_SH" read "$PIN" window_id 2>/dev/null)"
  return 0
}

cmd_close() {
  # ── 1. 리스 ───────────────────────────────────────────────────────────────
  if [ ! -r "$LOCK_LIB" ]; then
    echo "window_close_refused=lock_lib_absent"
    return 1
  fi
  # shellcheck source=/dev/null
  . "$LOCK_LIB"
  mkdir -p "$(dirname "$PIN")" 2>/dev/null || true
  if ! audit_acquire_lock "$PIN"; then
    echo "window_close_refused=lock_busy"
    return 1
  fi
  trap 'audit_release_lock "$PIN"' EXIT

  # ── 2. 리스 **안**에서 재읽기 ────────────────────────────────────────────
  #    (house rule, ccs-window-pin.sh:96 — 잠금 밖에서 읽고 안에서 쓰면 lost update 가 남는다)
  if [ -r "$PIN" ]; then
    _close_with_pin
  else
    _close_orphans
  fi
}

_close_with_pin() {
  WID="$(bash "$PIN_SH" read "$PIN" window_id 2>/dev/null)"
  OPENED="$(bash "$PIN_SH" read "$PIN" opened_at 2>/dev/null)"
  [ -n "$WID" ] || { echo "window_close_skipped=window_id_absent"; return 0; }

  # ── 3. 종료 적격 재평가 (`ccs-reference-resolve.py:19` 와 같은 경계) ──────
  SC="$(_session_count "$WID")"
  AGE="$(_age_days "$OPENED")"
  ELIG=0
  [ "${SC:-0}" -ge "$MAX_SESSIONS" ] 2>/dev/null && ELIG=1
  [ -n "$AGE" ] && [ "$(_ge "$AGE" "$MAX_DAYS")" = "1" ] && ELIG=1
  if [ "$ELIG" -ne 1 ]; then
    # 다른 프로세스가 이미 회전시켰을 수도 있다 — 그 경우도 여기로 온다.
    echo "window_close_skipped=not_closing"
    return 0
  fi

  # ── 4. **내구 중복확인** (활성 + archive). 3번은 이것이 아니다. ──────────
  if _has_verdict "$WID"; then
    echo "window_close_skipped=already_adjudicated"
    return 0
  fi

  PSHA="$(_sha_file "$PIN")"
  META_TMP="$(mktemp "${TMPDIR:-/tmp}/ccs-meta.XXXXXX")"
  bash "$PIN_SH" read-meta "$PIN" > "$META_TMP" 2>/dev/null

  _adjudicate_and_apply "$WID" "$PIN" "$META_TMP" 0 "$PSHA" || { rm -f "$META_TMP"; return 1; }
  rm -f "$META_TMP"

  ROT="$(_rotate_pin "$PSHA")" || { printf '창종료=%s %s\n' "$DECISION" "$ROT"; return 1; }
  printf '창종료=%s %s\n' "$DECISION" "$ROT"
  return 0
}

_has_verdict() {  # $1=window_id → 0 = 있음
  _read_ledger | WIN="$1" python3 -c '
import json, os, sys
w = os.environ["WIN"]
for line in sys.stdin:
    line = line.strip()
    if not line or "window_verdict" not in line: continue
    try: r = json.loads(line)
    except Exception: continue
    if r.get("kind") == "window_verdict" and r.get("window_id") == w:
        sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

# ── §5.3 — 고아. `orphan_closed` 만 판정하고, `orphan_open` 은 **판정하지 않는다**. ──
_close_orphans() {
  [ -d "$SESSIONS_ROOT" ] || { echo "window_close_skipped=no_registry"; return 0; }
  HANDLED=0
  for d in "$SESSIONS_ROOT"/*; do
    [ -d "$d" ] || continue
    OW="$(basename "$d")"
    _has_verdict "$OW" && continue          # 이미 판정된 창 — 손대지 않는다
    SC="$(_session_count "$OW")"
    FIRST_TS="$(_read_ledger | WIN="$OW" python3 -c '
import json, os, sys
w = os.environ["WIN"]; first = None
for line in sys.stdin:
    line = line.strip()
    if not line or "window_observation" not in line: continue
    try: r = json.loads(line)
    except Exception: continue
    if r.get("kind") == "window_observation" and r.get("window_id") == w:
        ts = r.get("ts") or ""
        if ts and (first is None or ts < first): first = ts
print(first or "")' 2>/dev/null)"
    AGE=""; [ -n "$FIRST_TS" ] && AGE="$(_age_days "$FIRST_TS")"

    # `orphan_closed` iff 세션 ≥ 상한 **OR** 최초 관측행이 14일 이상 오래됐다.
    #   두 번째는 **하한**으로서 건전하다 — `opened_at` 은 반드시 첫 행보다 앞서므로,
    #   14일 된 첫 행은 창이 14일 이상 됐음을 증명한다. 둘 다 핀 없이 증명 가능하다.
    CLOSED=0
    [ "${SC:-0}" -ge "$MAX_SESSIONS" ] 2>/dev/null && CLOSED=1
    [ -n "$AGE" ] && [ "$(_ge "$AGE" "$MAX_DAYS")" = "1" ] && CLOSED=1

    if [ "$CLOSED" -eq 1 ]; then
      _adjudicate_and_apply "$OW" "" "" 1 "" || return 1
      HANDLED=1
      printf '창종료=%s orphan=closed window=%s\n' "$DECISION" "$OW"
      # 판정했으니 새 창을 연다(선행핀 없음 → `skipped_no_predecessor`).
      MSHA="$(zsh "$SHA_SH" metric 2>/dev/null)"
      if [ -n "$MSHA" ]; then
        CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$PIN" "-" "-" "$MSHA" zsh >/dev/null 2>&1 || true
      fi
      return 0
    fi

    # ── `orphan_open` — 닫혔다고 **꾸며내지 않는다**. 같은 `window_id` 로 창을 이어 간다. ──
    #   `window_id` 가 그대로이므로 레지스트리 계수가 이어진다 = **시계가 재시작하지 않는다**.
    #   이것이 H1 이 지목한 결함(세션 8/20 에서 핀을 지우면 8세션을 완결된 창으로 판정하고
    #   시계를 되돌린다)을 새 계수기가 아니라 **동일성**으로 닫는 방식이다.
    OFS="$(_read_ledger | WIN="$OW" python3 -c '
import json, os, sys
w = os.environ["WIN"]; vals = set(); nulls = 0
for line in sys.stdin:
    line = line.strip()
    if not line or "window_observation" not in line: continue
    try: r = json.loads(line)
    except Exception: continue
    if r.get("kind") != "window_observation" or r.get("window_id") != w: continue
    v = r.get("open_floor")
    if isinstance(v, int): vals.add(v)
    else: nulls += 1
print(list(vals)[0] if (len(vals) == 1 and nulls == 0) else "")' 2>/dev/null)"
    MSHA="$(zsh "$SHA_SH" metric 2>/dev/null)"
    CSHA="$(zsh "$SHA_SH" composition 2>/dev/null)"   # recover-open 은 열거자를 안 돌므로 여기서 잰다
    if [ -z "$MSHA" ] || [ -z "$CSHA" ]; then
      echo "window_close_refused=sha_unmeasurable"
      return 1
    fi
    if [ -n "$OFS" ]; then
      bash "$PIN_SH" recover-open "$PIN" "$OFS" "$CSHA" "$MSHA" "$OW" "${FIRST_TS:-}" >/dev/null 2>&1 \
        && printf '창종료=미판정 orphan=open window=%s recovered=open_floor\n' "$OW" \
        || printf 'window_close_refused=orphan_recover_failed window=%s\n' "$OW"
    else
      # 행이 `open_floor` 를 안 실었거나 일치하지 않는다 — 피연산자를 **재기준화**하게 된다.
      # 재기준화된 피연산자 위의 positive 는 초과의 증거가 아니라 재기준화의 증거다.
      # 그래서 이 창은 **영영 positive 를 못 낸다**(종료 시 indeterminate).
      CCS_PIN_WINDOW_ID="$OW" CCS_PIN_OPENED_AT="${FIRST_TS:-}" CCS_PIN_RECOVERED=orphan_open_indeterminate \
        CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$PIN" "-" "-" "$MSHA" zsh >/dev/null 2>&1 \
        && printf '창종료=미판정 orphan=open window=%s recovered=open_floor_unreconstructible\n' "$OW" \
        || printf 'window_close_refused=orphan_recover_failed window=%s\n' "$OW"
    fi
    HANDLED=1
    return 0
  done
  [ "$HANDLED" -eq 0 ] && echo "window_close_skipped=no_orphan"
  return 0
}

case "${1:-close}" in
  close)        shift 2>/dev/null || true; cmd_close ;;
  gate-recover) shift; cmd_gate_recover "$@" ;;
  *) echo "usage: ccs-window-close.sh {close|gate-recover --window <id> --ack <reason>}" >&2; exit 2 ;;
esac
