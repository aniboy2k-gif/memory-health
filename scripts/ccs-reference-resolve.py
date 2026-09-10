#!/usr/bin/env python3
"""ccs-reference-resolve.py — REFERENCE 해소기 **한 벌** (CSR #2262 · 설계 v4 §3 C-3 / §4 H-9)

★ 왜 별도 파일인가 — 조항 이름이 그것을 요구한다:
  C-3 은 「**단일 값, 두 소비자**」다. 두 소비자 =
    ⑴ SessionStart 표면화 (`ccs-floor-surface.sh`)  ⑵ write 게이트 (`hooks/lib/ccs-write-gate.py`)
  착지 감사에서 **소비자 ⑴ 이 규칙을 아예 갖고 있지 않다**는 것이 실측됐다 — `window_id` 가
  비어 있지 않으면 `floor_min_observed` 를 그대로 REFERENCE 로 쓰고, 두 sha 도 창 경계도
  검사하지 않았다. 같은 무효 핀에 대해 ⑴ 은 `ref_leg=2 ref_stale=0`(거짓 건강 신호), ⑵ 는
  `ref_leg=3 ref_stale=1 ref_reason=composition` 을 냈다.
  그것이 왜 중대한가: 설계 §10 의 **Action 5 되돌릴 조건이 ⑴ 이 쓰는 관측행의 그 두 필드에
  결박**돼 있다 — *"If that first observation shows ref_leg=3 or ref_stale=1 …"*.
  그 필드를 무조건 2/0 으로 쓰는 소비자는 **되돌릴 조건을 구조적으로 발동 불가능하게** 만든다.
  이 파일이 그 규칙을 한 곳에 두어, 두 소비자가 같은 값을 같은 근거로 얻게 한다.

규칙 (설계 축자):
  REFERENCE := min(PIN.floor_min_observed, TOTAL_HARD_TOKENS)  if PIN VALID -> ref_leg=2
             := current_floor                                   otherwise    -> ref_leg=3, ref_stale=1
  PIN VALID iff composition_sha 일치 AND metric_sha 일치 AND 창이 열려 있음(세션<20 AND 14일 미만)

★ 정직 범위: 이것은 **해소**만 한다. 판정(`deny iff …`)은 소비자 ⑵ 의 몫이고, 표면화는
  소비자 ⑴ 의 몫이다. 한 파일이 세 가지를 다 하면 다시 합쳐지는 것이므로 여기서 멈춘다.

CLI:  ccs-reference-resolve.py <pin> <current_floor> <hard_cap> <comp_sha> <metric_sha> <sessions_root>
출력: `reference|ref_leg|ref_stale|ref_reason`  (ref_reason 은 유효 시 빈 문자열)
종료: 항상 0 — 이것은 해소기이지 게이트가 아니다.
"""
import calendar
import json
import os
import sys

MAX_SESSIONS = int(os.environ.get("CCS_WINDOW_MAX_SESSIONS", "20"))
MAX_DAYS = float(os.environ.get("CCS_WINDOW_MAX_DAYS", "14"))


def read_pin(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def window_open(pin, sessions_root, max_sessions=MAX_SESSIONS, max_days=MAX_DAYS):
    """창이 열려 있는가 — 세션 수와 나이 두 경계 (v5 §7 그대로). 반환 (open?, 닫힌 사유)."""
    wid = pin.get("window_id")
    if not wid:
        return False, "window_id_absent"

    try:
        t = __import__("time").strptime(pin.get("opened_at") or "", "%Y-%m-%dT%H:%M:%SZ")
        # `opened_at` 은 UTC(`Z`)이므로 UTC 로 해석하는 `calendar.timegm` 을 쓴다.
        age_days = (__import__("time").time() - calendar.timegm(t)) / 86400.0
    except (ValueError, OverflowError):
        return False, "opened_at_unparseable"
    if age_days >= max_days:
        return False, "age"

    try:
        n = sum(1 for e in os.scandir(os.path.join(sessions_root, wid)) if e.is_dir())
    except OSError:
        # 세션 수를 모르면 창을 **닫는 쪽**(엄격)으로 간다.
        return False, "session_registry_unreadable"
    if n >= max_sessions:
        return False, "sessions"
    return True, ""


def resolve(pin, current_floor, hard_cap, comp_sha, metric_sha, sessions_root):
    """C-3 — 단일 값. 반환 (reference, ref_leg, ref_stale, ref_reason)."""
    if pin is None:
        return current_floor, 3, 1, "pin_absent"
    if pin.get("composition_sha") != comp_sha:
        return current_floor, 3, 1, "composition"
    if pin.get("metric_sha") != metric_sha:
        return current_floor, 3, 1, "metric"
    okw, why = window_open(pin, sessions_root)
    if not okw:
        return current_floor, 3, 1, why
    fmo = pin.get("floor_min_observed")
    if not isinstance(fmo, int):
        return current_floor, 3, 1, "floor_min_observed_not_int"
    return min(fmo, hard_cap), 2, 0, ""


def main():
    if len(sys.argv) != 7:
        print("usage: ccs-reference-resolve.py <pin> <current_floor> <hard_cap> "
              "<comp_sha> <metric_sha> <sessions_root>", file=sys.stderr)
        return 0
    pin_path, cf, cap, csha, msha, sroot = sys.argv[1:7]
    try:
        cf_i, cap_i = int(cf), int(cap)
    except ValueError:
        # floor 를 모르면 참조도 못 낸다 — 빈 값으로 정직하게 돌려준다.
        print("|3|1|current_floor_unknown")
        return 0
    ref, leg, stale, reason = resolve(read_pin(pin_path), cf_i, cap_i, csha, msha, sroot)
    print(f"{ref}|{leg}|{stale}|{reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
