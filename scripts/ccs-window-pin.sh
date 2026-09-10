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
#   ccs-window-pin.sh create <pinfile> <floor> <composition_sha> <metric_sha> [provenance]
#   ccs-window-pin.sh lower  <pinfile> <observed_floor> [provenance]
#   ccs-window-pin.sh read   <pinfile> [field]
# 종료: 0 성공 · 1 거부(사유는 stdout `pin_lower_refused=…`) · 2 인자/환경 오류
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
    mkdir -p "$(dirname "$PIN")" 2>/dev/null
    python3 "$CCS_PIN_HELPER" create "$PIN" "$FLOOR" "$CSHA" "$MSHA" "$PROV"
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
    _die "usage: ccs-window-pin.sh {create|lower|read} ..."
    ;;
esac
