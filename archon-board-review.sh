#!/bin/bash
# archon-board-review — Multi-model governance review plugin for Archon
# Injects board review and milestone loop nodes into Archon workflows
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="1.0.0"
CONFIG_DIR="$HOME/.archon-board-review"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
TEMPLATES="$SCRIPT_DIR/templates"

# ─── Helpers ─────────────────────────────────────────────────────────

usage() {
  cat <<EOF
archon-board-review v$VERSION — Multi-model governance review for Archon workflows

Usage:
  archon-board-review setup               One-time setup (creates config + agent dirs)
  archon-board-review install [project]    Install board workflows into a project
  archon-board-review check   [project]    Verify upstream hasn't changed since install
  archon-board-review status  [project]    Show installed workflow info
  archon-board-review config               Show resolved configuration

project defaults to current directory.
EOF
  exit 1
}

die() { echo "ERROR: $1" >&2; exit 1; }
info() { echo ":: $1"; }
warn() { echo "WARNING: $1" >&2; }

hash_file() {
  sha256sum "$1" | cut -d' ' -f1
}

# ─── Config ──────────────────────────────────────────────────────────

# Read a top-level key from config.yaml (simple grep, no yq needed)
config_get() {
  local key="$1"
  local default="${2:-}"
  if [ -f "$CONFIG_FILE" ]; then
    local val
    val=$(grep "^${key}:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed "s/^${key}:[[:space:]]*//" | xargs)
    if [ -n "$val" ]; then
      echo "$val"
      return
    fi
  fi
  echo "$default"
}

# Read a nested agent key: agent_config pragmatist cli
agent_config() {
  local agent="$1"
  local key="$2"
  local default="${3:-}"
  if [ -f "$CONFIG_FILE" ]; then
    local val
    val=$(grep -A6 "^  ${agent}:" "$CONFIG_FILE" 2>/dev/null | grep "^    ${key}:" | head -1 | sed "s/^    ${key}:[[:space:]]*//" | tr -d '"' | xargs)
    if [ -n "$val" ]; then
      echo "$val"
      return
    fi
  fi
  echo "$default"
}

load_config() {
  [ -f "$CONFIG_FILE" ] || die "No configuration found. Run 'archon-board-review setup' first."
  BOARD_DIR=$(config_get "board_dir" "$CONFIG_DIR/board")
  BOARD_USER=$(config_get "board_user" "")
  ARCHON_DEFAULTS=$(find_archon_defaults)
}

# ─── Archon Discovery ───────────────────────────────────────────────

find_archon_defaults() {
  # 1. Environment variable override
  if [ -n "${ARCHON_BOARD_REVIEW_DEFAULTS:-}" ]; then
    echo "$ARCHON_BOARD_REVIEW_DEFAULTS"
    return
  fi

  # 2. Config file
  local from_config
  from_config=$(config_get "archon_defaults" "")
  if [ -n "$from_config" ] && [ -d "$from_config" ]; then
    echo "$from_config"
    return
  fi

  # 3. Common locations
  local candidates=(
    "$HOME/tinkering/Archon/.archon/workflows/defaults"
    "$HOME/Archon/.archon/workflows/defaults"
    "$HOME/.archon/workflows/defaults"
    "/opt/archon/.archon/workflows/defaults"
  )
  for candidate in "${candidates[@]}"; do
    if [ -d "$candidate" ]; then
      echo "$candidate"
      return
    fi
  done

  # 4. Try to find archon on PATH and derive location
  if command -v archon &>/dev/null; then
    local archon_bin
    archon_bin=$(command -v archon)
    local archon_root
    archon_root=$(dirname "$(dirname "$archon_bin")")
    if [ -d "$archon_root/.archon/workflows/defaults" ]; then
      echo "$archon_root/.archon/workflows/defaults"
      return
    fi
  fi

  die "Cannot find Archon workflow defaults. Set archon_defaults in $CONFIG_FILE or ARCHON_BOARD_REVIEW_DEFAULTS env var."
}

# Find the upstream workflow YAML — checks project .archon first, then defaults
find_upstream() {
  local project_dir="$1"
  local workflow_name="$2"
  local project_workflow="$project_dir/.archon/workflows/$workflow_name"

  if [ -f "$project_workflow" ]; then
    echo "$project_workflow"
  elif [ -f "$ARCHON_DEFAULTS/$workflow_name" ]; then
    echo "$ARCHON_DEFAULTS/$workflow_name"
  else
    return 1
  fi
}

# ─── Inject board nodes into a workflow YAML ─────────────────────────

inject_board_nodes() {
  local source="$1"
  local target="$2"
  local board_node="$TEMPLATES/board-review-node.yaml"
  local loop_node="$TEMPLATES/implement-loop-node.yaml"

  [ -f "$board_node" ] || die "Missing template: $board_node"
  [ -f "$loop_node" ] || die "Missing template: $loop_node"

  # State machine: eat the PHASE 3 header block + implement-tasks node,
  # replace with board-review template + implement-loop template.
  awk '
    BEGIN { state = "NORMAL" }

    # Buffer ═══ borders — they might be the PHASE 3 header we need to eat
    state == "NORMAL" && /^  # ═+$/ {
      border = $0
      state = "CHECK_PHASE3"
      next
    }

    # If the line after ═══ is PHASE 3, eat the whole header block
    state == "CHECK_PHASE3" && /PHASE 3: IMPLEMENT/ {
      state = "EAT_PHASE3_BOTTOM"
      next
    }

    # Not PHASE 3 — flush the buffered border and resume
    state == "CHECK_PHASE3" {
      print border
      state = "NORMAL"
      print
      next
    }

    # Eat the bottom ═══ of the PHASE 3 header, then emit templates
    state == "EAT_PHASE3_BOTTOM" && /^  # ═+$/ {
      # Emit board-review template
      while ((getline line < BOARD_NODE) > 0) print line
      close(BOARD_NODE)
      print ""
      # Emit implement-loop template
      while ((getline line < LOOP_NODE) > 0) print line
      close(LOOP_NODE)
      state = "SKIP_IMPLEMENT"
      next
    }

    # Skip the implement-tasks node body until the next phase header
    state == "SKIP_IMPLEMENT" {
      if (/^  # ═+$/) {
        state = "NORMAL"
        print
      }
      next
    }

    state == "NORMAL" { print }
  ' BOARD_NODE="$board_node" LOOP_NODE="$loop_node" "$source" > "$target.tmp"

  # Fix depends_on references downstream
  sed -i 's/depends_on: \[implement-tasks\]/depends_on: [implement-loop]/g' "$target.tmp"

  mv "$target.tmp" "$target"
}

# Update workflow name and description for the board variant
update_workflow_meta() {
  local file="$1"
  local orig_name="$2"
  local board_name="$3"

  sed -i \
    -e "s/^name: $orig_name/name: $board_name/" \
    -e 's/Use when: You have an existing implementation plan/Use when: You have an existing implementation plan and want multi-model board review/' \
    -e 's/Use when: You have a feature idea/Use when: You have a feature idea and want multi-model board review/' \
    "$file"
}

# ─── setup ───────────────────────────────────────────────────────────

cmd_setup() {
  info "Setting up archon-board-review..."

  # Create config directory
  mkdir -p "$CONFIG_DIR"

  # Create agent workspace
  local board_dir="$CONFIG_DIR/board"
  for agent in pragmatist systems-thinker skeptic; do
    mkdir -p "$board_dir/$agent/inbox"
    mkdir -p "$board_dir/$agent/outbox"
    if [ -f "$TEMPLATES/agents/$agent/CLAUDE.md" ]; then
      cp "$TEMPLATES/agents/$agent/CLAUDE.md" "$board_dir/$agent/CLAUDE.md"
      info "Agent template: $agent"
    fi
  done

  # Detect CLIs
  local detected_claude="no" detected_codex="no"
  command -v claude &>/dev/null && detected_claude="yes"
  command -v codex &>/dev/null && detected_codex="yes"

  # Auto-detect Archon
  local archon_path=""
  local candidates=(
    "$HOME/tinkering/Archon/.archon/workflows/defaults"
    "$HOME/Archon/.archon/workflows/defaults"
    "$HOME/.archon/workflows/defaults"
  )
  for candidate in "${candidates[@]}"; do
    if [ -d "$candidate" ]; then
      archon_path="$candidate"
      break
    fi
  done

  # Generate config
  if [ ! -f "$CONFIG_FILE" ]; then
    sed \
      -e "s|__ARCHON_DEFAULTS__|${archon_path:-# NOT DETECTED — set manually}|" \
      -e "s|__HOME__|$HOME|" \
      "$TEMPLATES/config.yaml.template" > "$CONFIG_FILE"
    info "Config written: $CONFIG_FILE"
  else
    info "Config exists: $CONFIG_FILE (not overwritten)"
  fi

  echo ""
  echo "Setup complete."
  echo ""
  echo "Detected:"
  echo "  claude CLI:  $detected_claude"
  echo "  codex CLI:   $detected_codex"
  echo "  Archon:      ${archon_path:-NOT FOUND}"
  echo ""
  echo "Agent workspace: $board_dir/"
  echo "  pragmatist/      (Claude Opus 4.6)"
  echo "  systems-thinker/ (GPT-5.2 Codex)"
  echo "  skeptic/         (DeepSeek V3.2 via OpenRouter)"
  echo ""

  if [ -z "$archon_path" ]; then
    echo "ACTION NEEDED: Set archon_defaults in $CONFIG_FILE"
    echo "  Point it to your Archon .archon/workflows/defaults/ directory."
    echo ""
  fi

  echo "Next: archon-board-review install <project-dir>"
}

# ─── install ─────────────────────────────────────────────────────────

cmd_install() {
  local project_dir="${1:-.}"
  project_dir="$(cd "$project_dir" && pwd)"

  load_config

  info "Installing archon-board-review in: $project_dir"

  # Ensure .archon directories exist
  mkdir -p "$project_dir/.archon/workflows"
  mkdir -p "$project_dir/.archon/commands"

  # ── plan-to-pr ──
  local upstream_p2p
  upstream_p2p=$(find_upstream "$project_dir" "archon-plan-to-pr.yaml") \
    || die "Cannot find archon-plan-to-pr.yaml in project or Archon defaults ($ARCHON_DEFAULTS)"

  local hash_p2p
  hash_p2p=$(hash_file "$upstream_p2p")

  local target_p2p="$project_dir/.archon/workflows/archon-board-plan-to-pr.yaml"
  inject_board_nodes "$upstream_p2p" "$target_p2p"
  update_workflow_meta "$target_p2p" "archon-plan-to-pr" "archon-board-plan-to-pr"
  info "Created: archon-board-plan-to-pr.yaml"

  # ── idea-to-pr ──
  local upstream_i2p
  upstream_i2p=$(find_upstream "$project_dir" "archon-idea-to-pr.yaml") \
    || die "Cannot find archon-idea-to-pr.yaml in project or Archon defaults ($ARCHON_DEFAULTS)"

  local hash_i2p
  hash_i2p=$(hash_file "$upstream_i2p")

  local target_i2p="$project_dir/.archon/workflows/archon-board-idea-to-pr.yaml"
  inject_board_nodes "$upstream_i2p" "$target_i2p"
  update_workflow_meta "$target_i2p" "archon-idea-to-pr" "archon-board-idea-to-pr"
  info "Created: archon-board-idea-to-pr.yaml"

  # ── Store upstream hashes ──
  cat > "$project_dir/.archon/.board-review-hash" <<EOF
# archon-board-review upstream hashes — do not edit
# Generated: $(date -Iseconds)
plan-to-pr=$hash_p2p
idea-to-pr=$hash_i2p
upstream-plan-to-pr=$upstream_p2p
upstream-idea-to-pr=$upstream_i2p
EOF
  info "Stored upstream hashes in .archon/.board-review-hash"

  # ── Copy command file ──
  cp "$SCRIPT_DIR/commands/archon-board-review-plan.md" "$project_dir/.archon/commands/"
  info "Copied: archon-board-review-plan.md command"

  info "Installation complete."
  echo ""
  echo "Installed workflows:"
  echo "  archon-board-plan-to-pr  (plan-to-pr + board review + milestone loop)"
  echo "  archon-board-idea-to-pr  (idea-to-pr + board review + milestone loop)"
  echo ""
  echo "Run:  archon workflow list"
  echo "Use:  archon workflow run archon-board-plan-to-pr -- <plan-file>"
}

# ─── check ───────────────────────────────────────────────────────────

cmd_check() {
  local project_dir="${1:-.}"
  project_dir="$(cd "$project_dir" && pwd)"

  local hashfile="$project_dir/.archon/.board-review-hash"
  [ -f "$hashfile" ] || die "No archon-board-review install found. Run 'archon-board-review install' first."

  info "Checking upstream integrity for: $project_dir"

  local stored_p2p stored_i2p upstream_p2p_path upstream_i2p_path
  stored_p2p=$(grep '^plan-to-pr=' "$hashfile" | cut -d= -f2)
  stored_i2p=$(grep '^idea-to-pr=' "$hashfile" | cut -d= -f2)
  upstream_p2p_path=$(grep '^upstream-plan-to-pr=' "$hashfile" | cut -d= -f2)
  upstream_i2p_path=$(grep '^upstream-idea-to-pr=' "$hashfile" | cut -d= -f2)

  local drift=0

  if [ -f "$upstream_p2p_path" ]; then
    local current_p2p
    current_p2p=$(hash_file "$upstream_p2p_path")
    if [ "$current_p2p" = "$stored_p2p" ]; then
      info "plan-to-pr: OK (unchanged)"
    else
      warn "plan-to-pr: DRIFTED — upstream has changed since last install"
      warn "  Board workflow may reference stale phases or missing dependencies."
      warn "  Re-run: archon-board-review install $project_dir"
      drift=1
    fi
  else
    warn "plan-to-pr: upstream file not found at $upstream_p2p_path"
    drift=1
  fi

  if [ -f "$upstream_i2p_path" ]; then
    local current_i2p
    current_i2p=$(hash_file "$upstream_i2p_path")
    if [ "$current_i2p" = "$stored_i2p" ]; then
      info "idea-to-pr: OK (unchanged)"
    else
      warn "idea-to-pr: DRIFTED — upstream has changed since last install"
      warn "  Re-run: archon-board-review install $project_dir"
      drift=1
    fi
  else
    warn "idea-to-pr: upstream file not found at $upstream_i2p_path"
    drift=1
  fi

  if [ "$drift" -eq 0 ]; then
    info "All upstream workflows are in sync."
  else
    echo ""
    echo "Re-install to sync: archon-board-review install $project_dir"
    exit 1
  fi
}

# ─── status ──────────────────────────────────────────────────────────

cmd_status() {
  local project_dir="${1:-.}"
  project_dir="$(cd "$project_dir" && pwd)"

  local hashfile="$project_dir/.archon/.board-review-hash"
  if [ ! -f "$hashfile" ]; then
    echo "archon-board-review: NOT INSTALLED in $project_dir"
    return
  fi

  echo "archon-board-review: INSTALLED"
  echo ""
  echo "Project: $project_dir"
  echo ""

  local board_p2p="$project_dir/.archon/workflows/archon-board-plan-to-pr.yaml"
  local board_i2p="$project_dir/.archon/workflows/archon-board-idea-to-pr.yaml"
  local cmd_file="$project_dir/.archon/commands/archon-board-review-plan.md"

  echo "Workflows:"
  [ -f "$board_p2p" ] && echo "  archon-board-plan-to-pr.yaml  OK" || echo "  archon-board-plan-to-pr.yaml  MISSING"
  [ -f "$board_i2p" ] && echo "  archon-board-idea-to-pr.yaml  OK" || echo "  archon-board-idea-to-pr.yaml  MISSING"
  echo ""
  echo "Commands:"
  [ -f "$cmd_file" ] && echo "  archon-board-review-plan.md   OK" || echo "  archon-board-review-plan.md   MISSING"
  echo ""

  grep '^# Generated:' "$hashfile" | sed 's/# /Installed: /'
}

# ─── config ──────────────────────────────────────────────────────────

cmd_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "No configuration. Run 'archon-board-review setup' first."
    return 1
  fi

  echo "archon-board-review configuration"
  echo "================================="
  echo ""
  echo "Config file: $CONFIG_FILE"
  echo "Board dir:   $(config_get 'board_dir' "$CONFIG_DIR/board")"
  echo "Board user:  $(config_get 'board_user' '(current user)')"
  echo ""

  # Try to resolve Archon
  local archon_path
  archon_path=$(config_get "archon_defaults" "")
  if [ -n "$archon_path" ] && [ -d "$archon_path" ]; then
    echo "Archon defaults: $archon_path (OK)"
  elif [ -n "$archon_path" ]; then
    echo "Archon defaults: $archon_path (NOT FOUND)"
  else
    echo "Archon defaults: (not configured)"
  fi
  echo ""

  echo "Agents:"
  for agent in pragmatist systems-thinker skeptic; do
    local cli model
    cli=$(agent_config "$agent" "cli" "?")
    model=$(agent_config "$agent" "model" "?")
    echo "  $agent: $cli ($model)"
  done
  echo ""

  echo "CLIs detected:"
  command -v claude &>/dev/null && echo "  claude: $(which claude)" || echo "  claude: NOT FOUND"
  command -v codex &>/dev/null && echo "  codex: $(which codex)" || echo "  codex: NOT FOUND"
}

# ─── Main ────────────────────────────────────────────────────────────

case "${1:-}" in
  setup)   shift; cmd_setup "$@" ;;
  install) shift; cmd_install "$@" ;;
  check)   shift; cmd_check "$@" ;;
  status)  shift; cmd_status "$@" ;;
  config)  shift; cmd_config "$@" ;;
  -h|--help|"") usage ;;
  *) die "Unknown command: $1. Run 'archon-board-review --help'." ;;
esac
