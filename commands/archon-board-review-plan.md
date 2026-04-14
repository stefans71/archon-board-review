---
description: Run multi-model governance review on the implementation plan
argument-hint: (no arguments - reads from workflow artifacts)
---

# Board Review Plan

**Workflow ID**: $WORKFLOW_ID

---

## Your Mission

Run a multi-model board review on the implementation plan before code is written.
Three agents with different model families review the plan following the 4-round SOP:
Blind Review → Consolidation → Deliberation (if needed) → Confirmation.

FIX NOW items are applied to the plan. The reviewed plan becomes the implementation source.

**This step does NOT implement anything** — it reviews and improves the plan.

---

## Phase 0: CONFIG — Resolve Paths

### 0.1 Load Configuration

```bash
CONFIG_FILE="$HOME/.archon-board-review/config.yaml"
test -f "$CONFIG_FILE" || { echo "ERROR: Run 'archon-board-review setup' first"; exit 1; }
```

Extract configuration values:

```bash
BOARD_DIR=$(grep '^board_dir:' "$CONFIG_FILE" | awk '{print $2}')
BOARD_DIR="${BOARD_DIR:-$HOME/.archon-board-review/board}"
BOARD_USER=$(grep '^board_user:' "$CONFIG_FILE" | sed 's/board_user://' | xargs)
```

### 0.2 Resolve Agent Settings

For each agent (pragmatist, systems-thinker, skeptic), extract from config:
- `cli` — which CLI to use (claude or codex)
- `model` — model identifier
- `flags` — CLI flags
- `timeout` — max seconds per agent invocation

```bash
# Example extraction for pragmatist:
PRAGMATIST_CLI=$(grep -A5 'pragmatist:' "$CONFIG_FILE" | grep 'cli:' | awk '{print $2}')
PRAGMATIST_MODEL=$(grep -A5 'pragmatist:' "$CONFIG_FILE" | grep 'model:' | awk '{print $2}')
PRAGMATIST_FLAGS=$(grep -A5 'pragmatist:' "$CONFIG_FILE" | grep 'flags:' | sed 's/.*flags: *//' | tr -d '"')
PRAGMATIST_TIMEOUT=$(grep -A5 'pragmatist:' "$CONFIG_FILE" | grep 'timeout:' | awk '{print $2}')
# Repeat for systems-thinker and skeptic
```

### 0.3 Determine Invocation Pattern

If `BOARD_USER` is set and differs from the current user, commands are wrapped:
```bash
sudo -u $BOARD_USER bash -c 'cd $AGENT_DIR && ...'
```

If `BOARD_USER` is empty (default), commands run directly:
```bash
cd $AGENT_DIR && ...
```

**PHASE_0_CHECKPOINT:**

- [ ] Config file exists and loaded
- [ ] Board dir resolved
- [ ] Agent CLI/model/flags extracted for all 3 agents
- [ ] Invocation pattern determined (sudo or direct)

---

## Phase 1: LOAD — Read Plan Artifacts

### 1.1 Load Plan Context

```bash
cat $ARTIFACTS_DIR/plan-context.md
```

Extract: plan title, files to change, scope limits, validation commands, acceptance criteria.

### 1.2 Load Plan Confirmation

```bash
cat $ARTIFACTS_DIR/plan-confirmation.md
```

Verify status is CONFIRMED or PROCEED WITH CAUTION. If BLOCKED, stop:

```
Board review cannot proceed — plan confirmation is BLOCKED.
Fix blockers and re-run the workflow.
```

### 1.3 Load Original Plan

The plan source path is in `plan-context.md`. Read the full plan:

```bash
cat {plan-source-path}
```

**PHASE_1_CHECKPOINT:**

- [ ] Plan context loaded
- [ ] Confirmation status verified (not BLOCKED)
- [ ] Original plan loaded

---

## Phase 2: PRE-FLIGHT — Verify Board Environment

### 2.1 Check Board User (if configured)

Only if `BOARD_USER` is set:

```bash
id $BOARD_USER
```

If it fails: stop with "Board user '$BOARD_USER' does not exist."

### 2.2 Check Agent Directories

For each agent (pragmatist, systems-thinker, skeptic), verify:

```bash
for AGENT in pragmatist systems-thinker skeptic; do
  test -d "$BOARD_DIR/$AGENT/inbox" || echo "MISSING: $AGENT/inbox"
  test -d "$BOARD_DIR/$AGENT/outbox" || echo "MISSING: $AGENT/outbox"
  test -f "$BOARD_DIR/$AGENT/CLAUDE.md" || echo "MISSING: $AGENT/CLAUDE.md"
done
```

If any are missing: "Run 'archon-board-review setup' to create agent directories."

### 2.3 Check CLIs

For each agent, check its configured CLI is available:

```bash
# For claude-based agents:
which claude || echo "claude CLI not found"
# For codex-based agents:
which codex || echo "codex CLI not found"
```

### 2.4 Review Lock

```bash
LOCKFILE="$BOARD_DIR/.review-lock"
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cut -d'|' -f1 "$LOCKFILE")
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "Review in progress (PID $LOCK_PID). Wait or kill it."
    exit 1
  else
    rm -f "$LOCKFILE"
  fi
fi
echo "$$|$(date -Iseconds)" > "$LOCKFILE"
```

If any pre-flight check fails, stop immediately. Do NOT proceed to agent runs.

**PHASE_2_CHECKPOINT:**

- [ ] Board user exists (if configured)
- [ ] All agent directories complete
- [ ] Required CLIs available
- [ ] Lock acquired

---

## Phase 3: BRIEF — Write Agent Briefs

### 3.1 Compose the Brief

**Agents are ephemeral.** Every invocation is a fresh session with zero memory. All context — identity, domain context, brief, prior round artifacts — must be in their inbox. If you don't give it to them, they don't have it.

Write a brief containing:

1. **Review type**: Implementation plan review (NOT code review)
2. **Context**: What the project does, what this plan adds
3. **Full plan inline** — the entire plan text, not a summary. Never summarize what agents can read themselves.
4. **Scope limits** — the "NOT Building" section from plan-context.md
5. **Plan confirmation status** — any warnings from confirm-plan
6. **Broader context** — agents reviewing a plan need to understand the system the plan operates in. Include architecture, dependencies, deployment environment, prior decisions.
7. **Evaluation criteria**:
   - Completeness: does the plan cover all acceptance criteria?
   - Feasibility: can each task be implemented as described?
   - Risk: what could go wrong during implementation?
   - Dependencies: are task ordering and file dependencies correct?
   - Missing pieces: what does the plan assume but not state?
8. **Output format**: Numbered findings with severity (FIX NOW / DEFER / INFO)
9. **Deferred items**: Check for any deferred items in the project. Include them as active evaluation targets: "Evaluate whether your review triggers any of these deferred items. If a trigger condition is met, promote to FIX NOW with evidence." Never say "do not re-raise" — agents interpret this as "ignore."

### 3.2 Write Context and Brief to Inboxes

```bash
CONTEXT="Project: $(basename $(pwd))
Project path: $(pwd)
Review type: Implementation plan
Date: $(date -Iseconds)"

for AGENT in pragmatist systems-thinker skeptic; do
  echo "$CONTEXT" > "$BOARD_DIR/$AGENT/inbox/context.md"
  echo "$BRIEF" > "$BOARD_DIR/$AGENT/inbox/brief.md"
done
```

**PHASE_3_CHECKPOINT:**

- [ ] Brief composed with full plan inline (never summarized)
- [ ] Broader context included (system architecture, dependencies)
- [ ] Context written to all 3 agent inboxes
- [ ] Brief written to all 3 agent inboxes
- [ ] Deferred items included as active evaluation targets

---

## Phase 4: ROUND 1 — Blind Review

### 4.1 Record Start Time

```bash
REVIEW_START=$(date +%s)
RUN_ID="run-$REVIEW_START"
for AGENT in pragmatist systems-thinker skeptic; do
  echo "$RUN_ID" > "$BOARD_DIR/$AGENT/outbox/.run-id"
done
```

### 4.2 Launch All Agents in Parallel

Build invocation commands from config. The prompt for each agent is the same:

```
read CLAUDE.md then read inbox/context.md and inbox/brief.md and write your report to outbox/report.md
```

**For claude-based agents** (pragmatist, skeptic):
```bash
AGENT_DIR="$BOARD_DIR/{agent}"
timeout $TIMEOUT [sudo -u $BOARD_USER] bash -c "unset CLAUDECODE && cd $AGENT_DIR && claude $FLAGS --model $MODEL -p '$PROMPT'" &
```

**For codex-based agents** (systems-thinker):
```bash
AGENT_DIR="$BOARD_DIR/{agent}"
timeout $TIMEOUT [sudo -u $BOARD_USER] bash -c "cd $AGENT_DIR && codex exec -m '$MODEL' $FLAGS '$PROMPT'" &
```

The `[sudo -u $BOARD_USER]` prefix is only added when `BOARD_USER` is configured.

Launch all three in parallel, capture PIDs, wait for all to complete.

### 4.3 Verify Reports

For each agent, check:

1. Exit code was 0 (non-zero or 124 = timeout → failure)
2. `outbox/report.md` exists and was modified after `$REVIEW_START`
3. For Codex agents: report does NOT start with `OpenAI Codex v` or contain `ERROR:` (CLI error output, not findings)

```bash
for AGENT in pragmatist systems-thinker skeptic; do
  REPORT="$BOARD_DIR/$AGENT/outbox/report.md"
  if [ ! -f "$REPORT" ]; then
    echo "FAILED: $AGENT — no report produced"
  elif [ "$(stat -c %Y "$REPORT")" -lt "$REVIEW_START" ]; then
    echo "STALE: $AGENT — report older than run start"
  else
    echo "OK: $AGENT — $(wc -l < "$REPORT") lines"
  fi
done
```

**Failed agents must be retried once.** If retry also fails, note which agent failed and
continue only if at least 2 agents produced valid reports. With fewer than 2, stop the review.

Do NOT share reports between agents. Do NOT synthesize error output as findings.

### 4.4 Read Reports

Read all successful reports:

```bash
cat $BOARD_DIR/pragmatist/outbox/report.md
cat $BOARD_DIR/systems-thinker/outbox/report.md
cat $BOARD_DIR/skeptic/outbox/report.md
```

Record timing:
```bash
ROUND1_END=$(date +%s)
echo "Round 1 complete in $((ROUND1_END - REVIEW_START))s"
```

**PHASE_4_CHECKPOINT:**

- [ ] All 3 agents launched in parallel
- [ ] Reports collected (at least 2 valid)
- [ ] Failed agents retried
- [ ] Timing recorded

---

## Phase 5: ROUND 2 — Consolidation

**Done by you (orchestrator), not agents.**

### 5.1 Group Findings

1. Read all Round 1 reports
2. Group findings by theme
3. Assign consolidated IDs: C1, C2, C3...
4. Note which agents raised each item and whether they agree

### 5.2 Classify Each Item

| Severity | When to use |
|----------|-------------|
| **FIX NOW** | Plan error, missing dependency, incorrect task ordering, wrong file path |
| **DEFER** | Valid concern but not blocking implementation. Must have trigger condition |
| **INFO** | Observation, suggestion, nice-to-have |
| **REJECT** | Agent raised something already covered by scope limits |

### 5.3 Apply Tiebreaking Rules

When agents assign different severities:
1. 2 of 3 agree → use majority, note dissent
2. All 3 disagree → use highest severity, flag for Round 3
3. FIX NOW vs DEFER disagreement → classify as FIX NOW, let deliberation resolve

### 5.4 Write Consolidation

**Agents are ephemeral — they have zero memory of Round 1.** Write to each agent's inbox:
- `context.md` — same domain context
- `brief.md` — original Round 1 brief (agents need source material again)
- `consolidation.md` — your consolidated findings with IDs
- `round2-brief.md` — instructions (AGREE/DISAGREE/MODIFY per item), owner directives

### 5.5 Run Round 2 Agents

Launch all agents again (same parallel pattern as Round 1) with Round 2 inboxes.
Collect Round 2 reports.

**PHASE_5_CHECKPOINT:**

- [ ] Findings grouped and classified
- [ ] Consolidation written to inboxes (with full original brief — agents are ephemeral)
- [ ] Round 2 agents completed
- [ ] Agreement/disagreement recorded

---

## Phase 6: ROUND 3 — Deliberation (if needed)

If Round 2 is unanimous:

> Round 2 unanimous — skipping deliberation, proceeding to confirmation.

Skip to Phase 7.

If disagreements exist:
1. Extract disputed items
2. Show each agent's position with names visible
3. Write `round3-brief.md` to inboxes (include ALL prior context — agents are ephemeral)
4. Agents state AGREE or BLOCK per item
5. Run agents, collect reports

**PHASE_6_CHECKPOINT:**

- [ ] Disputes identified (or unanimous → skip)
- [ ] Round 3 completed (if needed)

---

## Phase 7: ROUND 4 — Confirmation

### 7.1 Write Final Brief

Write `round4-brief.md` to all inboxes containing:
- All items with final classifications
- Implementation notes for FIX NOW items
- Dispute resolutions (if any)
- Instructions: state SIGN OFF or BLOCK per item

**Include all prior context again.** Agents are ephemeral.

### 7.2 Run Confirmation Round

Launch all agents. Collect reports.

### 7.3 Handle Blocks

If all agents sign off → proceed.

If any agent blocks:
- Document the block and rationale
- Apply owner authority override with documented rationale (autonomous mode)
- Note the override in the review artifact

**PHASE_7_CHECKPOINT:**

- [ ] Confirmation round completed
- [ ] All agents signed off (or blocks overridden with rationale)

---

## Phase 8: APPLY — Fix the Plan

### 8.1 Collect FIX NOW Items

From the final consolidated findings, extract all items classified as FIX NOW.

### 8.2 Apply Fixes to Plan

For each FIX NOW item, modify the plan:
- Wrong task ordering → reorder tasks
- Missing dependency → add dependency note
- Incorrect file path → fix the path
- Missing task → add the task
- Ambiguous instruction → clarify it

**Do NOT rewrite the plan from scratch.** Make targeted edits that address each finding.

### 8.3 Write Amended Plan

If any FIX NOW items were applied, write the amended plan to `$ARTIFACTS_DIR/plan-amended.md`.
Update `plan-context.md` to reference the amended plan.

If no FIX NOW items, the original plan stands unchanged.

**PHASE_8_CHECKPOINT:**

- [ ] FIX NOW items extracted
- [ ] Plan amendments applied (if any)
- [ ] Amended plan written (if applicable)

---

## Phase 9: ARTIFACT — Write Board Review

### 9.1 Write Review Artifact

Write to `$ARTIFACTS_DIR/board-review.md`:

```markdown
# Board Review

**Generated**: {YYYY-MM-DD HH:MM}
**Workflow ID**: $WORKFLOW_ID
**Review mode**: Standard (3 agents, 4-round SOP)
**Rounds completed**: {N}

---

## Agents

| Agent | Model | Status |
|-------|-------|--------|
| Pragmatist | {model from config} | {OK/FAILED} |
| Systems Thinker | {model from config} | {OK/FAILED} |
| Skeptic | {model from config} | {OK/FAILED} |

---

## FIX NOW Items

| ID | Finding | Agent(s) | Applied |
|----|---------|----------|---------|
| C1 | {description} | Pragmatist, Skeptic | Yes — {what changed} |

{If none: "No FIX NOW items. Plan passed review unchanged."}

---

## DEFER Items

| ID | Finding | Trigger Condition |
|----|---------|-------------------|
| C2 | {description} | {when this becomes relevant} |

{If none: "No deferred items."}

---

## INFO Items

| ID | Finding |
|----|---------|
| C4 | {observation} |

---

## Plan Amendments

{If amendments:}
Amended plan written to: `$ARTIFACTS_DIR/plan-amended.md`

{If no amendments:}
No amendments. Original plan stands.

---

## Sign-Off

| Agent | Verdict |
|-------|---------|
| Pragmatist | SIGN OFF |
| Systems Thinker | SIGN OFF |
| Skeptic | {SIGN OFF / BLOCK (overridden)} |

---

## Timing

**Total**: {N}s
**Round 1**: {N}s (Pragmatist: {N}s, Systems Thinker: {N}s, Skeptic: {N}s)
**Rounds 2-4**: {N}s each
```

### 9.2 Remove Lock

```bash
rm -f "$BOARD_DIR/.review-lock"
```

**PHASE_9_CHECKPOINT:**

- [ ] Board review artifact written
- [ ] Lock removed

---

## Phase 10: OUTPUT — Report Results

```markdown
## Board Review Complete

**Workflow ID**: `$WORKFLOW_ID`
**Status**: {APPROVED / APPROVED WITH AMENDMENTS}

### Review Summary

| Metric | Count |
|--------|-------|
| FIX NOW items | {N} (all applied) |
| DEFER items | {M} |
| INFO items | {K} |
| Rounds completed | {R} |

### Agents

| Agent | Model | Verdict |
|-------|-------|---------|
| Pragmatist | {model} | SIGN OFF |
| Systems Thinker | {model} | SIGN OFF |
| Skeptic | {model} | SIGN OFF |

{If amendments:}
### Plan Amendments

{N} FIX NOW items applied to plan. Amended plan: `$ARTIFACTS_DIR/plan-amended.md`

### Artifact

Review written to: `$ARTIFACTS_DIR/board-review.md`

### Next Step

Proceed to milestone implementation loop.
```

---

## Error Handling

### Agent Fails After Retry

Continue with remaining agents if at least 2 produced valid reports.
Document the failure in the review artifact. If fewer than 2 agents
produced reports, stop the review:

```
Board review cannot complete — fewer than 2 agents produced valid reports.
Check agent CLIs and credentials, then re-run.
```

### Lock Held by Active Process

Do not break the lock. Report the PID and suggest waiting or killing.

### Plan Confirmation BLOCKED

Cannot review a blocked plan. Stop immediately.

---

## Success Criteria

- **AGENTS_RAN**: At least 2 of 3 agents produced valid reports
- **SOP_FOLLOWED**: 4-round process completed (3 if unanimous after R2)
- **FIX_NOW_APPLIED**: All FIX NOW items applied to plan
- **ARTIFACT_WRITTEN**: `board-review.md` contains full review record
- **LOCK_RELEASED**: Review lock removed
