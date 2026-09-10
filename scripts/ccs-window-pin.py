#!/usr/bin/env python3
"""ccs-window-pin.py — ccs-window.start 의 읽기/생성/하향 (원자적 교체 담당)

CSR #2262 Action 1 / C-7. 잠금은 호출자(ccs-window-pin.sh)가 잡는다 — 이 파일은
**잠금 안에서 실행된다고 가정**하고, 재읽기와 원자적 교체만 책임진다.

★ 왜 재읽기가 여기 있는가
  잠금 밖에서 읽고 잠금 안에서 쓰면 lost update 가 그대로 남는다. 그래서 `lower` 는
  인자로 받은 옛 값을 쓰지 않고 **디스크에서 다시 읽는다**. 이것이 이 파일의 핵심 한 줄이다.

★ 원자적 교체 = mkstemp(같은 디렉토리) + os.replace
  게이트 자신이 기준선을 그렇게 쓴다(check-context-size.sh:608/:612). 같은 디렉토리여야
  os.replace 가 같은 파일시스템 안에서 원자적이다.

★ 불변 필드는 정말 불변으로 다룬다
  `floor` 는 창 개시 시점의 **증거**다(종료 판정이 그것과 대조한다). 그것을 제어 상태로도 쓰면
  한 필드가 감사기록과 가변상태를 겸하게 된다 — 그래서 하향은 `floor_min_observed` 에만 한다.
"""
import io
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

FIELDS = ("opened_at", "floor", "composition_sha", "metric_sha",
          "floor_min_observed", "updated_at", "provenance", "window_id")


def _now():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _read(path):
    with io.open(path, encoding='utf-8') as fh:
        return json.load(fh)


def _atomic_write(path, obj):
    d = os.path.dirname(path) or '.'
    fd, tmp = tempfile.mkstemp(dir=d)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            json.dump(obj, fh, ensure_ascii=False, sort_keys=True)
            fh.write('\n')
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_create(path, floor, csha, msha, prov):
    if os.path.exists(path):
        print("pin_create_refused=already_exists")
        return 1
    import hashlib
    opened = _now()
    wid = hashlib.sha256((opened + csha).encode('utf-8')).hexdigest()[:12]
    obj = {
        "opened_at": opened,
        "floor": int(floor),                 # IMMUTABLE — 창 개시 증거
        "composition_sha": csha,             # IMMUTABLE — 멤버십 (count-free)
        "metric_sha": msha,                  # IMMUTABLE — 측정 의미론
        "floor_min_observed": int(floor),    # 단조 비증가 — 유일한 가변 제어 필드
        "updated_at": opened,
        "provenance": prov,
        "window_id": wid,
    }
    _atomic_write(path, obj)
    print("pin_created=%s window_id=%s floor=%s" % (path, wid, floor))
    return 0


def cmd_lower(path, observed, prov):
    observed = int(observed)
    try:
        obj = _read(path)                    # ★ 잠금 안에서의 재읽기 — 이 줄이 lost update 를 막는다
    except Exception as e:                   # noqa: BLE001 — 손상 핀을 조용히 덮어쓰지 않는다
        print("pin_lower_refused=unreadable:%s" % type(e).__name__)
        return 1
    stored = obj.get("floor_min_observed")
    if not isinstance(stored, int):
        print("pin_lower_refused=malformed_stored")
        return 1
    if observed >= stored:
        # 올리지 않는다. 같아도 쓰지 않는다(불필요한 쓰기 = 불필요한 경쟁).
        print("pin_hold=%d observed=%d" % (stored, observed))
        return 0
    obj["floor_min_observed"] = observed
    obj["updated_at"] = _now()
    obj["provenance"] = prov
    _atomic_write(path, obj)
    print("pin_lowered=%d from=%d" % (observed, stored))
    return 0


def cmd_read(path, field):
    try:
        obj = _read(path)
    except Exception:                        # noqa: BLE001
        print("")
        return 1
    if field:
        v = obj.get(field)
        print("" if v is None else v)
    else:
        print(json.dumps(obj, ensure_ascii=False, sort_keys=True))
    return 0


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: ccs-window-pin.py {create|lower|read} <pinfile> ...\n")
        return 2
    cmd, path = argv[1], argv[2]
    if cmd == "create":
        return cmd_create(path, argv[3], argv[4], argv[5], argv[6])
    if cmd == "lower":
        return cmd_lower(path, argv[3], argv[4] if len(argv) > 4 else "unknown")
    if cmd == "read":
        return cmd_read(path, argv[3] if len(argv) > 3 else "")
    sys.stderr.write("unknown command: %s\n" % cmd)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
