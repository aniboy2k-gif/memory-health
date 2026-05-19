# version: 1.0.0
# memory-health-rules.md — Optimizer 판단 기준 (R1~R5)
#
# 이 파일은 /memory-health --fix 실행 시 Optimizer가 MEMORY.md 최적화 후보를
# 선정하는 규칙을 정의한다. 즉흥적 판단 금지 — 이 파일에 없는 기준은 적용 불가.
#
# 사용자 환경에 맞게 규칙을 수정하여 사용하세요.

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

MEMORY.md에 직접 작성된 내용이 10줄을 초과하는 경우, 별도 파일로 분리하고
포인터로 교체하는 것을 제안한다.

**판정 기준**: 단일 섹션(## 헤더 ~ 다음 ## 헤더 사이)이 10줄 초과

**처리**: 별도 `memory/` 파일 생성 후 MEMORY.md에 포인터 삽입

---

## R4: 비활성 피드백 메모리 아카이브

`feedback_` 접두어 파일이 포인터에 등록되어 있으나 최근 30일간 참조 기록이
없는 경우, `violation-archive.md`로 이동을 제안한다.

**판정 기준**: 포인터 파일의 마지막 수정일 기준 30일 초과 + feedback_ 접두어

**주의**: 자동 판단으로 삭제 불가 — 반드시 사용자 확인 후 처리

---

## R5: 테이블 행 압축

MEMORY.md 내 마크다운 테이블에서 내용이 비어 있거나 "—"만 있는 행을 제거하여
테이블을 압축한다.

**판정 기준**: 테이블 행의 모든 데이터 셀이 빈 값 또는 "—"인 경우

**처리**: 해당 행 삭제. 테이블 헤더와 구분선은 유지.

---

## R6: Sidecar Fingerprint (Idempotency Invariant)

> **신설**: 2026-05-19 — CSR #656 DA Tier 1 C-4 정합 (압축 death spiral 차단). 본 R6은 R1~R5의 idempotency 보장 layer.

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
2. **일치**: 변경 ❌ (이미 적용됨, idempotency 보장) — stderr 안내 + exit 0
3. **불일치**: 변경 진행 + sidecar 갱신 (atomic write: `.tmp` → rename)
4. **신규**: sidecar 부재 = 첫 실행 — 변경 진행 후 sidecar 생성

### Edge case

- 사용자 직접 편집 → sha256 불일치 → 변경 진행 (정상)
- sidecar 손상/삭제 → 변경 + sidecar 재생성
- TOCTOU → atomic rename + 변경 도중 hash 재검증

### 제약 (구현 시 — 후속 세션)

- Sidecar 디렉토리 = `~/.claude/da-tools/memory-health-fingerprints/` (별도 SYNC, claude-forge 비대상)
- sidecar는 user memory ❌ — 도구 metadata (DA C-3 privacy 정합)

---

## 적용 순서

R1(중복) → R2(만료) → R5(테이블 압축) → R3(인라인→포인터) → R4(비활성 피드백) → **R6(fingerprint 갱신)**

R4는 사용자 데이터 보존 위험이 있으므로 마지막에 제안한다.
R6은 R1~R5 적용 후 sidecar 갱신 — 항상 마지막 단계.
