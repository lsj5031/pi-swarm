# Pi Swarm 🐝

Parallel GitHub issue and PR processing using the `pi` agent and Git worktrees.

## Features

- **Issue Swarm**: Process multiple GitHub issues in parallel
- **PR Swarm**: Review and fix multiple Pull Requests in parallel
- **Captain**: Orchestrate epics with dependency-aware wave execution
- **Commander**: Orchestrate multiple epics or generate entire projects from a description
- **Isolated Worktrees**: Each agent works in its own git worktree
- **Headless Execution**: Uses `pi --mode json` for structured monitoring
- **State Persistence**: Resume interrupted operations with `--resume`
- **Auto-retry**: Failed tasks retry automatically with exponential backoff
- **Error Detection**: Smart detection of fatal errors (quota, auth, rate limits)
- **GitHub Issue Management**: Auto-creates issues from task lists in project mode
- **Lock Files**: Prevents duplicate runs with stale lock detection
- **Heartbeat Monitoring**: Tracks process liveness for crash recovery

## Command Hierarchy

```
Commander (Project/Milestone orchestrator)
    │
    ├─► Captain (Epic orchestrator)
    │       ├─► swarm.sh (Issue wave 1)
    │       ├─► pr-swarm.sh (Review PRs)
    │       ├─► swarm.sh (Issue wave 2)
    │       └─► ...
    │
    └─► Captain (Another Epic)
            └─► ...
```

## Installation

1. Dependencies:
   - [gh CLI](https://cli.github.com/) (authenticated)
   - [jq](https://stedolan.github.io/jq/)
   - `pi` agent installed
   - `git`

2. Clone:
   ```bash
   git clone https://github.com/lsj5031/pi-swarm.git
   ```

3. Optional - Install as pi skill:
   ```bash
   mkdir -p ~/.config/agents/skills
   ln -s $(pwd)/pi-swarm ~/.config/agents/skills/pi-swarm
   ```

## Quick Start

> [!IMPORTANT]
> Run scripts from the root of the target repository.

### Work on Issues
```bash
/path/to/pi-swarm/scripts/swarm.sh 12 15 22
```

### Review PRs
```bash
/path/to/pi-swarm/scripts/pr-swarm.sh 101 105
```

### Execute an Epic
```bash
/path/to/pi-swarm/scripts/captain.sh --epic 151
```

### Execute Multiple Epics
```bash
/path/to/pi-swarm/scripts/commander.sh --epics 151 160 175
```

### Generate & Execute a New Project
```bash
/path/to/pi-swarm/scripts/commander.sh --project "Build a CLI todo app with SQLite"
```

## Scripts

### swarm.sh
Processes GitHub issues in parallel. Creates worktrees, runs pi agents, commits changes, and creates PRs.

### pr-swarm.sh
Reviews and fixes PRs in parallel. Checks out PR branches, reviews with pi, pushes fixes, posts comments.

### captain.sh
Orchestrates an epic issue:
1. Parses epic body to extract sub-issues and dependencies
2. Groups issues into parallel-safe waves
3. Executes waves with swarm.sh
4. Reviews PRs with pr-swarm.sh
5. Validates success criteria
6. Posts summary to epic

### commander.sh
Orchestrates multiple epics or projects:
1. Parses milestone OR generates project plan
2. Creates GitHub issues (for --project mode)
3. Executes epics in dependency order
4. Runs multiple captains in parallel
5. Posts final report

## Options

### Common Options

| Flag | Description |
|------|-------------|
| `--model <name>` | Model to use (sonnet, opus, etc.) |
| `-j, --jobs <n>` | Max parallel jobs |
| `--dry-run` | Preview without executing |
| `--resume` | Resume from saved state after interruption |
| `--force` | Force start even if lock file exists (overrides stale locks) |

### Script-Specific

| Script | Key Options |
|--------|-------------|
| `swarm.sh` | `--pr/--no-pr`, `--push/--no-push`, `--cleanup/--no-cleanup`, `--timeout <min>` |
| `pr-swarm.sh` | `--push/--no-push`, `--cleanup/--no-cleanup`, `--timeout <min>` |
| `captain.sh` | `--epic <num>`, `--max-retries <n>`, `--wave-timeout <min>`, `--resume`, `--force` |
| `commander.sh` | `--milestone <num>`, `--epics <...>`, `--project <spec>`, `--max-parallel <n>`, `--cleanup`, `--merge-prs` |

## Monitoring & Logs

```bash
# Watch swarm progress
tail -f .worktrees/*.log

# Captain state (includes issue status, retries, errors)
cat .captain/epic-151.json | jq .

# Commander state
cat .commander/milestone-200.json | jq .

# View specific issue logs
cat .worktrees/issue-48.log

# Check for errors in state
jq '.errors' .captain/epic-151.json

# Monitor heartbeat (process liveness)
cat .captain/.lock-epic-151
```

## Output Structure

```
.worktrees/           # Swarm output
├── issue-48/         # Git worktree (isolated environment)
├── issue-48.log      # Human-readable log
├── issue-48.jsonl    # JSON log (pi agent output)
└── issue-48.pr       # PR URL (created after completion)

.captain/             # Captain state & logs
├── epic-151.json         # State file (issue status, retries, errors)
├── epic-151-plan.json    # Execution plan (waves, dependencies)
├── epic-151.log          # Captain log
└── .lock-epic-151        # Lock file with heartbeat

.commander/           # Commander state & logs
├── project-abc123.json       # State file (epic status)
├── project-abc123-plan.json  # Execution plan
├── epic-151.log              # Per-epic captain logs
└── .lock-project-abc123      # Lock file with heartbeat
```

## Resume & Recovery

### Resuming Interrupted Operations

All scripts support `--resume` to continue after interruption:

```bash
# Resume captain execution
scripts/captain.sh --epic 151 --resume

# Resume commander execution
scripts/commander.sh --milestone 200 --resume

# Force resume if lock is stale (process crashed)
scripts/captain.sh --epic 151 --resume --force
```

### State Persistence

State files track all progress:
- Issue status: `pending`, `in_progress`, `completed`, `failed`, `fatal`
- Retry counts per task
- Error messages and types
- Wave completion status

### Lock Files & Heartbeats

- Lock files prevent duplicate runs
- Heartbeats update every 30s to detect stale processes
- Use `--force` to override stale locks

## Error Handling

### Automatic Error Detection

The system detects and handles these error types:

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

### Recovering from Errors

```bash
# 1. Fix the issue (add credits, update API key, etc.)
# 2. Resume execution
scripts/captain.sh --epic 151 --resume

# 3. If lock is stale, force resume
scripts/captain.sh --epic 151 --resume --force
```

## GitHub Issue Handling

### Project Mode (`--project`)

When using `commander.sh --project`:
1. **Pi agent generates** project plan with epics and tasks
2. **Creates GitHub issues** for epic + all sub-issues
3. **Links issues** with proper dependencies
4. **Executes plan** using captain/swarm orchestration

### Epic Issue Formats

Captain supports multiple epic formats:

**Format 1: Linked Issues**
```markdown
## Sub-Issues
- [ ] #145 - Create API endpoints (1 day)
- [ ] #146 - Build frontend (depends on #145)

## Success Criteria
- All tests passing
- Code reviewed
```

**Format 2: Task List (auto-creates issues)**
```markdown
## Tasks
1. Design database schema
2. Implement REST API
3. Build frontend UI

Captain will create GitHub issues for each task.
```

**Format 3: Simple Description**
```markdown
Build a user authentication system with JWT tokens.

Captain will work on this directly as a single task.
```

## Epic/Milestone Format

For best results with captain/commander, structure your issues with:

```markdown
## Sub-Issues
- [ ] #145 - Create API endpoints (1 day)
- [ ] #146 - Build frontend (depends on #145)

## Parallelization Strategy
Track A: #145 → #146
Track B: #147 (independent)

## Success Criteria
- All tests passing
- Code reviewed
```

## Examples

```bash
# Issues with timeout and job limit
scripts/swarm.sh --timeout 30 -j 2 48 50 52

# PRs without pushing
scripts/pr-swarm.sh --no-push 101 102

# Epic with opus model
scripts/captain.sh --epic 151 --model opus

# Resume interrupted epic
scripts/captain.sh --epic 151 --resume

# Force resume if lock is stale
scripts/captain.sh --epic 151 --resume --force

# Multiple epics with 3 parallel captains
scripts/commander.sh --epics 151 160 175 --max-parallel 3

# Generate project (dry run to preview)
scripts/commander.sh --project "REST API with JWT auth" --dry-run

# Execute generated project
scripts/commander.sh --project "REST API with JWT auth"

# Run cleanup after completion
scripts/commander.sh --milestone 200 --cleanup

# Merge PRs after completion
scripts/commander.sh --epics 151 160 --merge-prs
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      Commander                          │
│  - Parses milestone/project                             │
│  - Creates GitHub issues (project mode)                 │
│  - Orchestrates multiple Captains in parallel           │
│  - Optional cleanup and PR merging                      │
└────────────────────────┬────────────────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│   Captain    │ │   Captain    │ │   Captain    │
│   Epic #1    │ │   Epic #2    │ │   Epic #3    │
│              │ │              │ │              │
│  - Waves     │ │  - Waves     │ │  - Waves     │
│  - Retries   │ │  - Retries   │ │  - Retries   │
│  - State mgmt│ │  - State mgmt│ │  - State mgmt│
└──────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                │                │
       ▼                ▼                ▼
┌──────────────────────────────────────────────────────┐
│                    swarm.sh                          │
│  - Creates isolated worktrees                        │
│  - Spawns parallel pi agents                         │
│  - Commits and creates PRs                           │
│  - Error detection and retry                         │
└──────────────────────────┬───────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────┐
│                   pr-swarm.sh                        │
│  - Reviews PRs with pi agent                         │
│  - Fixes issues directly                             │
│  - Pushes and posts comments                         │
└──────────────────────────────────────────────────────┘
```
