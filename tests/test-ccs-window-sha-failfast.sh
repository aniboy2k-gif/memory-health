#!/bin/bash
# test-ccs-window-sha-failfast.sh — `_metric` 의 다이제스트 지점이 실패를 전파하는가 (CSR #2288)
#
# ★ 이 스위트가 왜 여기(memory-health 저장소)에 있는가 — 정직
#   시험 대상(`scripts/ccs-window-sha.sh`)과 **같은 저장소**라 한 커밋으로 함께 움직인다.
#   같은 이유를 형제 스위트 `test-ccs-window-close.sh` 헤더가 이미 적어 두었다.
#   da-system 의 `.githooks/pre-push` 는 `CCS_PATHS='^(...da-tools/...)$'` 로 **`da-tools/` 경로에만**
#   발동하므로(실측) 이 파일을 거기 두어도 자동 실행되지 않는다 — 교차저장소 배치는 이득 없이
#   결합만 늘린다.
#
# ★ 자동 실행 배선은 **없다** — memory-health 에는 `.githooks` 도 `core.hooksPath` 도 없고
#   `.git/hooks` 에 sample 외 파일이 없다(실측). 이 스위트는 **손으로 돌려야 한다**.
#   형제 `test-ccs-window-close.sh` 도 같은 처지다. 숨기지 않고 적는다.
#
# ★ 무엇이 빨강이어야 하는가 (Red-first)
#   패치 전 `scripts/ccs-window-sha.sh` 에 대해 N1~N5 가 **실패해야** 한다. 오늘 초록인 세 스위트
#   (`test-ccs-tokenize-equivalence` · `test-ccs-stdout-freeze` · `test-ccs-write-gate`)는 이 결함을
#   보지 못한다 — 전부 `_metric` 이 rc=0 을 내는 경로만 밟기 때문이다.
#
# ★ 격리: 픽스처 게이트·픽스처 모듈만 쓴다(`CCS_GATE` override). 실 게이트·실 원장·실 핀 무접촉.
#   스위트 끝에서 실 원장 sha256 불변을 단언한다.
#
# 사용: bash tests/test-ccs-window-sha-failfast.sh
# ────────────────────────────────────────────────────────────────────────────
set -u

SELF="$(cd "$(dirname "$0")" && pwd)"
SHA_SH="$SELF/../scripts/ccs-window-sha.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/ccs-failfast.XXXXXX")"
trap 'rm -rf "$W"' EXIT

REAL_SHASUM="$(command -v shasum)"
[ -x "$REAL_SHASUM" ] || { echo "ERROR: shasum 부재"; exit 2; }

REAL_LEDGER="$HOME/.claude/da-tools/context-budget-audit.jsonl"
REAL_LEDGER_BEFORE="$($REAL_SHASUM -a 256 "$REAL_LEDGER" 2>/dev/null | cut -d' ' -f1)"

# ── 픽스처 게이트 + 픽스처 공유 모듈 ────────────────────────────────────────
# `_metric` 이 읽는 것만 담는다: 상수 6줄 + `^def _load_tokenizer(` 블록.
# `_TOKENIZER_DERIVED="${GATE:A:h}/lib/ccs-tokenize.py"` 이므로 모듈은 게이트 **옆** lib/ 에 둔다.
mkdir -p "$W/gate/lib"
GATE="$W/gate/check-context-size.sh"
# ★ `--print-floor-realpaths` 분기를 **맨 앞**에 둔다 — 뒤의 python 형태 줄은 zsh 문법이 아니므로
#   실행 경로가 거기 닿으면 게이트가 죽는다(실측: C7 이 그 이유로 빨갰다). 그래서 no-op heredoc 안에
#   가둔다. `_metric` 은 이 파일을 **텍스트로** 읽으므로(awk/grep) heredoc 안이어도 그대로 잡힌다.
cat > "$GATE" <<'GATEEOF'
#!/bin/zsh
if [ "${1:-}" = "--print-floor-realpaths" ]; then
  printf '%s\0%s\0' "/fixture/alpha.md" "/fixture/beta.md"
  exit 0
fi
PER_FILE_CAP_TOKENS=10000
TOTAL_HARD_TOKENS=30000
TOTAL_SOFT_TOKENS=27000
KO_THRESHOLD=0.1
KO_FACTOR_HARD=1.99
EN_FACTOR_HARD=2.55
: <<'PYBLOCK'
def _load_tokenizer(x):
    return x

PYBLOCK
exit 0
GATEEOF
chmod +x "$GATE"
printf 'FIXTURE TOKENIZER MODULE\n' > "$W/gate/lib/ccs-tokenize.py"

run_metric() {  # $1=PATH prefix(빈문자면 무스텁) → stdout 을 $OUT, rc 를 $RC, stderr 를 $ERRF
  ERRF="$W/err.$$"
  if [ -n "${1:-}" ]; then
    OUT="$(PATH="$1:$PATH" CCS_GATE="$GATE" zsh "$SHA_SH" metric 2>"$ERRF")"; RC=$?
  else
    OUT="$(CCS_GATE="$GATE" zsh "$SHA_SH" metric 2>"$ERRF")"; RC=$?
  fi
}
reason_of() { sed -n 's/^CCS_METRIC_UNAVAILABLE reason=\([a-z_][a-z_]*\).*/\1/p' "$ERRF" | head -1; }

# 스텁 생성기. ★ 줄번호로 가리키지 않는다 — 다음 편집 한 번에 조용히 거짓이 되고, 그것이 이 티켓의
#   결함 그 자체다. 두 다이제스트 지점을 **호출 형태**로 부른다:
#     · 모듈 다이제스트 = `shasum -a 256 "$_TOKENIZER_DERIVED"`  → **파일형** ($# >= 3)
#     · 지문 다이제스트 = `{ … } | shasum -a 256`                  → **stdin형** ($# == 2)
# ★ 이 인자-개수 판별은 **load-bearing** 이다 — 대상 스크립트가 `shasum` 을 부르는 형태가 바뀌면
#   (예: 지문 다이제스트가 파일 인자를 받게 되면) 스텁이 두 지점을 조용히 뒤바꿔 잡고, 그러면 N3~N5 가
#   **틀린 이유로 통과**한다. 그래서 아래 A0 이 그 가정을 직접 단언한다(가정을 주석으로만 두지 않는다).
mk_stub() { # $1=dir $2=mode
  mkdir -p "$1"
  cat > "$1/shasum" <<STUBEOF
#!/bin/sh
REAL="$REAL_SHASUM"
MODE="$2"
case "\$MODE" in
  all_fail)        exit 7 ;;
  file_hex_rc9)    if [ \$# -ge 3 ]; then echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  \$3"; exit 9; fi; exec "\$REAL" "\$@" ;;
  file_bad_rc0)    if [ \$# -ge 3 ]; then echo "NOTAHASH  \$3"; exit 0; fi; exec "\$REAL" "\$@" ;;
  stdin_fail)      if [ \$# -ge 3 ]; then exec "\$REAL" "\$@"; fi; exit 11 ;;
  stdin_bad_rc0)   if [ \$# -ge 3 ]; then exec "\$REAL" "\$@"; fi; cat >/dev/null; echo "ZZZZ  -"; exit 0 ;;
esac
exec "\$REAL" "\$@"
STUBEOF
  chmod +x "$1/shasum"
}

echo "── A0: 스텁 판별 가정 자체를 단언한다 (가정이 조용히 뒤집히면 N3~N5 가 틀린 이유로 통과) ──"
# `_metric` 이 shasum 을 정확히 2회 부르고, 그 호출이 {파일형 $#>=3, stdin형 $#==2} 한 쌍인가.
TRACE="$W/argtrace"; : > "$TRACE"
mkdir -p "$W/s0"
cat > "$W/s0/shasum" <<TRACEEOF
#!/bin/sh
echo "\$#" >> "$TRACE"
exec "$REAL_SHASUM" "\$@"
TRACEEOF
chmod +x "$W/s0/shasum"
run_metric "$W/s0"
n_calls=$(wc -l < "$TRACE" | tr -d ' ')
n_file=$(awk '$1>=3' "$TRACE" | wc -l | tr -d ' ')
n_stdin=$(awk '$1==2' "$TRACE" | wc -l | tr -d ' ')
# ★ "정확히 2회" 를 ">=1회씩" 으로 **느슨하게 하지 않는다**(DA 지적을 검토 후 반려).
#   느슨하게 하면 세 번째 호출이 생겨도 초록인데, 그 세 번째가 파일형이면 N3 의 스텁이 그것까지
#   오염시켜 **N3~N5 가 틀린 이유로 통과**한다. 즉 이 빨강은 위양성이 아니라 "스텁을 다시 유도하라"는
#   정확한 신호다. 대신 실패 문구가 그 다음 행동을 말하게 한다.
[ "$n_calls" -eq 2 ] && ok "A0 shasum 호출 정확히 2회" \
  || bad "A0 호출 ${n_calls}회 (기대 2) — 스텁의 인자-개수 판별이 더는 두 다이제스트 지점을 1:1 로 가리지 못한다. mk_stub 의 판별식을 새 호출 형태에 맞춰 다시 유도할 것(느슨하게 풀지 말 것)."
[ "$n_file" -eq 1 ] && ok "A0 파일형(\$#>=3) 정확히 1회 — 모듈 다이제스트를 가린다" || bad "A0 파일형 ${n_file}회 (기대 1)"
[ "$n_stdin" -eq 1 ] && ok "A0 stdin형(\$#==2) 정확히 1회 — 지문 다이제스트를 가린다" || bad "A0 stdin형 ${n_stdin}회 (기대 1)"
# ★ A0 의 범위 — **성공 경로만** 추적한다(`run_metric "$W/s0"` 은 정상 실행이다). 오류 경로에서만
#   도달하는 `shasum` 호출이 생기면 A0 은 그것을 세지 못한다. "정확히 2회"를 스크립트 전체의
#   불변식으로 읽지 말 것 — 성공 경로의 불변식이다.

echo
echo "── P0 양성대조: 픽스처 게이트로 정상 산출 (지문 구성 동결) ──"
run_metric ""
if [ "$RC" -eq 0 ]; then ok "P0 정상 rc=0"; else bad "P0 rc=$RC (기대 0) · stderr=$(cat "$ERRF")"; fi
case "$OUT" in
  *[!0-9a-f]*|"") bad "P0 출력이 소문자 16진이 아니다: '$OUT'" ;;
  *) if [ ${#OUT} -eq 64 ]; then ok "P0 64자리 소문자 16진"; else bad "P0 길이 ${#OUT} (기대 64)"; fi ;;
esac
# 지문 구성 동결 — 픽스처가 고정이므로 이 값도 고정이다. 값이 움직이면 **해싱되는 바이트열이
# 바뀐 것**이며, 그것이 곧 살아있는 핀의 무효화다(CSR #2288 비협상 수용조건의 기계화).
EXPECTED_FIXTURE_METRIC="ea1ba4867616b071e6f6f02bcbdb276fc7f45b17ff2e4aadfbf2cf49ef0973c4"
if [ "$EXPECTED_FIXTURE_METRIC" = "__PIN__" ]; then
  printf '  ⓘ  P0 픽스처 지문 = %s  (아직 미고정 — 아래 안내 참조)\n' "$OUT"
elif [ "$OUT" = "$EXPECTED_FIXTURE_METRIC" ]; then
  ok "P0 픽스처 지문 동결 — 해싱 바이트열 불변"
else
  bad "P0 픽스처 지문이 움직였다: $OUT (기대 $EXPECTED_FIXTURE_METRIC) — 해싱 바이트열이 바뀌었다"
fi

echo
echo "── N1: shasum 전면 실패(무출력) → rc=3 · stdout 0바이트 ──"
mk_stub "$W/s1" all_fail; run_metric "$W/s1"
[ "$RC" -eq 3 ] && ok "N1 rc=3" || bad "N1 rc=$RC (기대 3) ← 실패 미전파"
[ ${#OUT} -eq 0 ] && ok "N1 stdout 0바이트" || bad "N1 stdout ${#OUT}바이트 (기대 0)"
r="$(reason_of)"; [ "$r" = "tokenizer_hash_failed" ] && ok "N1 reason=tokenizer_hash_failed" || bad "N1 reason='$r'"

echo
echo "── N2: 모듈 다이제스트가 유효 64-hex 를 내고 rc=9 → rc=3 · 날조 지문 미편입 ──"
mk_stub "$W/s2" file_hex_rc9; run_metric "$W/s2"
[ "$RC" -eq 3 ] && ok "N2 rc=3" || bad "N2 rc=$RC (기대 3) ← 생산자 rc 미포착"
[ ${#OUT} -eq 0 ] && ok "N2 stdout 0바이트" || bad "N2 stdout='$OUT' ← 날조 지문이 편입됐다"
# ★ 이 단언은 **문자열 포함 검사여서는 안 된다** — 날조된 `_mod_sha` 는 해싱돼 들어가므로 출력에
#   문자 그대로 나타나는 일이 없고, 그래서 깨진 코드에서도 통과한다(실측으로 확인한 공허한 단언).
#   대신 **날조 스트림이 내는 지문 그 자체**를 고정해 두고 그것과 같지 않은지 묻는다.
#   패치 전에는 정확히 이 값이 나오고(빨강), 패치 후에는 아무것도 안 나온다(초록).
# ★ 핀 재생성 규칙 — 이 핀은 **픽스처에 종속**이다. 픽스처 게이트나 픽스처 모듈을 고치면 위 P0 핀이
#   먼저 빨개지는데, **그때 이 N2 핀도 함께 다시 뽑아야 한다.** 안 그러면 이 값은 더 이상 "그 날조가
#   내는 지문" 이 아니게 되어 비교가 조용히 공허해진다. 그 경우에도 바로 위 `stdout 0바이트` 단언이
#   진짜 불변식("실패하면 어떤 지문도 내지 않는다")을 계속 지킨다 — 이 핀은 그 위의 덧방이다.
FORGED_FIXTURE_METRIC="35ede62d5c7dda9b5703c1098c6d14ff4bc28c2409b2f670330a57f806cb2a92"
if [ "$FORGED_FIXTURE_METRIC" = "__PIN_FORGED__" ]; then
  printf '  ⓘ  N2 날조 지문 = %s  (아직 미고정 — 아래 안내 참조)\n' "$OUT"
elif [ "$OUT" = "$FORGED_FIXTURE_METRIC" ]; then
  bad "N2 날조된 지문이 그대로 metric_sha 로 나갔다: $OUT"
else
  ok "N2 날조 지문이 편입되지 않았다"
fi
r="$(reason_of)"; [ "$r" = "tokenizer_hash_failed" ] && ok "N2 reason=tokenizer_hash_failed" || bad "N2 reason='$r'"

echo
echo "── N3: 모듈 다이제스트가 rc=0 인데 해시가 부적격 → rc=3 (rc 포착으로는 못 잡는 절반) ──"
mk_stub "$W/s3" file_bad_rc0; run_metric "$W/s3"
[ "$RC" -eq 3 ] && ok "N3 rc=3" || bad "N3 rc=$RC (기대 3) ← 해시 검증 부재"
[ ${#OUT} -eq 0 ] && ok "N3 stdout 0바이트" || bad "N3 stdout='$OUT'"
r="$(reason_of)"; [ "$r" = "tokenizer_hash_failed" ] && ok "N3 reason=tokenizer_hash_failed" || bad "N3 reason='$r'"

echo
echo "── N4: 지문 다이제스트 단독 실패(stdin 형태만) → rc=3 · reason=metric_hash_failed ──"
mk_stub "$W/s4" stdin_fail; run_metric "$W/s4"
[ "$RC" -eq 3 ] && ok "N4 rc=3" || bad "N4 rc=$RC (기대 3)"
[ ${#OUT} -eq 0 ] && ok "N4 stdout 0바이트" || bad "N4 stdout='$OUT'"
r="$(reason_of)"; [ "$r" = "metric_hash_failed" ] && ok "N4 reason=metric_hash_failed" || bad "N4 reason='$r'"

echo
echo "── N5: 지문 다이제스트가 rc=0 인데 해시가 부적격 → rc=3 · reason=metric_hash_failed ──"
mk_stub "$W/s5" stdin_bad_rc0; run_metric "$W/s5"
[ "$RC" -eq 3 ] && ok "N5 rc=3" || bad "N5 rc=$RC (기대 3)"
[ ${#OUT} -eq 0 ] && ok "N5 stdout 0바이트" || bad "N5 stdout='$OUT'"
r="$(reason_of)"; [ "$r" = "metric_hash_failed" ] && ok "N5 reason=metric_hash_failed" || bad "N5 reason='$r'"

echo
echo "── C6: 두 새 토큰이 **소비자 정규식**을 통과하는가 (토큰 안에 rc= 를 넣으면 깨진다) ──"
# 소비자 2곳이 쓰는 동일 정규식: hooks/ccs-write-gate.sh · scripts/ccs-floor-surface.sh
for pair in "tokenizer_hash_failed:path=/x rc=7" "metric_hash_failed:rc=11"; do
  tok="${pair%%:*}"; tail_fields="${pair#*:}"
  got="$(printf 'CCS_METRIC_UNAVAILABLE reason=%s %s\n' "$tok" "$tail_fields" \
        | sed -n 's/^CCS_METRIC_UNAVAILABLE reason=\([a-z_][a-z_]*\).*/\1/p' | head -1)"
  [ "$got" = "$tok" ] && ok "C6 '$tok' 추출 정상 (뒤 필드 '$tail_fields' 무해)" || bad "C6 '$tok' → '$got'"
done

echo
echo "── C7: 범위 밖 불변 — _composition() 은 건드리지 않았다 ──"
COUT="$(CCS_GATE="$GATE" zsh "$SHA_SH" composition 2>/dev/null)"; CRC=$?
[ "$CRC" -eq 0 ] && [ ${#COUT} -eq 64 ] && ok "C7 composition rc=0 · 64-hex (불변)" \
  || bad "C7 composition rc=$CRC len=${#COUT}"
# ★ 정직: `_composition()` 은 **같은 모양의 결함을 그대로 갖는다**(파이프 rc 미포착).
#   이 티켓의 범위가 아니라서 고치지 않았고, 여기서도 그 결함을 단언하지 않는다.
#   범위 논거는 CSR #2288 본문 "범위 밖" 절에 있다 — 무해 증명이 아니다.

echo
echo "── 격리 ──"
REAL_LEDGER_AFTER="$($REAL_SHASUM -a 256 "$REAL_LEDGER" 2>/dev/null | cut -d' ' -f1)"
[ "$REAL_LEDGER_BEFORE" = "$REAL_LEDGER_AFTER" ] && ok "실 원장 sha256 불변" \
  || bad "실 원장이 변했다: $REAL_LEDGER_BEFORE → $REAL_LEDGER_AFTER"

echo
printf '결과: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
