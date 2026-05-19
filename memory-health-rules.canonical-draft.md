# version: 1.0.0
# canonical-status: draft (Phase D-1, 2026-05-19)
# canonical-location: claude-forge/rules/memory-health-rules.md (예정)
# projection-targets:
#   - ~/.claude/skills/memory-health/memory-health-rules.md (chmod 444, Mirror sync)
# sync-policy: unidirectional canonical → projection (§7-D-3-A 정합)
# last-updated: 2026-05-19
# csr-master: CSR #659 (Phase D-1) · CSR #658 (Phase C) · CSR #656 (Phase A+B) · CSR #655 (DA)
# memory-health-rules.md — Optimizer 판단 기준 (R1~R6)
#
# 이 파일은 /memory-health --fix 실행 시 Optimizer 가 MEMORY.md 최적화 후보를
# 선정하는 규칙을 정의한다. 즉흥적 판단 금지 — 이 파일에 없는 기준은 적용 불가.
#
# 본 파일은 canonical (claude-forge/rules/) 위치에 거주하며, LOCAL projection 은
# chmod 444 read-only 로 단방향 동기화된다 (§7-D-3-A · cross-ssot-sync.md §3 정합).
# 직접 수정 금지 — 변경은 canonical 위치에서 외부 git PR 절차로만 진행한다.
#
# 사용자 환경에 맞게 규칙을 수정하려면 canonical 위치에서 PR 을 생성한다.

## R1: 중복 포인터 제거

동일한 파일 경로를 참조하는 포인터가 MEMORY.md 내에 2개 이상 존재하면,
가장 최근 것 또는 가장 구체적인 것 1개만 남기고 나머지를 제거한다.

**판정 기준**: 동일 파일명이 포인터 형식(`파일경로 [...]`)으로 2회 이상 등장

**예외**: 서로 다른 트리거 조건이 있는 경우 중복으로 보지 않는다

---

## R2: 만료된 프로젝트 포인터 제거

트리거 조건이 더 이상 유효하지 않은 포인터(완결된 프로젝트, 삭제된 파일 참조)를
후보로 표시한다. 사용자 확인 후 제거한다.

**판정 기준**:
- 참조 파일이 실제로 존재하지 않는 경우 (자동 감지)
- 프로젝트 상태가 "완결"로 명시된 경우 (사용자 확인 필요)

**주의**: 자동 판단으로 삭제 불가 — 반드시 사용자 확인 후 제거

---

## R3: 과도한 인라인 내용을 포인터로 전환

MEMORY.md 에 직접 작성된 내용이 10줄을 초과하는 경우, 별도 파일로 분리하고
포인터로 교체하는 것을 제안한다.

**판정 기준**: 단일 섹션(## 헤더 ~ 다음 ## 헤더 사이)이 10줄 초과

**처리**: 별도 `memory/` 파일 생성 후 MEMORY.md 에 포인터 삽입

---

## R4: 비활성 피드백 메모리 아카이브

`feedback_` 접두어 파일이 포인터에 등록되어 있으나 최근 30일간 참조 기록이
없는 경우, `violation-archive.md` 로 이동을 제안한다.

**판정 기준**: 포인터 파일의 마지막 수정일 기준 30일 초과 + feedback_ 접두어

**주의**: 자동 판단으로 삭제 불가 — 반드시 사용자 확인 후 처리

---

## R5: 테이블 행 압축

MEMORY.md 내 마크다운 테이블에서 내용이 비어 있거나 "—" 만 있는 행을 제거하여
테이블을 압축한다.

**판정 기준**: 테이블 행의 모든 데이터 셀이 빈 값 또는 "—" 인 경우

**처리**: 해당 행 삭제. 테이블 헤더와 구분선은 유지.

---

## R6: Sidecar Fingerprint (Idempotency Invariant)

> **신설**: 2026-05-19 — CSR #656 DA Tier 1 C-4 정합 (압축 death spiral 차단). 본 R6 은 R1~R5 의 idempotency 보장 layer.

memory-health 가 변경한 파일은 **별도 sidecar 파일에 fingerprint** 기록한다. 동일 입력 재실행 시 sidecar hash 비교로 **중복 변경 차단**.

### Sidecar 위치 (User memory 외부)

```
~/.claude/da-tools/memory-health-fingerprints/{file-path-sha256-prefix}.json
```

> **중요 (ChatGPT C-2 정합)**: fingerprint marker 자체는 user memory 파일 외부 저장 — **inline marker 금지** (user memory contamination 차단).

### Sidecar 스키마

```json
{
  "file_path": "/Users/.../MEMORY.md",
  "last_run_sha256": "abc123...",
  "last_run_rules": ["R1", "R5"],
  "last_run_timestamp": "2026-05-19T10:00:00Z",
  "tool_version": "1.1.0",
  "rule_version": "1.0.0"
}
```

### 동작

1. **변경 전**: 현 파일 sha256 → sidecar `last_run_sha256` 비교
2. **일치**: 변경 차단 (이미 적용됨, idempotency 보장) — stderr 안내 + exit 0
3. **불일치**: 변경 진행 + sidecar 갱신 (atomic write: `.tmp` → rename)
4. **신규**: sidecar 부재 = 첫 실행 — 변경 진행 후 sidecar 생성

### Edge case

- 사용자 직접 편집 → sha256 불일치 → 변경 진행 (정상)
- sidecar 손상/삭제 → 변경 + sidecar 재생성
- TOCTOU → atomic rename + 변경 도중 hash 재검증

### 제약 (구현 시)

- Sidecar 디렉토리 = `~/.claude/da-tools/memory-health-fingerprints/` (별도 SYNC, claude-forge 비대상)
- sidecar 는 user memory 아님 — 도구 metadata (DA C-3 privacy 정합)

---

## 적용 순서

R1(중복) → R2(만료) → R5(테이블 압축) → R3(인라인→포인터) → R4(비활성 피드백) → **R6(fingerprint 갱신)**

R4 는 사용자 데이터 보존 위험이 있으므로 마지막에 제안한다.
R6 은 R1~R5 적용 후 sidecar 갱신 — 항상 마지막 단계.

---

## Atomicity 동작 흐름 (CSR #658 Phase C 정합)

본 rules 의 R1~R6 적용은 WAL + Journal + Backup 3중 안전망 위에서 진행한다.

```bash
# 1. WAL init (prepare phase)
wal_id=$(memory-wal.sh init "$files" "$rules")

# 2. Backup (변경 직전 보장)
memory-backup.sh --wal-id "$wal_id"

# 3. R1~R6 적용 — 실제 파일 변경

# 4. Journal log (append-only audit + sha256 chain)
memory-journal.sh log <action> "$files" "$rules" "$wal_id" '{...}'

# 5. WAL commit (atomic 완료 신호)
memory-wal.sh commit "$wal_id"
```

중단 시: WAL 잔존 → 다음 실행 시 `memory-wal.sh recover` 가 자동 감지 → 사용자 확인 후 `rollback` + `git checkout` 또는 backup 복구.

---

## 변경 이력

| 버전 | 일자 | 변경 |
|------|------|------|
| 1.0.0 | 2026-04 | R1~R5 신설 |
| 1.0.0 | 2026-05-19 | R6 신설 (CSR #656 Phase B), Atomicity 동작 흐름 추가 (CSR #658 Phase C) |
| 1.0.0 (draft) | 2026-05-19 | canonical 메타 헤더 추가 (Phase D-1, CSR #659) — 외부 PR 머지 시 정식 1.0.0 발효 |

다음 세션 D-2 진입 시 본 draft 를 `claude-forge/rules/memory-health-rules.md` 로 복사 + commit + 외부 PR.
