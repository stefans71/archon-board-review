---
description: Run Multi-model governance review on implemented code (post-PR)
argument-hint: (no arguments - reads from workflow artifacts)
---

# Board Review Code

**Workflow ID**: $WORKFLOW_ID

---

## Your Mission

Run a Multi-model board review on the implemented code after Archon's native review
agents have completed. Three agents review the code diff following the 4-round SOP, then author
fix artifacts for FIX NOW items.

**Single-writer architecture:** This step produces findings and fix artifacts ONLY. It does NOT
apply fixes to the branch. Archon's `implement-fixes` is the sole branch mutator. Fix artifacts
are appended to `consolidated-review.md` using Archon-compatible severities so `implement-fixes`
can consume them alongside Archon's native review findings.

**This step does NOT modify code** — it reviews and produces artifacts.

---

## Phase 0: CONFIG — Resolve Paths

### 0.1 Load Configuration

```bash
CONFIG_FILE="$HOME/.archon-board-review/config.yaml"
test -f "$CONFIG_FILE" || { echo "ERROR: Run 'archon-board-review setup' first"; exit 1; }
```

Extract: `BOARD_DIR`, `BOARD_USER`, per-agent `{cli, model, flags, timeout, env_*}`, `diff_size_limit` (default 51200), `diff_partition_strategy` (default "by-category").

### 0.2 Resolve Agent Settings

Same as `archon-board-review-plan.md` Phase 0.2 — extract CLI, model, flags, timeout, and env vars for each agent from config.

**PHASE_0_CHECKPOINT:**

- [ ] Config loaded
- [ ] Board dir and agent settings resolved
- [ ] Diff size limit and partition strategy set

---

## Phase 1: LOAD — Read Review Context

### 1.1 Load Scope

```bash
cat $ARTIFACTS_DIR/review/scope.md
```

Extract: changed files, file categories, focus areas, scope limits ("NOT Building" sections).

### 1.2 Get PR Diff

```bash
PR_NUMBER=$(cat $ARTIFACTS_DIR/.pr-number)
DIFF=$(gh pr diff $PR_NUMBER)
DIFF_SIZE=$(echo "$DIFF" | wc -c)
echo "Diff size: $DIFF_SIZE bytes"
```

### 1.3 Load Archon Review Summary

```bash
cat $ARTIFACTS_DIR/review/consolidated-review.md
```

Note what Archon's 5 agents already found — avoid duplicating their findings.

### 1.4 Load Plan Context (if available)

```bash
cat $ARTIFACTS_DIR/plan-context.md 2>/dev/null || echo "No plan context"
cat $ARTIFACTS_DIR/board-review.md 2>/dev/null || echo "No prior board review"
```

### 1.5 Verify Board Paths

Board paths were resolved in Phase 0 from config. Verify they exist:

```bash
test -d "$BOARD_DIR" || { echo "ERROR: Board dir $BOARD_DIR not found"; exit 1; }
```

**PHASE_1_CHECKPOINT:**

- [ ] Scope loaded
- [ ] Diff obtained and size measured
- [ ] Archon review summary loaded
- [ ] Board paths set

---

## Phase 1.5: PARTITION — Handle Large Diffs

### Size-Based Strategy

If `$DIFF_SIZE` < 50KB (51200 bytes):
> Full diff inline. Proceed to Phase 2.

If `$DIFF_SIZE` between 50KB and 100KB:
> Include executive summary + file index + full diff. All agents receive the same complete artifact.

If `$DIFF_SIZE` > 100KB:
> Split into focused sessions by subsystem using `scope.md` file categories (Source, Test, Config, Docs).
> Each category chunk gets its own 4-round review. Merge all findings before Phase 8.

```bash
if [ "$DIFF_SIZE" -gt 102400 ]; then
  echo "LARGE DIFF: $DIFF_SIZE bytes. Splitting by subsystem."
  # Parse scope.md for file categories, create per-category diffs
  # Run Phase 2-7 for each chunk, collect all findings
elif [ "$DIFF_SIZE" -gt 51200 ]; then
  echo "MEDIUM DIFF: $DIFF_SIZE bytes. Adding summary + index."
  # Prepend file-level summary and section index to the diff
fi
```

**PHASE_1.5_CHECKPOINT:**

- [ ] Diff size evaluated
- [ ] Partitioning strategy selected (inline / summary+index / split)
- [ ] Chunks prepared (if splitting)

---

## Phase 2: PRE-FLIGHT — Verify Board Environment

Same as plan review: check board user, agent directories, CLIs, credentials, lock.
See `archon-board-review-plan.md` Phase 2 for full details.

**PHASE_2_CHECKPOINT:**

- [ ] Board environment verified
- [ ] Lock acquired

---

## Phase 3: BRIEF — Write Agent Briefs

### 3.1 Compose the Brief

Write a brief containing:

1. **Review type**: Code review (NOT plan review) — reviewing actual implemented code
2. **Context**: What the project does, what this PR changes, what the plan intended
3. **Diff** (or chunk) inline — follow size limits from Phase 1.5
4. **Scope limits** — "NOT Building" sections from scope.md. Do NOT flag intentional exclusions.
5. **Archon review summary** — what the 5 native agents already found. Focus on gaps they missed.
6. **Evaluation criteria**:
   - Architectural correctness: does the implementation match the plan's design intent?
   - Semantic bugs: logic errors that pass tests but produce wrong outcomes
   - Cross-cutting concerns: changes that affect multiple subsystems
   - Security: vulnerabilities the native review agents may miss
7. **Output format**: Numbered findings with severity (FIX NOW / DEFER / INFO)
8. **Deferred items**: Include any deferred items from prior reviews as active evaluation targets.

### 3.2 Write to Inboxes

```bash
for AGENT in pragmatist systems-thinker skeptic; do
  echo "$CONTEXT" > "$BOARD_DIR/$AGENT/inbox/context.md"
  echo "$BRIEF" > "$BOARD_DIR/$AGENT/inbox/brief.md"
done
```

**PHASE_3_CHECKPOINT:**

- [ ] Brief composed with diff inline (respecting size limits)
- [ ] Archon review summary included (to avoid duplication)
- [ ] Brief written to all 3 agent inboxes

---

## Phase 4-7: 4-ROUND SOP

Follow the standard 4-round SOP exactly as in `archon-board-review-plan.md`:

- **Phase 4: Round 1** — Blind review (all agents in parallel)
- **Phase 5: Round 2** — Consolidation (group findings, classify, tiebreak)
- **Phase 6: Round 3** — Deliberation (if disagreements; skip if unanimous)
- **Phase 7: Round 4** — Confirmation (SIGN OFF or BLOCK)

Use the same agent invocation patterns, timeouts, retry logic, and checkpoint
structure as the plan review command.

---

## Phase 7.5: FIX ARTIFACT AUTHORING

**Skip this phase if zero FIX NOW items.**

### 7.5.1 Write Fix Artifact Brief

Write `fix-artifacts-brief.md` to all inboxes containing:

- **All prior context** (agents are ephemeral — include original brief)
- **The confirmed FIX NOW list** with IDs, descriptions, and affected files
- **Instructions**: For each FIX NOW item, **read the actual source file** and produce:

```
### C[N]: [Title]
**File:** exact/path/to/file
**Lines:** X-Y (informational only)

BEFORE (with 3+ lines surrounding context):
```[language]
[exact code currently in the file — copy-paste, not paraphrased]
```

AFTER:
```[language]
[exact replacement code with same surrounding context]
```

NOTES: [caveats, cross-cutting dependencies with other fixes]
```

- **Rules for agents**:
  1. Read the actual source code to produce BEFORE blocks — do not guess
  2. BEFORE must match exactly what is in the file, with 3+ lines of anchored context
  3. AFTER must be a complete, working replacement
  4. Each snippet is self-contained
  5. If a fix requires changes across multiple files, produce one snippet per file
  6. Note cross-cutting dependencies between fixes (e.g., "apply C3 before C1")
  7. **Do NOT apply fixes** — only author artifacts. Branch mutation is Archon's `implement-fixes` responsibility.

### 7.5.2 Run Fix Artifact Round

Launch all agents (same parallel pattern as Round 1). Each writes `outbox/fix-artifacts.md`.
Verify reports: at least 2 valid. Retry failed agents once.

### 7.5.3 Reconcile Artifacts

For each FIX NOW item:
1. If agents agree → use it
2. If agents disagree → prefer most specific fix, then fewest files, then root-cause over symptom
3. Honor cross-cutting dependency order

**PHASE_7.5_CHECKPOINT:**

- [ ] Fix artifact brief written to all inboxes
- [ ] Agents produced fix-artifacts.md (at least 2 valid)
- [ ] Artifacts reconciled — one authoritative fix per FIX NOW item

---

## Phase 8: MERGE — Append to Consolidated Review

**Single-writer integration.** Board does NOT apply fixes. It appends findings to
Archon's `consolidated-review.md` so `implement-fixes` sees both review streams.

### 8.1 Map Severities

| Board | Archon Equivalent |
|---------------|-------------------|
| FIX NOW | CRITICAL or HIGH |
| DEFER | MEDIUM |
| INFO | LOW |

### 8.2 Format and Append

For each FIX NOW item, format as an Archon-compatible finding and append to
`$ARTIFACTS_DIR/review/consolidated-review.md`:

```markdown
## [CRITICAL] C{N}: {title} (Board)

**Source:** Board board-review-code
**File:** {path}
**Lines:** {X-Y}

### Issue
{description}

### Recommended Fix (Option A — from board fix artifact)
{the reconciled BEFORE/AFTER snippet}

### Why It Matters
{impact if not addressed}
```

### 8.3 Write Board Review Artifact

Write `$ARTIFACTS_DIR/review/board-review-code.md` with the full review record (same format
as plan review artifact — agents, findings, fix artifacts, timing, sign-off).

**PHASE_8_CHECKPOINT:**

- [ ] Severities mapped
- [ ] Findings appended to consolidated-review.md in Archon format
- [ ] Board review artifact written

---

## Phase 9: CLEANUP

### 9.1 Remove Lock

```bash
rm -f $BOARD/.review-lock
```

### 9.2 Clean Inboxes

```bash
for AGENT in pragmatist systems-thinker skeptic; do
  rm -f "$BOARD_DIR/$AGENT/inbox/consolidation.md" \
        "$BOARD_DIR/$AGENT/inbox/round2-brief.md" \
        "$BOARD_DIR/$AGENT/inbox/round3-brief.md" \
        "$BOARD_DIR/$AGENT/inbox/round4-brief.md" \
        "$BOARD_DIR/$AGENT/inbox/fix-artifacts-brief.md"
done
```

**PHASE_9_CHECKPOINT:**

- [ ] Lock removed
- [ ] Inboxes cleaned

---

## Phase 10: OUTPUT — Report Results

```markdown
## Board Code Review Complete

**Workflow ID**: `$WORKFLOW_ID`
**Status**: {APPROVED / APPROVED WITH AMENDMENTS}
**Integration**: Findings appended to consolidated-review.md (single-writer)

### Review Summary

| Metric | Count |
|--------|-------|
| FIX NOW items | {N} (artifacts authored, appended to consolidated-review.md) |
| DEFER items | {M} |
| INFO items | {K} |
| Rounds completed | {R} |

### Agents

| Agent | Model | Verdict |
|-------|-------|---------|
| Pragmatist | {model from config} | SIGN OFF |
| Systems Thinker | {model from config} | SIGN OFF |
| Skeptic | {model from config} | SIGN OFF |

### Fix Artifacts

| ID | File(s) | Snippet Source | Appended to consolidated-review.md |
|----|---------|---------------|-------------------------------------|
| C1 | {path} | {agent} | Yes |

### Next Step

`implement-fixes` will consume the merged consolidated-review.md and apply all fixes.
```

---

## Error Handling

### Agent Fails After Retry

Continue with remaining agents if at least 2 produced valid reports.
Document the failure in the review artifact.

### Large Diff Partitioning Failure

If diff cannot be partitioned (e.g., single massive file), fall back to
summary-only mode: provide file-level summary + specific high-risk sections inline.
Log the limitation in the review artifact.

### Merge Conflict with consolidated-review.md

If `consolidated-review.md` has been modified since Phase 1.3, re-read it before
appending. Append-only operation — never overwrite existing Archon findings.

---

## Success Criteria

- **AGENTS_RAN**: At least 2 of 3 agents produced valid reports
- **SOP_FOLLOWED**: 4-round process completed (3 if unanimous after R2)
- **ARTIFACTS_AUTHORED**: Fix artifacts produced for all FIX NOW items (Phase 7.5)
- **FINDINGS_MERGED**: Board findings appended to consolidated-review.md
- **SINGLE_WRITER**: No branch mutations made — only artifact production
- **ARTIFACT_WRITTEN**: `board-review-code.md` contains full review record
- **LOCK_RELEASED**: Review lock removed
- **INBOXES_CLEANED**: Stale round files removed from agent inboxes
