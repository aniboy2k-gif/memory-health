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
  ★ CSR #2262 종료 판정: 설계가 말하는 `open_floor` 가 **바로 이 필드**다(착지 전제조건 4 의 답 —
    `cmd_lower` 가 `floor` 를 건드리지 않는다는 것이 실측·회귀로 확인됨). 두 번째 필드를 만들지
    않는다: 같은 값의 사본이 둘이면 갈라질 자리가 생기고, 핀 필드 수 8 이라는 기존 수용조건(§8.8)도
    깨진다.

★ 창 개시 시점의 **정황**은 핀이 아니라 사이드카 `<pin>.meta.json` 에 둔다
  타당성(plausibility)·멤버십(composition)·선행창·복구표시는 종료 판정이 소비하는 정황이지
  참조 해소(`ccs-reference-resolve.py`)의 피연산자가 아니다. 핀에 섞으면 필드 수 계약이 깨지고
  해소기 입력면이 넓어진다. 사이드카는 핀과 **같은 잠금 안에서** 함께 쓰인다.
  ★ 사이드카가 없으면 `unknown` 이지 `suspect` 가 아니다 — 부재는 의심의 증거가 아니다.
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


def meta_path(pin):
    return pin + ".meta.json"


def cmd_create(path, floor, csha, msha, prov, meta_json="", forced_wid="", opened_at=""):
    if os.path.exists(path):
        print("pin_create_refused=already_exists")
        return 1
    import hashlib
    opened = opened_at or _now()
    # ★ 잔여(명시): `window_id` 는 `sha256(opened_at + composition_sha)[:12]` 이고 `opened_at` 은
    #   **초 단위**다. 따라서 같은 초에 같은 구성으로 만든 두 핀은 **같은 id** 를 갖는다. 그러면
    #   종료 판정의 중복확인이 뒤 창을 `already_adjudicated` 로 건너뛴다. 운영에서는 회전이
    #   세션 시작당 최대 1회이고 창이 20세션을 사는 탓에 사실상 도달하지 않지만, **구조적으로
    #   배제되지는 않는다**. 시험에서는 실제로 밟혔다(그래서 시험이 id 를 명시로 넘긴다).
    #   여기서 고치지 않는 이유: 이 파생식은 출하된 필드의 의미론이고, 바꾸면 기존 핀·행의
    #   id 와 불연속이 생긴다. 고칠 자리는 별도 티켓이다.
    wid = forced_wid or hashlib.sha256((opened + csha).encode('utf-8')).hexdigest()[:12]
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
    # ★ 사이드카를 **먼저** 쓴다. 핀이 있는데 정황이 없으면 `unknown` 으로 흡수되지만,
    #   정황만 있고 핀이 없으면 다음 create 가 그 정황을 남의 창 것으로 읽을 수 있다.
    if meta_json:
        try:
            meta = json.loads(meta_json)
        except ValueError:
            print("pin_create_refused=meta_unparseable")
            return 1
        if not isinstance(meta, dict):
            print("pin_create_refused=meta_not_object")
            return 1
        meta["window_id"] = wid          # 사이드카는 자기가 어느 창 것인지 스스로 말한다
        meta["written_at"] = _now()
        _atomic_write(meta_path(path), meta)
    _atomic_write(path, obj)
    print("pin_created=%s window_id=%s floor=%s" % (path, wid, floor))
    return 0


def cmd_read_meta(path):
    """사이드카를 읽는다. 부재·손상·창 불일치는 전부 **빈 객체**로 — 부재는 의심이 아니다."""
    try:
        obj = _read(meta_path(path))
    except Exception:                        # noqa: BLE001
        print("{}")
        return 0
    if not isinstance(obj, dict):
        print("{}")
        return 0
    try:
        pin = _read(path)
    except Exception:                        # noqa: BLE001
        pin = {}
    if obj.get("window_id") and pin.get("window_id") and obj["window_id"] != pin["window_id"]:
        # 다른 창의 정황이다 — 남의 창 표시를 이 창에 적용하지 않는다.
        print('{"stale_meta":true}')
        return 0
    print(json.dumps(obj, ensure_ascii=False, sort_keys=True))
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
        return cmd_create(path, argv[3], argv[4], argv[5], argv[6],
                          argv[7] if len(argv) > 7 else "",
                          argv[8] if len(argv) > 8 else "",
                          argv[9] if len(argv) > 9 else "")
    if cmd == "read-meta":
        return cmd_read_meta(path)
    if cmd == "lower":
        return cmd_lower(path, argv[3], argv[4] if len(argv) > 4 else "unknown")
    if cmd == "read":
        return cmd_read(path, argv[3] if len(argv) > 3 else "")
    sys.stderr.write("unknown command: %s\n" % cmd)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
