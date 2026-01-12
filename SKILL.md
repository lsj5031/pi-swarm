---
name: pi-swarm
description: Spawns parallel pi agents to work on multiple GitHub issues or PRs using git worktrees. Use when asked to process multiple items in parallel, perform bulk reviews/fixes, or orchestrate entire projects.
---

# Pi Swarm

Orchestrates parallel headless pi agents across isolated git worktrees to process GitHub issues, PRs, epics, and entire projects.

## Command Hierarchy

```
Commander (Project/Milestone level)
    │
    ├─► Captain (Epic level)
    │       ├─► swarm.sh (Issue wave 1)
    │       ├─► pr-swarm.sh (Review PRs)
    │       ├─► swarm.sh (Issue wave 2)
    │       └─► ...
    │
    └─► Captain (Another Epic)
            └─► ...
```

## Scripts

### Issue Swarm
Process multiple issues in parallel:
```bash
scripts/swarm.sh 48 50 52
```

### PR Swarm
Review and fix multiple PRs in parallel:
```bash
scripts/pr-swarm.sh 101 105
```

### Captain (Epic Orchestrator)
Orchestrate an entire epic with dependency-aware wave execution:
```bash
scripts/captain.sh --epic 151
```

### Commander (Project/Milestone Orchestrator)
Orchestrate multiple epics or generate a project from scratch:
```bash
# From a milestone issue
scripts/commander.sh --milestone 200

# From specific epics
scripts/commander.sh --epics 151 160 175

# Generate new project from description
scripts/commander.sh --project "Build a CLI todo app with SQLite backend"
```

## What Each Script Does

### swarm.sh
For each issue:
1. **Fetches** details from GitHub API
2. **Creates** isolated git worktree
3. **Spawns** headless pi agent
4. **Commits** and creates PR

### pr-swarm.sh
For each PR:
1. **Fetches** PR and checks out branch
2. **Reviews** with pi agent
3. **Fixes** issues directly
4. **Pushes** and posts comment

### captain.sh
For an epic:
1. **Parses** epic → extracts issues & dependencies
2. **Plans** execution waves
3. **Dispatches** swarm.sh per wave
4. **Reviews** PRs with pr-swarm.sh
5. **Validates** success criteria
6. **Reports** to epic issue

### commander.sh
For a project/milestone:
1. **Parses** milestone OR **generates** project plan
2. **Creates** GitHub issues (if --project mode)
3. **Plans** epic waves with dependencies
4. **Dispatches** captain.sh per epic
5. **Monitors** cross-epic progress
6. **Reports** final status

## Options

### swarm.sh / pr-swarm.sh

| Flag | Description | Default |
|------|-------------|---------|
| `--model <name>` | Model to use | (default) |
| `--push` / `--no-push` | Push changes | enabled |
| `--pr` / `--no-pr` | Create PRs | enabled |
| `--cleanup` / `--no-cleanup` | Delete worktrees | enabled |
| `-j, --jobs <n>` | Max parallel jobs | unlimited |
| `--timeout <min>` | Timeout per task | no timeout |
| `--dry-run` | Preview only | disabled |

### captain.sh

| Flag | Description | Default |
|------|-------------|---------|
| `--epic <num>` | Epic issue number | required |
| `--model <name>` | Model for agents | (default) |
| `--max-retries <n>` | Retries per task | 2 |
| `--wave-timeout <m>` | Timeout per wave | 60 min |
| `--resume` | Resume from state | disabled |
| `--force` | Force start (override stale lock) | disabled |
| `-j, --jobs <n>` | Jobs per wave | unlimited |
| `--dry-run` | Plan only | disabled |

### commander.sh

| Flag | Description | Default |
|------|-------------|---------|
| `--milestone <num>` | Milestone issue | - |
| `--epics <n> ...` | Epic numbers | - |
| `--project <spec>` | Project description | - |
| `--model <name>` | Model for agents | (default) |
| `--max-parallel <n>` | Parallel captains | 2 |
| `--max-retries <n>` | Retries per epic | 1 |
| `--epic-timeout <m>` | Timeout per epic | 120 min |
| `--resume` | Resume from state | disabled |
| `--force` | Force start (override stale lock) | disabled |
| `-j, --jobs <n>` | Jobs per captain | unlimited |
| `--dry-run` | Plan only | disabled |

## Monitoring

```bash
# Swarm logs
tail -f .worktrees/*.log

# Captain state
cat .captain/epic-151.json | jq .

# Commander state  
cat .commander/milestone-200.json | jq .

# Watch all logs
tail -f .worktrees/*.log .captain/*.log .commander/*.log
```

## Output Structure

```
.worktrees/
├── issue-48/           # Worktree
├── issue-48.log        # Log
├── issue-48.jsonl      # Agent JSON log
└── issue-48.pr         # PR URL

.captain/
├── epic-151.json       # State
├── epic-151-plan.json  # Plan
└── epic-151.log        # Log

.commander/
├── milestone-200.json       # State
├── milestone-200-plan.json  # Plan
├── epic-151.log             # Captain logs
└── epic-160.log
```

## Full Workflow

```
commander.sh --project "Todo CLI app"
    │
    ▼
┌─────────────────────┐
│  Generate Plan      │  ← Pi creates epics & issues
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Create GH Issues   │  ← Creates epic + sub-issues
└──────────┬──────────┘
           │
    ┌──────┴──────┐
    ▼             ▼
┌────────┐   ┌────────┐
│Captain │   │Captain │  ← Parallel epics
│Epic #1 │   │Epic #2 │
└───┬────┘   └───┬────┘
    │            │
    ▼            ▼
┌────────┐   ┌────────┐
│ Waves  │   │ Waves  │  ← swarm.sh + pr-swarm.sh
└───┬────┘   └───┬────┘
    │            │
    └─────┬──────┘
          ▼
┌─────────────────────┐
│  Final Report       │  ← Posted to milestone/project
└─────────────────────┘
```

## Error Handling

The scripts detect and handle various error types:

| Error Type | Detection | Behavior |
|------------|-----------|----------|
| **Rate Limit (429)** | "rate limit", "too many requests" | Retry with exponential backoff |
| **Auth (401/403)** | "unauthorized", "forbidden" | **Fatal** - stop immediately |
| **Quota Exceeded** | "quota", "billing", "insufficient" | **Fatal** - stop immediately |
| **Timeout** | Exit code 124 | Retry with backoff |
| **Network** | "connection", "ECONNREFUSED" | Retry with backoff |
| **API Error (5xx)** | "500", "502", "503" | Retry with backoff |

### Fatal Errors

When quota/auth errors are detected:
1. Task marked as `fatal` (won't retry)
2. Error recorded in state file
3. Execution stops after current wave
4. Summary includes error details

### Resuming After Errors

```bash
# Fix the issue (add credits, update API key, etc.)
# Then resume:
scripts/captain.sh --epic 151 --resume

# Force restart if lock is stale:
scripts/captain.sh --epic 151 --resume --force
```

### Process Liveness

- Lock files prevent duplicate runs
- Heartbeat files detect stale processes
- `--force` overrides stale locks

## Examples

```bash
# Process issues with timeout
scripts/swarm.sh --timeout 30 -j 2 48 50 52

# Review PRs (no push)
scripts/pr-swarm.sh --no-push 101 102

# Dry run captain
scripts/captain.sh --epic 151 --dry-run

# Execute epic with opus
scripts/captain.sh --epic 151 --model opus -j 3

# Resume interrupted epic
scripts/captain.sh --epic 151 --resume

# Force resume if lock is stale
scripts/captain.sh --epic 151 --resume --force

# Execute milestone with 3 parallel captains
scripts/commander.sh --milestone 200 --max-parallel 3

# Execute specific epics
scripts/commander.sh --epics 151 160 175

# Generate and execute new project
scripts/commander.sh --project "Build REST API for user management with JWT auth"

# Dry run project generation (shows plan + creates issues)
scripts/commander.sh --project "CLI todo app" --dry-run

# Run cleanup after completion
scripts/commander.sh --milestone 200 --cleanup

# Merge PRs after completion
scripts/commander.sh --epics 151 160 --merge-prs
```
