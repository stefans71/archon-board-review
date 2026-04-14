# archon-board-review

Multi-model governance review plugin for [Archon](https://github.com/coleam00/Archon). Adds a 3-agent board review and milestone-based implementation loop to Archon's plan-to-pr pipeline — without modifying Archon's source.

## What It Does

`archon-board-review install` creates two new workflows alongside the originals:

| Original | Board variant |
|----------|---------------|
| `archon-plan-to-pr` | `archon-board-plan-to-pr` |
| `archon-idea-to-pr` | `archon-board-idea-to-pr` |

The board variants add two nodes:

1. **Board Review** (after `confirm-plan`) — 3 agents from different model families review the plan using a 4-round SOP before any code is written
2. **Implement Loop** (replaces `implement-tasks`) — milestone-based iteration with `fresh_context: true` per milestone

## Quick Start

```bash
# Clone
git clone https://github.com/stefans71/archon-board-review.git
cd archon-board-review

# One-time setup (creates config + agent workspace)
./archon-board-review.sh setup

# Edit config if needed
nano ~/.archon-board-review/config.yaml

# Install into any Archon-managed project
./archon-board-review.sh install /path/to/your/project

# Run the board-integrated workflow
cd /path/to/your/project
archon workflow run archon-board-plan-to-pr -- docs/implementation-plan.md
```

## Prerequisites

- [Archon](https://github.com/coleam00/Archon) installed
- **claude** CLI ([Claude Code](https://claude.ai/code)) — required for Pragmatist and Skeptic agents
- **codex** CLI ([OpenAI Codex](https://platform.openai.com/docs/codex)) — required for Systems Thinker agent
- OpenRouter API key configured in Claude Code — for DeepSeek V3.2 routing (Skeptic agent)

Not all three CLIs are required. You can configure all agents to use the same CLI with different models. See [Configuration](#configuration).

## How It Works

### Workflow DAG

```
plan-setup → confirm-plan → board-review-plan → implement-loop → validate → finalize-pr
                                                                      ↓
                                              review-scope → sync → [5 review agents]
                                                                      ↓
                                                          synthesize → implement-fixes → summary
```

### Board Review (4-Round SOP)

Three agents with different perspectives review the plan:

| Agent | Default Model | Lens |
|-------|---------------|------|
| Pragmatist | Claude Opus 4.6 | Operational reality — feasibility, maintainability |
| Systems Thinker | GPT-5.2 Codex | Integration, dependencies, second-order effects |
| Skeptic | DeepSeek V3.2 | Gap-finder — missing, untested, assumed without evidence |

The review follows a structured 4-round process:

```
Round 1: Blind Review    — independent analysis, no cross-pollination
Round 2: Consolidation   — orchestrator groups findings, agents respond
Round 3: Deliberation    — only if disagreements (skip if unanimous)
Round 4: Confirmation    — agents SIGN OFF or BLOCK
```

FIX NOW items are applied to the plan before implementation begins.

### Milestone Loop

Replaces monolithic "implement all tasks at once" with per-milestone iterations:

- `fresh_context: true` — each milestone gets a clean context window
- `milestone-tracker.json` — cross-iteration state
- `max_iterations: 10` — hard cap
- Default model: Claude Opus 4.6 (configurable)

## Configuration

Configuration lives at `~/.archon-board-review/config.yaml`. Created by `setup`.

### Agent Models

Swap any agent's model by editing the config:

```yaml
agents:
  pragmatist:
    cli: claude
    model: claude-opus-4-6
    flags: "--dangerously-skip-permissions"
    timeout: 900
  systems-thinker:
    cli: codex
    model: gpt-5.2-codex
    flags: "--dangerously-bypass-approvals-and-sandbox"
    timeout: 900
  skeptic:
    cli: claude
    model: deepseek/deepseek-v3.2    # via OpenRouter
    flags: "--dangerously-skip-permissions"
    timeout: 900
```

### All-Claude Setup (no Codex or OpenRouter needed)

```yaml
agents:
  pragmatist:
    cli: claude
    model: claude-opus-4-6
  systems-thinker:
    cli: claude
    model: claude-sonnet-4-6
  skeptic:
    cli: claude
    model: claude-opus-4-6
```

### Board User (optional)

For process isolation, run agents as a dedicated user:

```yaml
board_user: llmuser
```

Default: runs agents as the current user.

### Archon Location

Auto-detected during setup. Override manually:

```yaml
archon_defaults: /path/to/Archon/.archon/workflows/defaults
```

Or via environment variable:

```bash
export ARCHON_BOARD_REVIEW_DEFAULTS=/path/to/Archon/.archon/workflows/defaults
```

## Commands

| Command | What it does |
|---------|-------------|
| `setup` | Creates `~/.archon-board-review/` with config and agent workspace |
| `install [dir]` | Generates board workflow YAMLs + copies command file into project |
| `check [dir]` | Verifies upstream Archon workflows haven't changed since install |
| `status [dir]` | Shows what's installed in a project |
| `config` | Prints resolved configuration |

## Integrity Checking

`archon-board-review check` compares SHA-256 hashes of upstream Archon workflow files against what was used during install. If upstream has changed (e.g., after `git pull` on Archon), the board workflows may be out of sync.

Re-run `archon-board-review install` to regenerate.

## No Archon Source Modification

This plugin creates **new** workflow files alongside Archon's originals. It never modifies Archon's source. You can `git pull upstream` on your Archon fork without conflicts.

## File Structure

```
archon-board-review/
├── archon-board-review.sh                # CLI: setup, install, check, status, config
├── templates/
│   ├── config.yaml.template              # Config template
│   ├── board-review-node.yaml            # Board review node YAML
│   ├── implement-loop-node.yaml          # Milestone loop node YAML
│   └── agents/
│       ├── pragmatist/CLAUDE.md          # Pragmatist identity
│       ├── systems-thinker/CLAUDE.md     # Systems Thinker identity
│       └── skeptic/CLAUDE.md             # Skeptic identity
├── commands/
│   └── archon-board-review-plan.md       # Board review orchestration command
└── README.md
```
