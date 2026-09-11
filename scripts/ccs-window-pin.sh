#!/bin/bash
# ccs-window-pin.sh — 자동로드 예산 참조 핀(`floor_min_observed`)의 **원자적** 갱신기
#
# CSR #2262 Action 1 / C-7. 설계 정본 da #1049 v5 · 착지 설계 da #1054 · grounding #696.
#
# ────────────────────────────────────────────────────────────────────────────
# 무엇을 지키는가 — 한 줄 불변식
#   `ccs-window.start` 의 **`floor_min_observed` 는 단조 비증가다** (내려가기만 하고 절대 안 올라간다).
#
# ★ 왜 잠금이 필요한가 (DA 가 잡아낸 CRITICAL, 이 저장소에서 관측된 전제)
#   잠금 없이 "읽고·비교하고·쓰는" 세 걸음을 하면, 동시 SessionStart 둘이 서로를 덮어써
#   **각자는 내리기만 했는데 핀이 올라간다**:
#       A 가 29,500 을 읽고 29,000 을 계산 · B 가 29,500 을 읽고 28,000 을 계산
#       B 가 28,000 을 씀 → A 가 (자기 옛 읽기값 기준) 29,000 을 씀 → 핀이 28,000 → 29,000 으로 상승
#   이것은 가정이 아니다 — 이 티켓 작업 중 **다른 세션이 같은 저장소를 실제로 수정**했다(관측).
#
# ★ 이 결함의 정확한 이름 (grounding #696 이 내 서술을 정정했다)
#   나는 이것을 "각자 국소 단조성을 지켰는데 전역 불변식이 깨졌다" 로 적었다. 그 표현이 가리키는
#   확립된 부류는 **write skew**(서로 다른 항목에 대한 교차 불변식)이고, 여기는 **같은 항목**에
#   대한 비원자적 read-modify-write 이므로 정확한 이름은 **lost update** 다
#   (Berenson et al., *A Critique of ANSI SQL Isolation Levels*, P4 Lost Update).
#   표준 처방도 그 문헌이 말하는 그대로다 — **읽기와 쓰기 전체를 하나의 직렬화된 연산으로.**
#
# ★ 왜 `mkdir` 잠금인가 (1차 출처 fetch 검증 — grounding #696)
#   `flock` 은 이 기계에 **없다**(실측 `command -v flock` → rc=1).
#   POSIX.1-2024 §4.4: "All file system operations that read or search a directory or that modify
#   the contents of a directory (for example creating, unlinking, or renaming a file) shall operate
#   atomically."  POSIX `mkdir()`: "[EEXIST] The named file exists." / "If -1 is returned, no
#   directory shall be created."
#   ⚠ 정직: `mkdir()` **페이지 자체는 원자성을 명시하지 않는다.** 보장의 출처는 §4.4 의 디렉토리
#     연산 일반 규정이고, 그 문장은 함수명이 아니라 "creating … a file" 이라는 서술로 표현된다.
#   ⚠ 그리고 `mkdir -p` 는 쓰면 안 된다 — 이미 존재해도 오류를 내지 않아, 상호배제가 의존하는
#     바로 그 실패가 사라진다.
#
# ★ 왜 **공용 라이브러리**를 쓰고 게이트의 인라인 사본을 안 쓰는가
#   `check-context-size.sh:538-549` 도 같은 관용구를 쓰지만 **stale 잠금을 회수하지 않고**,
#   busy 일 때 그냥 진행한다. `~/.claude/scripts/lib/audit-append-lock.sh` 는 TTL 로 stale 을
#   회수하고 busy 에 **1 을 반환해 호출자가 결정하게** 한다. 한 번의 SIGKILL 로 영원히 wedge 되는
#   제어 피연산자는 잠금이 없는 것보다 낫지 않다.
#
# ★ 정직 범위 (rules/hook-classification.md Decision Rule)
#   Design-Intent = **Advisory(협조적)**. `audit-append-lock.sh:17` 이 스스로 "cooperative" 라 밝힌다.
#   Effective-Guarantee = 불변식은 **성립한다** — 이 필드의 쓰기 주체 집단이 닫혀 있기 때문이다
#   (Action 1 의 이 코드 경로가 유일한 writer 이고 항상 참여한다).
#   우회 시 깨지는 불변식 한 줄 = "floor_min_observed 는 비증가". **집행(enforcement)이 아니다.**
#
# 사용:
#   ccs-window-pin.sh create    <pinfile> <floor> <composition_sha> <metric_sha> [provenance]
#   ccs-window-pin.sh lower     <pinfile> <observed_floor> [provenance]
#   ccs-window-pin.sh read      <pinfile> [field]
#   ccs-window-pin.sh read-meta <pinfile>          # 창 개시 정황 사이드카
# 종료: 0 성공 · 1 거부(사유는 stdout `pin_lower_refused=…`·`pin_create_refused=…`) · 2 인자/환경 오류
#
# ★ create 의 위치인자 `<floor>`·`<composition_sha>` 는 **검사되는 단언**이다 (설계 P-D).
#   측정 권위는 zsh 열거자이고, 인자가 그 측정과 다르면 `floor_mismatch`·`composition_sha_mismatch`
#   로 거부한다. 서명을 줄이지 않는 이유: 짧아진 위치 서명은 조용한 오용 위험을 만들고
#   불변식은 하나도 더 사지 못한다.
# ────────────────────────────────────────────────────────────────────────────
set -u

CCS_PIN_LOCK_LIB="${CCS_PIN_LOCK_LIB:-$HOME/.claude/scripts/lib/audit-append-lock.sh}"
CCS_PIN_HELPER="$(cd "$(dirname "$0")" && pwd)/ccs-window-pin.py"

_die() { echo "$1" >&2; exit "${2:-2}"; }

[ -r "$CCS_PIN_HELPER" ] || _die "핀 헬퍼 부재: $CCS_PIN_HELPER"

CMD="${1:-}"; shift || true

case "$CMD" in
  read)
    PIN="${1:?pinfile}"; FIELD="${2:-}"
    python3 "$CCS_PIN_HELPER" read "$PIN" "$FIELD"
    ;;

  create)
    PIN="${1:?pinfile}"; FLOOR="${2:?floor}"; CSHA="${3:?composition_sha}"; MSHA="${4:?metric_sha}"
    PROV="${5:-${CCS_PIN_PROVENANCE:-unknown}}"
    # ★ CREATE 도 provenance 로 막는다 (H-7/H-R1). 틀린 인터프리터로 만든 핀은 약 14k 낮게 굳고
    #   내리기 전용이라 **어떤 올바른 측정도 되돌리지 못한다**. LOWER 만 막는 것은 반쪽이다.
    if [ "$PROV" != "zsh" ]; then
      echo "pin_create_refused=provenance:$PROV"
      exit 1
    fi

    # ── P-D: provenance 를 **구조적**으로 만든다 ─────────────────────────────
    # 구 판에서 `provenance` 는 호출자가 **주장**하는 문자열이었다 — `zsh` 라고 적기만 하면
    # bash 가 잰 floor 도 통과했다(R-4: 약 14k 낮게 굳는다). 이제 create 가 **스스로**
    # zsh 열거자를 서브프로세스로 돌려 측정하고, 위치인자는 그 측정에 대한 **단언**이 된다.
    #   · `#!/bin/bash` 는 그대로다 — 재실행(re-exec)도, in-process sourcing 도 하지 않는다.
    #   · 인터프리터는 **절대경로**로 부른다. hook·launchd 가 주는 최소 PATH 에서 맨 `zsh` 가
    #     해소되지 않으면 비대화형 create 마다 `floor_unmeasurable` 이 나고, 대화형 시험만
    #     통과하는 **약한 게이트 방향**의 실패가 된다.
    #   ★ 정직한 불변식의 범위: `CCS_PIN_FLOOR_OVERRIDE`·`CCS_ENUMERATOR`·바꿔치기된 `/bin/zsh`
    #     가 없을 때, 어떤 핀도 **이 프로세스가 돌린 열거자가 내지 않은 floor** 를 기록하지 않는다.
    #     셋 다 행위자가 쓸 수 있다 — 없애는 것은 **우발적** 오측정이지 고의가 아니다.
    ZSH_BIN="${CCS_PIN_ZSH_BIN:-/bin/zsh}"
    ENUM="${CCS_ENUMERATOR:-$(cd "$(dirname "$0")" && pwd)/ccs-floor-enumerate.sh}"
    PLAN="$(cd "$(dirname "$0")" && pwd)/ccs-pin-create-plan.py"
    [ -r "$PLAN" ] || _die "create 계획기 부재: $PLAN"

    # ── §5.8: 픽스처 전용 노브는 **픽스처 경로에서만** 존중한다 ──────────────
    # 라이브 경로에서는 거부하지 않고 **무시**한다(거부는 약한 게이트 방향). 대신 조용하지도
    # 않다 — 무시했다는 사실과 본 변수 이름을 정황에 남긴다. 닫는 것은 **우발적 누출**이지
    # 고의가 아니다(행위자가 `CCS_FIXTURE_HOME` 까지 세우면 그대로 동작한다).
    OVR_NOTE=""
    if [ -n "${CCS_PIN_FLOOR_OVERRIDE:-}${CCS_ENUMERATOR:-}" ]; then
      _fx="${CCS_FIXTURE_HOME:-}"
      _fx_real=""; _pin_real=""
      [ -n "$_fx" ] && _fx_real="$(cd "$_fx" 2>/dev/null && pwd -P)"
      _pin_real="$(cd "$(dirname "$PIN")" 2>/dev/null && pwd -P)"
      case "${_pin_real:-/dev/null}/" in
        "${_fx_real:-/nonexistent-fixture-root}"/*) : ;;   # 픽스처 안 — 존중
        *)
          OVR_NOTE="override_ignored_live_path:$( [ -n "${CCS_PIN_FLOOR_OVERRIDE:-}" ] && printf 'CCS_PIN_FLOOR_OVERRIDE ' ; [ -n "${CCS_ENUMERATOR:-}" ] && printf 'CCS_ENUMERATOR' )"
          unset CCS_PIN_FLOOR_OVERRIDE
          ENUM="$(cd "$(dirname "$0")" && pwd)/ccs-floor-enumerate.sh"
          echo "$OVR_NOTE"
          ;;
      esac
    fi

    mkdir -p "$(dirname "$PIN")" 2>/dev/null

    PRED_PIN="${CCS_PIN_PREDECESSOR_FILE:-}"
    PRED_META="${CCS_PIN_PREDECESSOR_META:-}"

    if [ -n "${CCS_PIN_FLOOR_OVERRIDE:-}" ]; then
      # 픽스처 경로에서만 도달한다(위 §5.8 가드). 합성 floor 이므로 열거를 돌리지 않고,
      # 위치인자 sha 를 그대로 쓴다 — 픽스처가 원하는 형상을 그대로 잡게 한다.
      META_JSON="{\"plausibility\":\"fixture_override\",\"composition\":\"fixture_override\",\"floor_source\":\"CCS_PIN_FLOOR_OVERRIDE\"}"
      python3 "$CCS_PIN_HELPER" create "$PIN" "$CCS_PIN_FLOOR_OVERRIDE" "$CSHA" "$MSHA" "$PROV" \
              "$META_JSON" "${CCS_PIN_WINDOW_ID:-}" "${CCS_PIN_OPENED_AT:-}"
      exit $?
    fi

    if [ ! -x "$ZSH_BIN" ]; then
      echo "pin_create_refused=floor_unmeasurable:no_zsh:$ZSH_BIN"
      exit 1
    fi
    SENT="$(mktemp "${TMPDIR:-/tmp}/ccs-enum.XXXXXX")" || _die "임시파일 실패"
    trap 'rm -f "$SENT"' EXIT
    # stderr 는 버리지 않고 합친다 — 계획기는 **마지막 센티넬 줄**만 취하므로 진단이 섞여도
    # 파싱이 깨지지 않는다. 그리고 "stderr 가 있으면 거부" 는 채택하지 않았다(열거자는
    # 정당하게 경고한다 — 오거부는 핀 부재 → Leg 3 → **약한 게이트** 방향이다).
    "$ZSH_BIN" "$ENUM" > "$SENT" 2>>"$SENT"

    PLAN_OUT="$(CCS_PIN_ZSH_PATH="$ZSH_BIN" python3 "$PLAN" --sentinel "$SENT" \
                  --predecessor-pin "$PRED_PIN" --predecessor-meta "$PRED_META" \
                  --expect-floor "$FLOOR" --expect-composition "$CSHA" --note "$OVR_NOTE")"
    PLAN_RC=$?
    if [ "$PLAN_RC" -ne 0 ]; then
      echo "pin_create_refused=$(printf '%s\n' "$PLAN_OUT" | head -1 | cut -d' ' -f2-)"
      exit 1
    fi
    MEAS_LINE="$(printf '%s\n' "$PLAN_OUT" | sed -n '2p')"
    MEAS_FLOOR="$(printf '%s' "$MEAS_LINE" | cut -f1)"
    MEAS_CSHA="$(printf '%s' "$MEAS_LINE" | cut -f2)"
    META_JSON="$(printf '%s' "$MEAS_LINE" | cut -f3-)"
    if [ -n "${CCS_PIN_RECOVERED:-}" ]; then
      META_JSON="$(META="$META_JSON" REC="$CCS_PIN_RECOVERED" python3 -c '
import json, os
m = json.loads(os.environ["META"]); m["recovered"] = os.environ["REC"]
print(json.dumps(m, ensure_ascii=False, sort_keys=True))')"
    fi
    python3 "$CCS_PIN_HELPER" create "$PIN" "$MEAS_FLOOR" "$MEAS_CSHA" "$MSHA" "$PROV" \
            "$META_JSON" "${CCS_PIN_WINDOW_ID:-}" "${CCS_PIN_OPENED_AT:-}"
    ;;

  read-meta)
    PIN="${1:?pinfile}"
    python3 "$CCS_PIN_HELPER" read-meta "$PIN"
    ;;

  recover-open)
    # ── §5.3 `orphan_open` 복구 — **별도 경로**로 둔 이유 ────────────────────
    # 이 경로는 floor 를 **이 프로세스의 열거자가 아니라 내구 관측행에서** 가져온다. 그래서
    # `create` 의 불변식("어떤 핀도 이 프로세스가 돌린 열거자가 내지 않은 floor 를 기록하지
    # 않는다")을 흐리지 않도록 **이름이 다른 명령**으로 분리했다. 조용한 예외를 만들지 않는다.
    # 정당성: 그 값은 지어낸 수가 아니라 **원래 창이 zsh 열거자로 측정해 행에 적은 그 수**이고,
    # 재기준화하면 H1 이 지목한 「시계 재시작」이 그대로 재발한다. 대신 `floor_source` 에
    # `rows_reconstructed` 를 박아 이 핀이 어디서 왔는지 감출 수 없게 한다.
    PIN="${1:?pinfile}"; RFLOOR="${2:?open_floor}"; CSHA="${3:?composition_sha}"
    MSHA="${4:?metric_sha}"; RWID="${5:?window_id}"; ROPEN="${6:-}"
    case "$RFLOOR" in ''|*[!0-9]*) echo "pin_recover_refused=floor_not_int"; exit 1 ;; esac
    mkdir -p "$(dirname "$PIN")" 2>/dev/null
    META_JSON="{\"plausibility\":\"skipped_recovered\",\"composition\":\"skipped_recovered\",\"recovered\":\"orphan_open\",\"floor_source\":\"rows_reconstructed\",\"opened_at_is_lower_bound\":true,\"composition_sha\":\"$CSHA\"}"
    python3 "$CCS_PIN_HELPER" create "$PIN" "$RFLOOR" "$CSHA" "$MSHA" zsh "$META_JSON" "$RWID" "$ROPEN"
    ;;

  lower)
    PIN="${1:?pinfile}"; OBS="${2:?observed_floor}"
    PROV="${3:-${CCS_PIN_PROVENANCE:-unknown}}"
    if [ "$PROV" != "zsh" ]; then
      echo "pin_lower_refused=provenance:$PROV"
      exit 1
    fi
    [ -f "$PIN" ] || { echo "pin_lower_refused=pin_absent"; exit 1; }

    # ── 잠금 획득 ────────────────────────────────────────────────────────────
    # ★ 읽기가 잠금 **안**에 있어야 한다. 잠금 밖에서 읽고 안에서 쓰면 lost update 가 그대로 남는다.
    if [ ! -r "$CCS_PIN_LOCK_LIB" ]; then
      # 잠금 라이브러리가 없으면 **쓰지 않는다**. 잠금 없이 쓰는 것이 최악이기 때문이다.
      echo "pin_lower_refused=lock_lib_absent"
      exit 1
    fi
    # shellcheck source=/dev/null
    . "$CCS_PIN_LOCK_LIB"
    if ! audit_acquire_lock "$PIN"; then
      # busy 경로는 **명시**한다 — 명시하지 않은 busy 경로가 이 부류 수리가 새는 자리다.
      # 실패 방향(정직): 안 내리면 REFERENCE 가 더 **높게** 남는다 = 더 느슨한 쪽.
      #   ⒜ 비파괴 ⒝ 다음 SessionStart 에 자가 교정 ⒞ 잠금 없이 쓰는 대안은 어떤 후속 세션도
      #   고치지 못하게 불변식을 깬다. 그래서 이 방향을 택했고, 숨기지 않고 적는다.
      echo "pin_lower_refused=lock_busy"
      exit 1
    fi
    trap 'audit_release_lock "$PIN"' EXIT
    python3 "$CCS_PIN_HELPER" lower "$PIN" "$OBS" "$PROV"
    ;;

  *)
    _die "usage: ccs-window-pin.sh {create|lower|read|read-meta} ..."
    ;;
esac
