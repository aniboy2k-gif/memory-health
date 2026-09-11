#!/usr/bin/env python3
"""ccs-window-verdict.py — 창 종료 **판정** 한 벌 (CSR #2262 · 설계 r4 P-B · §5.2 · §5.4 · §5.6)

★ 이 파일은 판정만 한다 — 잠금도, 원장 append 도, 게이트 쓰기도, 회전도 하지 않는다.
  그 전이 전체의 직렬화는 호출자(`ccs-window-close.sh`)의 몫이다(설계 §5.1). 한 파일이
  판정과 전이를 겸하면 「단일 직렬화 전이」가 다시 여러 걸음으로 흩어진다.

★ 되돌릴 조건 (P-B) — 축자
    창 안에서 `floor > open_floor` 가 **서로 다른 UTC 날짜 2일 이상** 기록됐거나
    **서로 다른 세션 3개 이상**에서 기록되면 positive.
  피연산자는 **창 개시 시점에 얼어붙은 `open_floor`** 이지 살아 있는 `reference` 가 아니다.
  살아 있는 값을 쓰면 종료 후 Leg 3 강등 탓에 `floor == reference` 가 되어 조건이 **항상 거짓**이
  된다(실측: 종료 후 27/27 행이 `floor == reference`).

★ `open_floor` 는 어디 있나 — **핀의 `floor` 필드가 곧 그것이다** (착지 전제조건 4 의 답)
  설계는 `open_floor` 를 새 필드로 그렸고, 두 필드를 유지할지 합칠지는 "「`cmd_lower` 가 핀의
  `floor` 를 쓰는가」를 재서 정하라" 고 남겼다. 실측 답은 **쓰지 않는다** 이다 —
  `ccs-window-pin.py:92-95` 는 `floor_min_observed`·`updated_at`·`provenance` 만 갱신하고,
  `test-ccs-pin-concurrency.sh` 의 「하향이 floor 를 건드리지 않는가」 케이스가 그것을 이미
  지키고 있다(실측 PASS). 그래서 **합친다**: `open_floor := pin["floor"]`.
  얻는 것 ⑴ 핀 필드 수 8 유지(기존 수용조건 §8.8 불변) ⑵ 같은 값의 두 사본이 갈라질 자리 제거
  ⑶ `open_floor_immutable` 조항은 기존 회귀가 이미 지키는 성질이 된다.
  ★ 파생 결과 하나를 숨기지 않고 적는다: 설계 D8 은 "legacy 선행핀에는 `open_floor` 이 없으니
  타당성 검사를 건너뛴다" 를 전제했는데, 합치면 legacy 핀에도 `floor` 가 **있으므로**
  타당성 검사가 **가능**해진다. 건너뛰기는 `floor` 자체가 없는 손상 핀에만 남는다(더 엄격한 방향).

★ 정직 범위
  이 판정은 **관측행이 말하는 것**만 본다. 행을 남기지 않은 세션, 지워진 행, 회전으로 사라진
  archive 는 보이지 않는다. 판정은 `row_count`·`rows_through` 로 자기가 무엇을 봤는지 밝힌다.

CLI:
  ccs-window-verdict.py --window <id> --rows <jsonl-path|-> [--pin <pin.json>] [--meta <meta.json>]
                        [--gate-before warn|deny|off] [--orphan] [--prev-verdicts <jsonl-path|->]
출력: 판정행 JSON 한 줄 (stdout). 종료: 0 = 판정 산출 · 2 = 입력 오류.
"""
import argparse
import io
import json
import os
import sys

# 되돌릴 조건의 두 limb 임계 (설계 P-B). env override 는 **시험 전용**이며 운영 기본은 이 값이다.
DAYS_LIMB = int(os.environ.get("CCS_VERDICT_DAYS_LIMB", "2"))
SESSIONS_LIMB = int(os.environ.get("CCS_VERDICT_SESSIONS_LIMB", "3"))
# 타당성 대역(설계 P-D): open_floor 대비 이 비율보다 더 낮게 관측되면 의심.
#   25% 는 **판단**이지 측정이 아니다 — R-4 의 기록된 크기(~14k / 29316 ≈ 48%)는 바깥,
#   통상 드리프트는 한참 안쪽. 어떤 probe 도 이 숫자를 검증하지 않고, 기구만 검증한다.
PLAUSIBILITY_BAND = float(os.environ.get("CCS_PIN_PLAUSIBILITY_BAND", "0.25"))

NEG = "window_closed_negative"
POS = "window_closed_positive"
IND = "window_closed_indeterminate"


def _load_rows(path):
    fh = sys.stdin if path == "-" else io.open(path, encoding="utf-8", errors="replace")
    out = []
    try:
        for line in fh:
            line = line.strip()
            if not line or '"' not in line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue          # 손상 줄은 건너뛴다 — 판정을 포기하지는 않는다
            if isinstance(r, dict):
                out.append(r)
    finally:
        if fh is not sys.stdin:
            fh.close()
    return out


def _read_json(path):
    if not path:
        return None
    try:
        with io.open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _utc_day(ts):
    # ts 형식은 `YYYY-MM-DDTHH:MM:SSZ` — 날짜부만 취한다. 형식이 다르면 None.
    if not isinstance(ts, str) or len(ts) < 10 or ts[4] != '-' or ts[7] != '-':
        return None
    return ts[:10]


def open_floor_unanimity(rows, pin_open_floor):
    """§5.4 — 이질적인 행은 **절대 정상 계수하지 않는다**. 반환 (open_floor, operand, reason)."""
    non_null = [r.get("open_floor") for r in rows if isinstance(r.get("open_floor"), int)]
    null_n = len(rows) - len(non_null)
    if not rows:
        return None, "day_limb_only", None          # 행이 없다 — 계수할 것이 없다
    if not non_null:
        return None, "day_limb_only", None          # 전부 구 regime
    if null_n > 0:
        return None, "open_floor", "open_floor_partial_regime"
    distinct = sorted(set(non_null))
    if len(distinct) >= 2:
        return None, "open_floor", "open_floor_not_unanimous"
    val = distinct[0]
    if isinstance(pin_open_floor, int) and val != pin_open_floor:
        return val, "open_floor", "open_floor_row_pin_divergence"
    return val, "open_floor", None


def compute(window_id, rows, pin, meta, gate_before, orphan, prev_rows):
    wrows = [r for r in rows
             if r.get("kind") == "window_observation" and r.get("window_id") == window_id]
    wrows.sort(key=lambda r: (r.get("ts") or "", r.get("session_id") or ""))

    row_count = len(wrows)
    rows_through = None
    if wrows:
        rows_through = "%s#%d" % (wrows[-1].get("ts") or "", row_count)

    pin_open_floor = pin.get("floor") if isinstance(pin, dict) else None
    open_floor, operand, unanimity_reason = open_floor_unanimity(wrows, pin_open_floor)
    legacy = (operand == "day_limb_only")

    # ── 두 limb ────────────────────────────────────────────────────────────
    if legacy:
        # 구 regime: `open_floor` 가 없으므로 "초과"를 알 수 없다. §1 이 정한 과대근사를 쓴다 —
        # **행이 있는 서로 다른 UTC 날짜**. 이 경로는 절대 positive 를 내지 않는다.
        over = wrows
    else:
        over = [r for r in wrows
                if isinstance(r.get("floor"), int) and isinstance(open_floor, int)
                and r["floor"] > open_floor]
    days_over = len({d for d in (_utc_day(r.get("ts")) for r in over) if d})
    sessions_over = len({s for s in (r.get("session_id") for r in over) if s})

    # ── 의심 상태 (P-B(6)) — 무장(arming)이라는 유일한 위험 결정에서 소비된다 ──
    plausibility = (meta or {}).get("plausibility") if isinstance(meta, dict) else None
    composition = (meta or {}).get("composition") if isinstance(meta, dict) else None
    recovered = (meta or {}).get("recovered") if isinstance(meta, dict) else None
    if pin is None:
        plausibility = "pin_absent"
    elif plausibility is None:
        plausibility = "unknown"          # 사이드카 부재 = 구 regime. 의심의 **증거가 아니다**.
    if composition is None:
        composition = "unknown"

    reason = None
    if plausibility == "suspect":
        reason = "suspect_pin"
    elif composition in ("shrunk", "changed_unverifiable"):
        # `changed_unverifiable` = 지문은 달라졌는데 선행 목록이 없어 **방향을 증명할 수 없다**.
        #   설계 §5.2 는 부분집합일 때만 강제하나, 그 판정은 선행 realpath 목록을 전제한다.
        #   목록이 없는 칸(사이드카 이전 핀 = 사실상 최초 회전 1회)에서 `changed` 로 뭉개면
        #   r4 가 가장 위험하다고 지목한 바로 그 자리가 무방비가 된다. 그래서 같이 강제한다.
        reason = "composition_shrunk" if composition == "shrunk" else "composition_unverifiable"
    elif recovered == "orphan_open_indeterminate":
        reason = "open_floor_unreconstructible"
    elif unanimity_reason:
        reason = unanimity_reason
    elif (isinstance(pin, dict) and isinstance(open_floor, int)
          and isinstance(pin.get("floor_min_observed"), int)
          and pin["floor_min_observed"] < open_floor * (1.0 - PLAUSIBILITY_BAND)):
        reason = "implausibility_band"
    elif legacy and days_over >= DAYS_LIMB:
        # 과대근사 위에서 positive 를 낼 수는 없다. 그렇다고 negative 라 말할 근거도 없다.
        reason = "legacy_days_over"

    limbs = []
    if not legacy and reason is None:
        if days_over >= DAYS_LIMB:
            limbs.append("day")
        if sessions_over >= SESSIONS_LIMB:
            limbs.append("session")

    if reason is not None:
        decision = IND
    elif limbs:
        decision = POS
    else:
        decision = NEG

    # ── §5.6 — 가시 카운터. **어떤 카운트도 게이트를 바꾸지 않는다.** ────────
    prev_n = 0
    prev_verdicts = [r for r in (prev_rows or []) if r.get("kind") == "window_verdict"]
    if prev_verdicts:
        prev_verdicts.sort(key=lambda r: r.get("ts") or "")
        last = prev_verdicts[-1]
        if isinstance(last.get("consecutive_indeterminate"), int):
            prev_n = last["consecutive_indeterminate"]
    consecutive = (prev_n + 1) if decision == IND else 0

    # ── 게이트 (P-B(7)) — negative 는 **능동 해제**한다(래치에 해제가 없으면 상태기계가 아니다) ──
    if decision == POS:
        gate_after = "deny"
    elif decision == NEG:
        gate_after = "warn"
    else:
        gate_after = gate_before          # indeterminate 는 **아무것도 쓰지 않는다**

    return {
        "kind": "window_verdict", "row_schema_version": 1,
        "decision": decision,
        "window_id": window_id,
        "legacy": bool(legacy),
        "orphan": bool(orphan),
        "operand": operand,
        "open_floor": open_floor if isinstance(open_floor, int) else None,
        "days_over": days_over,
        "sessions_over": sessions_over,
        "limbs_fired": limbs,
        "plausibility": plausibility,
        "composition": composition,
        "adjudicated_pin_sha": None,      # 호출자가 채운다(핀 바이트를 읽는 쪽이 그쪽이다)
        "gate_before": gate_before,
        "gate_after": gate_after,
        "row_count": row_count,
        "rows_through": rows_through,
        "consecutive_indeterminate": consecutive,
        "indeterminate_reason": reason if decision == IND else None,
    }


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--window", required=True)
    ap.add_argument("--rows", required=True)
    ap.add_argument("--pin", default="")
    ap.add_argument("--meta", default="")
    ap.add_argument("--gate-before", default="warn")
    ap.add_argument("--orphan", action="store_true")
    ap.add_argument("--prev-verdicts", default="")
    a = ap.parse_args()

    rows = _load_rows(a.rows)
    prev = _load_rows(a.prev_verdicts) if a.prev_verdicts else rows
    v = compute(a.window, rows, _read_json(a.pin), _read_json(a.meta),
                a.gate_before, a.orphan, prev)
    print(json.dumps(v, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
