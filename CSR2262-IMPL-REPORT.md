# CSR #2262 — P-B / P-C / P-D 착지 보고 (§5.1 · §5.2 · §5.3 · §5.4 · §5.6)

설계 정본 = `da-chain.zd6OOYXiGC/r4-reflected.txt` (883행, 전문 정독).
작업 범위 = **P-B · P-C · P-D 와 §5.1 · §5.2 · §5.3 · §5.4 · §5.6**. P-A · P-E · P-F · P-G 는 소관 밖.

---

## 0. 한 줄 결론

**창이 닫히는데 아무 판정도 인쇄되지 않던 상태는 끝났다.** 라이브 창 `ceea9f87052b` 의 상태를
복사해 재생하면 지금은 판정이 인쇄되고 원장에 남는다(§3 축자). 다만 아래 **정직 범위**를 함께 읽어야
한다 — 이 통제들은 전부 **advisory** 이고, 어느 것도 집행(enforcement)이 아니다.

---

## 1. 바꾼 파일

| 파일 | 상태 | 무엇을 |
|---|---|---|
| `scripts/ccs-window-close.sh` | **신규** | §5.1 단일 직렬화 전이 · §5.3 고아 분류 · §5.6 `gate-recover` · P-B(7) 게이트 쓰기+되읽기 · P-C 회전 CAS |
| `scripts/ccs-window-verdict.py` | **신규** | P-B 판정 규칙 · §5.4 유일성 표 · §5.6 카운터. **판정만 한다** — 잠금·append·게이트·회전 없음 |
| `scripts/ccs-floor-enumerate.sh` | **신규** | 열거자 계약(emit 모드) 구현. zsh 전용, `CCS_FLOOR_JSON` 센티넬 |
| `scripts/ccs-pin-create-plan.py` | **신규** | §5.2 계약 fail-closed 검사 + 멤버십·타당성 표시 산출 |
| `scripts/ccs-window-pin.sh` | 수정 | `create` 가 zsh 열거자를 **서브프로세스로** 돌려 스스로 측정(P-D) · §5.8 픽스처 스코프 · `read-meta` · `recover-open` |
| `scripts/ccs-window-pin.py` | 수정 | 사이드카 `<pin>.meta.json` · 강제 `window_id`/`opened_at` · `read-meta`. **핀 필드는 여전히 정확히 8** |
| `scripts/ccs-floor-surface.sh` | 수정 | 종료 전이 호출(세션 등록 **전**) · 관측행 `open_floor`(schema 1→2) · 한 줄 안의 `창종료=` 필드 · `게이트=정체(N)` · `gate-recover` 디스패치 |
| `tests/test-ccs-window-close.sh` | **신규** | 48 케이스 (RED-first · B5-a/b/c · §5.4 5행 · D1~D13) |

---

## 2. 설계와 다르게 한 것 — 전부 사유와 함께

### 2-1. `open_floor` 를 **새 필드로 만들지 않고 핀의 `floor` 와 합쳤다** (착지 전제조건 4 의 답)

설계는 두 필드를 유지할지 합칠지를 *"`cmd_lower` 가 핀의 `floor` 를 쓰는가"* 실측에 맡겼다.
실측 답은 **쓰지 않는다** — `ccs-window-pin.py` 의 `cmd_lower` 는 `floor_min_observed`·`updated_at`·
`provenance` 만 갱신하고, `test-ccs-pin-concurrency.sh` 의 「하향이 floor 를 건드리지 않는가」 케이스가
이미 그것을 지키고 있다(실측 PASS). 그래서 **합쳤다**.

얻은 것: ⑴ 핀 필드 수 8 유지 → 기존 수용조건 §8.8(`test-ccs-write-gate.sh`)이 그대로 초록
⑵ 같은 값의 두 사본이 갈라질 자리 제거 ⑶ `open_floor_immutable` 조항이 **이미 있는 회귀**로 지켜진다.

★ 파생 결과 하나를 숨기지 않는다: 설계 **D8** 은 "legacy 선행핀에는 `open_floor` 이 없으니 타당성
검사를 건너뛴다" 를 전제했는데, 합치면 legacy 핀에도 `floor` 가 **있으므로** 타당성 검사가
**가능**해진다(더 엄격한 방향). `skipped_legacy_predecessor` 는 `floor` 자체가 없는 손상 핀에만 남는다.

### 2-2. `changed_unverifiable` 칸을 새로 두고, 그것도 indeterminate 를 강제한다

설계 §5.2 의 부분집합(`shrunk`) 판정은 **선행 핀의 realpath 목록**을 전제한다. 그런데 사이드카 이전에
만들어진 핀에는 지문만 있고 목록이 없다 — "지문이 달라졌는데 방향을 증명할 수 없는" 칸이 실재한다.
그 칸을 `changed`(무장 허용)로 뭉개면 r4 가 **가장 위험하다고 지목한 최초 회전**이 바로 그 뭉갬 위에서
일어난다. 그래서 별도 칸으로 이름 붙이고 `shrunk` 와 같이 indeterminate 를 강제한다.
범위: 선행 핀에 목록이 없을 때만 발생 = 사실상 최초 회전 1회. 실패 방향 = 그 창 한 번의 무장 불가(마찰).

### 2-3. `orphan_open` 재수립에서 `opened_at:null` 대신 **하한 타임스탬프**를 쓴다

설계는 `"opened_at":null` + `"opened_at_lower_bound"` 를 그렸다. 그러나 `ccs-reference-resolve.py:52`
가 `opened_at` 을 파싱하지 못하면 `opened_at_unparseable` → **Leg 3 영구 강등**(= 더 약한 게이트)이
된다. 그래서 `opened_at` 에 **최초 관측행의 ts**(증명된 하한)를 넣고, 그것이 하한이라는 사실을
사이드카 `opened_at_is_lower_bound:true` 로 기록한다. 세션 계수는 정확하고 그쪽이 지배적 경계다.

### 2-4. `orphan_open` 의 floor 복구는 `create` 가 아니라 **`recover-open` 이라는 별도 명령**이다

이 경로는 floor 를 이 프로세스의 열거자가 아니라 **내구 관측행**에서 가져온다. `create` 의 불변식
("어떤 핀도 이 프로세스가 돌린 열거자가 내지 않은 floor 를 기록하지 않는다")에 조용한 예외를 만들지
않으려고 이름이 다른 명령으로 분리했고, `floor_source:"rows_reconstructed"` 를 박아 출처를 감출 수
없게 했다. 재기준화하면 H1 이 지목한 「시계 재시작」이 그대로 재발하므로 복구 자체는 필요하다.

### 2-5. 판정행 append 는 `append-gate-audit.sh` 가 아니라 `append-audit-event.sh`

설계 §5.1 은 전자를 이름으로 적었으나, 그 자매는 skip-approval 스키마
(`gate`/`skip_reason`/`user_explicit_approval`)를 **강제**해 판정행을 거부한다. 후자가 스키마 자유이고
**같은 잠금 라이브러리·같은 fail-loud(exit 3) 계약**을 쓴다. 종료코드 검사 의무는 그대로 이행했다.

### 2-6. 열거자 emit 모드를 `check-context-size.sh` 안이 아니라 **어댑터**로 구현

그 파일은 `da-system/da-tools`(다른 담당)에 있고 **수정하지 않았다**. 어댑터는 게이트의 기존 모드
(`--print-floor-realpaths`)와 기존 출력(`hard_tokens=`)만 쓴다. 지문 정의가 두 곳에서 갈라지지 않는지는
약속이 아니라 **probe 로 단언**한다(§3 마지막 케이스, 실측 동치).

### 2-7. 시험 파일 위치

설계 §8 은 `da-system/da-tools/tests/` 를 지정했다. 그 저장소는 범위 밖이라 **수정하지 않았고**,
시험 대상 스크립트와 같은 저장소에 뒀다(한 커밋으로 함께 움직인다). 설계 U5 가 지목한 교차저장소
문제를 새로 만들지 않는 쪽이다.

---

## 3. 실행 출력 — 인용 (실제로 돌린 것만)

### 3-1. 라이브 창 `ceea9f87052b` 재생 (운영 아티팩트는 **읽기만**)

```
복사된 전제: 세션 28/20 · 관측행 119건 · 게이트 warn
--- ccs-window-close.sh close ---
창종료=window_closed_indeterminate pin_rotated=c2330a8cd7e1
rc=0
--- 남은 판정행 ---
{"adjudicated_pin_sha":"46f1ea524187…","composition":"unknown","consecutive_indeterminate":1,
 "days_over":2,"decision":"window_closed_indeterminate","gate_after":"warn","gate_before":"warn",
 "indeterminate_reason":"legacy_days_over","kind":"window_verdict","legacy":true,"limbs_fired":[],
 "open_floor":null,"operand":"day_limb_only","orphan":false,"plausibility":"unknown",
 "row_count":118,"rows_through":"2026-09-11T00:31:19Z#118","sessions_over":28,
 "ts":"2026-09-11T00:51:30Z","window_id":"ceea9f87052b"}
--- 게이트 ---
CCS_WRITE_GATE=warn
```

★ **설계 §4 가 carry 한 값(`window_closed_negative`)과 다르다 — 그리고 그게 맞다.** 그 값은 관측행이
**한 UTC 날짜**에 걸쳐 있던 시점(r0 의 M4)에 계산된 것이다. 오늘 그 창의 행은 `2026-09-10`·`2026-09-11`
**두 날짜**에 걸쳐 있고, 구 regime 행(= `open_floor` 없음)은 P-B(4) 의 day-limb 전용 경로를 타므로
`days_over>=2` → **indeterminate(`legacy_days_over`)** 이고 게이트는 **무변경**이다. 과대근사 위에서
positive 를 낼 수는 없고, 그렇다고 negative 라 말할 근거도 없다 — 설계가 정한 그대로다.
**`negative` 로 보이려고 수치를 맞추지 않았다.**

### 3-2. SessionStart 한 줄 (정본 §10.4 한 줄 상한 유지)

```
줄 수 = 1
CCS_FLOOR: 29457 — 하드캡까지 543 ref=29457 창세션=1/20 창종료=window_closed_indeterminate pin_rotated=9bdff8f18571
--- 이 세션이 남긴 관측행의 open_floor ---
window_observation open_floor= 29457 window_id= 9bdff8f18571 schema= 2
```

### 3-3. 두 종결자 동시성 (§5.1 C1) — 결정적 RED/GREEN

```
PASS  B5-a RED — 잠금 제거판이 창 하나에 판정행 2건을 남겼다. 이 시험은 목표 결함을 실제로 검출한다
PASS  B5-b GREEN — 같은 배리어, 잠긴 판: 판정행 **정확히 1건**
PASS  B5-b 진 프로세스가 **이름 있는 코드**로 말했다 (lock_busy / already_adjudicated / not_closing)
PASS  B5-c 회전 뒤에도 read_rotated(활성+archive)가 archive 의 판정을 본다 — 활성만 읽으면 두 번째를 쓴다
```

★ RED 를 처음에는 못 만들었고(판정행 0건), 원인은 "잠금이 없어서" 가 아니라 **변이판이 임시
디렉토리에 놓여 자매 스크립트를 못 찾아 조용히 0건**을 낸 것이었다. 그 조용한 0 을 RED 성공으로
읽지 않고 파고들어 고쳤다(`CCS_PIN_SH`·`CCS_VERDICT_PY` 를 시험이 명시로 고정). 도구의 침묵을
사실로 받아들이지 않은 자리다.

### 3-4. 전체 스위트 (3회 연속 동일)

```
결과: PASS=48 FAIL=0   (×3, 결정적)
```

포함: RED-first(구 판 27705cf 는 판정을 인쇄도 기록도 하지 않는다) · P-B B1/B2/B3 · P-B(4) B-L1/B-L2 ·
§5.4 5행 전건 · P-B(6) suspect/shrunk · B5-a/b/c · P-C 회전·predecessor·orphan_open(f)·orphan_closed(e) ·
P-D D1·D2·D3·D4·D9·D10·D11·D12·D12b·D6 · §5.8 D13 · §5.6 B7(카운터 3 + 회복 거부 2종 + 성공) ·
열거자↔sha 스크립트 지문 동치 · 격리 3종(실 핀·실 게이트·실 원장 무변경).

---

## 4. 회귀 3종 — rc 와 판정

| 스위트 | 기준선(설치본, 작업 전) | 지금(설치본) | 지금(**내 워크트리 지향**) | 판정 |
|---|---|---|---|---|
| `test-ccs-write-gate.sh` | rc=0 · PASS=40 FAIL=0 | rc=1 · PASS=41 FAIL=3 | rc=1 · **PASS=41 FAIL=3 (동일)** | **내 변경 무관** |
| `test-ccs-degraded-latch.sh` | rc=0 · PASS=8 FAIL=0 | rc=0 · PASS=8 FAIL=0 | rc=0 · **PASS=8 FAIL=0** | PASS |
| `test-ccs-tokenize-equivalence.sh` | rc=0 · PASS=12 FAIL=0 | rc=0 · PASS=12 FAIL=0 | (memory-health 미참조) | PASS |
| `test-ccs-pin-concurrency.sh`(참고) | rc=0 · PASS=9 FAIL=0 | rc=0 · PASS=9 FAIL=0 | rc=1 · PASS=2 FAIL=7 | **인계 필요(§5)** |

★ `test-ccs-write-gate.sh` 의 FAIL 3건은 전부 **P10(per-file 축 = P-A)** 이고 **내 소관이 아니다**.
이 스위트는 오늘 09:35 자동커밋으로 **다른 세션이 P10 케이스를 새로 넣었다**(내 기준선 40/0 → 41/3).
설치본으로 돌려도, 내 워크트리로 돌려도 **같은 3건**이 같은 이유로 실패한다 — 즉 P-A 구현 대기 중인
**의도된 RED** 다. 내가 만든 실패는 0건이다.

```
FAIL  P10⑴ ★rc=0 decision=allow deny_axis='' — 집계는 참조선 안인데 per-file 캡 초과가 통과했다
FAIL  P10⑴ ★행에 projected_file_tokens/per_file_cap 정수가 없다
FAIL  P10⑶ ★rc=2 deny_axis='' — 집계 거부의 축 라벨이 틀렸다
```

★ 이 스위트들은 **설치본**(`~/.claude/skills/memory-health/scripts/` → `claude-forge`)을 시험한다.
내 워크트리는 그 경로가 아니므로, 위 3열은 `CCS_PIN_SH`·`CCS_WINDOW_SHA_SH`·`CCS_REFERENCE_RESOLVER`·
`CCS_FLOOR_SURFACE`·`CCS_LATCH_PY` 를 워크트리로 가리켜 **실제로 다시 돌린** 값이다. 안 돌리고
"영향 없음" 으로 적지 않았다.

---

## 5. 인계 — `test-ccs-pin-concurrency.sh` 한 줄 (da-system 담당 몫)

설계 **D7** 이 이미 지정한 편집이다: *"The four existing test call sites … each gain
`CCS_PIN_FLOOR_OVERRIDE`."* P-D 가 `create` 의 위치인자 `floor` 를 **검사되는 단언**으로 만들었으므로
(설계 D4), 합성 floor 를 쓰는 픽스처는 그 사실을 밝혀야 한다. §5.8 때문에 `CCS_FIXTURE_HOME` 도
함께 필요하다.

```diff
 seed_pin() {  # $1=핀파일  $2=값
   rm -f "$1"
-  CCS_PIN_PROVENANCE=zsh bash "$PIN_SH" create "$1" "$2" "csha-fixed" "msha-fixed" zsh >/dev/null
+  CCS_FIXTURE_HOME="$W" CCS_PIN_FLOOR_OVERRIDE="$2" CCS_PIN_PROVENANCE=zsh \
+    bash "$PIN_SH" create "$1" "$2" "csha-fixed" "msha-fixed" zsh >/dev/null
 }
```

**추측이 아니라 실측이다** — 이 패치를 적용한 **사본**(`/tmp/.../pc-copy.sh`, da-system 원본 무변경)에
내 워크트리를 물려 돌린 결과: `결과: PASS=9 FAIL=0 QUAR=0`.

---

## 6. 정직 범위 — 무엇이 성립하고 무엇이 성립하지 않는가

**모든 통제가 advisory 다. 어느 것도 집행이 아니다.**

- **리스는 협조적이다.** `audit-append-lock.sh:17` 이 스스로 *"cooperative … not a security boundary"*
  라고 밝힌다. 성립하는 것은 **이 코드 경로를 도는 프로세스들 사이에서** 창 하나당 판정이 정확히
  하나이고, 진 프로세스가 아무것도 쓰지 않으며 이름으로 말한다는 것뿐이다. 핀을 손으로 고치거나,
  리스를 안 잡는 종료 경로를 돌리거나, 잠금 디렉토리를 지우는 행위자는 배제되지 않는다.
- **`rm -r ccs-window.sessions/<id>/`** 는 고아 판정도 §5.3 분류도 무력화한다. 여기서 탐지되지 않는다.
- **§5.2 는 변화를 잡지, 틀림을 잡지 못한다.** include 목록 결함이 선행 핀보다 먼저 있었으면 두 지문이
  같은 결함으로 계산돼 비교가 일치하고 아무것도 발화하지 않는다. 진짜 최초 실행에는 기대값 자체가 없다.
- **P-D 의 불변식 범위**: `CCS_PIN_FLOOR_OVERRIDE`·`CCS_ENUMERATOR`·바꿔치기된 `/bin/zsh` 가 없을 때만
  성립한다. 셋 다 행위자가 쓸 수 있다. 없애는 것은 **우발적** 오측정이지 고의가 아니다.
  §5.8 은 **누출**을 닫지 고의를 닫지 않는다(`CCS_FIXTURE_HOME` 까지 세우면 그대로 동작).
- **`gate-recover` 는 승인 경계가 아니다.** 같은 행위자가 언제든 돌릴 수 있다. 사는 것은 **기록**이다 —
  누가 언제 무슨 사유로, 그리고 **통과한 측정을 첨부해** 풀었는가.
- **`deny` 가 무엇을 뜻하는지**: write 게이트가 Write/Edit 을 거부한다는 뜻이다. `Bash` heredoc 은 같은
  바이트를 그대로 쓴다. "예산이 보호된다" 는 문장은 어디에도 쓰지 않았다.
- **새 잔여 (U6, 실제로 밟았다)**: `window_id = sha256(opened_at + composition_sha)[:12]` 이고 `opened_at`
  이 **초 단위**라, 같은 초에 같은 구성으로 만든 두 핀은 **같은 id** 를 갖는다 → 뒤 창이
  `already_adjudicated` 로 조용히 건너뛰어진다. 운영에서는 회전이 세션 시작당 최대 1회라 사실상
  도달하지 않지만 **구조적으로 배제되지는 않는다**. 시험에서는 실제로 밟혀서 시험이 id 를 명시한다.
  여기서 고치지 않은 이유: 출하된 필드의 파생식이라 바꾸면 기존 핀·행의 id 와 불연속이 생긴다.
  **별도 티켓 몫이고, 그 사실을 코드 주석에도 남겼다**(`ccs-window-pin.py`).

---

## 7. 하지 않은 것 — 사유와 함께

| 항목 | 상태 | 사유 |
|---|---|---|
| P-A (per-file 축) | **안 함** | 소관 밖. `test-ccs-write-gate.sh` 의 P10 3건이 그 RED 다 |
| P-E (`da-system/.githooks/pre-push`) | **안 함** | `da-system` 수정 금지 지시. 그 저장소 담당 몫 |
| P-F (`ccs-clauses.tsv` + 적합성 스위트) | **안 함** | 소관 밖 |
| P-G (`ccs-design-v6.md` + 티켓 본문 렌더) | **안 함** | 소관 밖 |
| `check-context-size.sh` 에 emit 모드 추가 | **안 함** | 그 파일은 `da-system` 소속. 대신 어댑터(§2-6) |
| `test-ccs-pin-concurrency.sh` D7 편집 | **안 함** | `da-system` 수정 금지. 패치를 §5 에 실측 검증과 함께 인계 |
| 운영 창 `ceea9f87052b` 실제 종결 | **안 함** | 운영 핀·게이트·원장을 바꾸는 비가역 행위. 재생으로 증거만 제시(§3-1). 실제 종결은 이 코드가 설치본에 반영된 뒤 다음 SessionStart 가 스스로 한다 |
| push · PR | **안 함** | 지시상 오케스트레이터 몫 |
| 설계 U1~U5 | **안 함** | 설계가 스스로 "다음 라운드가 공격할 자리" 로 남긴 미검토 항목. 여기서 답하지 않았고, U6 을 하나 더 실측으로 추가했다(§6) |
