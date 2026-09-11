#!/usr/bin/env python3
"""ccs-pin-create-plan.py — create 시점의 **계약 검사 + 정황 산출** (CSR #2262 · 설계 P-D · §5.2)

호출자(`ccs-window-pin.sh create`)가 zsh 열거자를 서브프로세스로 돌려 얻은 센티넬 JSON 을
이 파일에 넘긴다. 여기서 하는 일은 두 가지뿐이다.
  ⑴ **계약을 fail-closed 로 검사**한다 — 파싱·양의 floor·file_count>0·unreadable==0·
     `file_count == len(realpaths)`. 마지막 등식이 `file_count` 를 장식에서 **두 독립 계수의
     교차검사**로 바꾼다(설계 §5.2(1)).
  ⑵ 선행 핀과 대조해 **멤버십·타당성 표시**를 만든다. 어느 쪽도 **거부하지 않는다** —
     create 에서 거부하면 핀이 없어지고, 핀이 없으면 참조가 Leg 3(current_floor)으로 떨어져
     게이트의 두 연언이 같아진다(= 더 약한 게이트). 의심은 거부가 아니라 **표시**로 나르고,
     종료 판정이 무장(arming)이라는 유일한 위험 지점에서 소비한다.

★ 왜 `shrunk` 만 indeterminate 를 강제하는가
  C2 가 지목한 실패는 **낮게 측정된 floor**(wrong-low)이고, 그것을 만드는 것은 멤버십이
  **줄어들** 때뿐이다. 모든 변화를 의심하면 정당한 통합(per-file 축이 장려하는 바로 그 편집)마다
  창이 indeterminate 로 닫혀, 운영자가 우회하도록 훈련된다. 대신 정당한 삭제도 그 창의 무장
  능력을 한 번 잃는다 — 과도하게 엄격하지만 **종료한다**(다음 창의 선행핀이 줄어든 멤버십을
  기대값으로 갖는다. 래치되지 않는다).

★ `changed_unverifiable` — 설계에 없는 한 칸을 왜 두는가 (명시)
  설계 §5.2 는 부분집합 판정을 위해 선행 핀의 **realpath 목록**을 전제한다. 그런데 사이드카
  이전에 만들어진 핀에는 지문만 있고 목록이 없다 — 그래서 "지문이 달라졌는데 방향을 증명할 수
  없는" 칸이 실재한다. 그 칸을 `changed` 로 뭉개면 r4 가 가장 위험하다고 지목한 **최초 회전**이
  바로 그 뭉갬 위에서 일어난다. 그래서 이 칸은 `shrunk` 와 같이 **indeterminate 를 강제**한다.
  범위: 선행 핀에 목록이 없을 때만 발생하므로 사실상 최초 회전 1회이고, 그 다음 창부터는
  목록이 있으므로 사라진다. 실패 방향 = 그 창 한 번의 무장 불가(마찰) 이지 안전 손실이 아니다.

CLI: ccs-pin-create-plan.py --sentinel <file|-> [--predecessor-pin <f>] [--predecessor-meta <f>]
                            [--expect-floor N] [--expect-composition SHA] [--note TEXT]
출력: `REFUSE <code>` 또는 `OK` + 다음 줄에 `<floor>\t<composition_sha>\t<meta_json>`
종료: 0 = OK · 1 = REFUSE · 2 = 입력 오류
"""
import argparse
import io
import json
import os
import sys

BAND = float(os.environ.get("CCS_PIN_PLAUSIBILITY_BAND", "0.25"))


def _read_text(p):
    if p == "-":
        return sys.stdin.read()
    with io.open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def _read_json(p):
    if not p:
        return None
    try:
        with io.open(p, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def parse_sentinel(text):
    """마지막 센티넬 줄만 취한다 — `/etc/zshenv` 등이 앞에 무엇을 찍어도 파싱이 깨지지 않는다."""
    found = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("CCS_FLOOR_JSON "):
            found = line[len("CCS_FLOOR_JSON "):]
    if found is None:
        return None
    try:
        obj = json.loads(found)
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--sentinel", required=True)
    ap.add_argument("--predecessor-pin", default="")
    ap.add_argument("--predecessor-meta", default="")
    ap.add_argument("--expect-floor", default="")
    ap.add_argument("--expect-composition", default="")
    ap.add_argument("--note", default="")
    a = ap.parse_args()

    try:
        text = _read_text(a.sentinel)
    except OSError:
        print("REFUSE floor_unmeasurable")
        return 1

    s = parse_sentinel(text)
    if s is None:
        print("REFUSE floor_unmeasurable")
        return 1

    floor = s.get("floor")
    fc = s.get("file_count")
    unread = s.get("unreadable")
    csha = s.get("composition_sha")
    rp = s.get("realpaths")

    if not isinstance(floor, int) or floor <= 0 or not isinstance(csha, str) or not csha:
        print("REFUSE floor_unmeasurable")
        return 1
    if not isinstance(fc, int) or not isinstance(unread, int) or not isinstance(rp, list):
        print("REFUSE floor_incomplete")
        return 1
    if fc <= 0 or unread > 0 or fc != len(rp):
        print("REFUSE floor_incomplete")
        return 1

    # 위치인자는 **검사되는 단언**이다 (설계 P-D). 측정이 권위이고, 인자는 그 측정과 맞아야 한다.
    #   `-` = "단언하지 않음". 운영 호출자(회전·고아 복구)는 기대값을 모르는 것이 정상이라
    #   `-` 를 넘긴다 — 모르는 값을 지어내 단언하는 것보다 단언하지 않는 편이 정직하다.
    if a.expect_floor and a.expect_floor != "-" and a.expect_floor.isdigit() \
            and int(a.expect_floor) != floor:
        print("REFUSE floor_mismatch:arg=%s measured=%d" % (a.expect_floor, floor))
        return 1
    if a.expect_composition and a.expect_composition != "-" and a.expect_composition != csha:
        print("REFUSE composition_sha_mismatch")
        return 1

    pred = _read_json(a.predecessor_pin)
    pmeta = _read_json(a.predecessor_meta) or {}

    # ── 멤버십 (§5.2) ──────────────────────────────────────────────────────
    removed, added = [], []
    if pred is None:
        composition = "skipped_no_predecessor"
        pred_csha = None
    else:
        pred_csha = pred.get("composition_sha")
        pred_rp = pmeta.get("realpaths") if isinstance(pmeta.get("realpaths"), list) else None
        if pred_csha == csha:
            composition = "unchanged"
        elif pred_rp is None:
            # 지문은 달라졌는데 선행 목록이 없어 **방향을 증명할 수 없다**.
            composition = "changed_unverifiable"
        else:
            now_set, old_set = set(rp), set(pred_rp)
            removed = sorted(old_set - now_set)
            added = sorted(now_set - old_set)
            composition = "shrunk" if (removed and not added) else "changed"

    # ── 타당성 (P-D) — 거부하지 않는다. 표시만 한다. ────────────────────────
    if pred is None:
        plausibility = "skipped_no_predecessor"
    elif not isinstance(pred.get("floor"), int):
        plausibility = "skipped_legacy_predecessor"
    elif floor < pred["floor"] * (1.0 - BAND):
        plausibility = "suspect"
    else:
        plausibility = "ok"

    meta = {
        "plausibility": plausibility,
        "composition": composition,
        "composition_sha": csha,
        "predecessor_window_id": (pred or {}).get("window_id"),
        "predecessor_composition_sha": pred_csha,
        "predecessor_floor": (pred or {}).get("floor"),
        "removed_paths": removed,
        "added_paths": added,
        "realpaths": rp,
        "file_count": fc,
        "floor_source": "enumerator",
        "zsh_path": os.environ.get("CCS_PIN_ZSH_PATH") or None,
        "note": a.note or None,
    }
    print("OK")
    print("%d\t%s\t%s" % (floor, csha, json.dumps(meta, ensure_ascii=False, sort_keys=True)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
