#!/usr/bin/env python3
"""ccs-degraded-latch.py — 지속 측정불가 latch (CSR #2262 Action 5 · 설계 v4 §5 M-g)

무엇을 답하는가:
  "write 게이트가 **연달아** 측정에 실패하고 있는가?"

★ 왜 파생(derived)인가 — 쓰기 경로가 카운터를 올리지 않는다:
  설계 원안은 write 경로가 카운터를 증가시키는 형태였고, 그것은 반려됐다. 이유 세 가지 —
  ⑴ 모든 쓰기가 지나가는 핫패스에 **제어 상태의 writer** 를 놓게 되고
  ⑵ 실패하는 쓰기마다 C-7 의 핀 잠금과 경합하며
  ⑶ write 게이트가 자기가 **피연산자로 읽는 아티팩트를 변이**시키게 된다.
  그래서 latch 는 저장하지 않고, C-6(2)가 이미 의무화한 **결정 행들을 읽어 SessionStart 에서
  유도**한다. 이 파일이 그 유도다.

★ 비용, 명시: 유도라서 latch 는 **최대 한 세션 늦게** 표면화된다. advisory 통제에서
  한 세션의 탐지 지연은 모든 쓰기에 제어 상태 writer 를 두는 것보다 싸다 — 그 거래를
  의도적으로 택했고, 나중에 발견되지 않도록 여기 적어 둔다.

규칙:
  latch := 마지막 write_gate_decision 행들의 **연속 꼬리**가 3건 이상 전부 `unmeasurable`
  해제 := 측정에 성공한 행(`allow`/`deny`)이 **한 건이라도** 뒤에 오면 즉시 0

출력: `<0|1>|<degraded_since ISO 또는 빈칸>|<연속 개수>`
종료: 항상 0 — 이것은 진단이지 게이트가 아니다. 읽을 수 없으면 `0||0`.
"""
import json
import os
import sys

LEDGER = os.environ.get(
    "LEDGER", os.path.expanduser("~/.claude/da-tools/context-budget-audit.jsonl"))
TAIL_LINES = int(os.environ.get("CCS_LATCH_TAIL_LINES", "800"))
THRESHOLD = int(os.environ.get("CCS_LATCH_THRESHOLD", "3"))


def main():
    try:
        with open(LEDGER, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()[-TAIL_LINES:]
    except OSError:
        print("0||0")
        return 0

    decisions = []          # [(decision, ts)] — write 게이트 행만, 파일 순서 그대로
    for ln in lines:
        ln = ln.strip()
        if not ln or '"write_gate_decision"' not in ln:
            continue
        try:
            row = json.loads(ln)
        except ValueError:
            continue
        if row.get("kind") != "write_gate_decision":
            continue
        d = row.get("decision")
        if d:
            decisions.append((d, row.get("ts") or ""))

    run = 0
    since = ""
    for d, ts in reversed(decisions):
        if d == "unmeasurable":
            run += 1
            since = ts or since
        else:
            break                       # 성공한 측정 하나가 latch 를 해제한다

    if run >= THRESHOLD:
        print(f"1|{since}|{run}")
    else:
        print(f"0||{run}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
