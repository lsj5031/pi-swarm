# Pi Swarm 🐝

Parallel GitHub issue and PR processing using the `pi` agent and Git worktrees.

## Features

- **Issue Swarm**: Process multiple GitHub issues in parallel
- **PR Swarm**: Review and fix multiple Pull Requests in parallel
- **Captain**: Orchestrate epics with dependency-aware wave execution
- **Commander**: Orchestrate multiple epics or generate entire projects from a description
- **Isolated Worktrees**: Each agent works in its own git worktree
- **Headless Execution**: Uses `pi --mode json` for structured monitoring
- **State Persistence**: Resume interrupted operations
- **Auto-retry**: Failed tasks retry automatically

## Command Hierarchy

```
Commander ──► Captain ──► swarm.sh ──► pi agent
                │              │
                │              └──► pr-swarm.sh ──► pi agent
                │
                └──► Captain ──► ...
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
| `--resume` | Resume from saved state |

### Script-Specific

| Script | Key Options |
|--------|-------------|
| `swarm.sh` | `--pr/--no-pr`, `--push/--no-push`, `--timeout <min>` |
| `pr-swarm.sh` | `--push/--no-push`, `--timeout <min>` |
| `captain.sh` | `--epic <num>`, `--max-retries <n>`, `--wave-timeout <min>` |
| `commander.sh` | `--milestone <num>`, `--epics <...>`, `--project <spec>`, `--max-parallel <n>` |

## Monitoring

```bash
# Watch swarm progress
tail -f .worktrees/*.log

# Captain state
cat .captain/epic-151.json | jq .

# Commander state
cat .commander/milestone-200.json | jq .
```

## Output Structure

```
.worktrees/           # Swarm output
├── issue-48/         # Git worktree
├── issue-48.log      # Human log
├── issue-48.jsonl    # JSON log
└── issue-48.pr       # PR URL

.captain/             # Captain state
├── epic-151.json
├── epic-151-plan.json
└── epic-151.log

.commander/           # Commander state
├── project-abc123.json
├── project-abc123-plan.json
└── epic-*.log
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

# Multiple epics with 3 parallel captains
scripts/commander.sh --epics 151 160 175 --max-parallel 3

# Generate project (dry run to preview)
scripts/commander.sh --project "REST API with JWT auth" --dry-run

# Execute generated project
scripts/commander.sh --project "REST API with JWT auth"
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      Commander                          │
│  - Parses milestone/project                             │
│  - Creates GitHub issues (project mode)                 │
│  - Orchestrates multiple Captains                       │
└────────────────────────┬────────────────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│   Captain    │ │   Captain    │ │   Captain    │
│   Epic #1    │ │   Epic #2    │ │   Epic #3    │
└──────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                │                │
       ▼                ▼                ▼
┌──────────────────────────────────────────────────────┐
│                    swarm.sh                          │
│  - Creates worktrees                                 │
│  - Spawns parallel pi agents                         │
│  - Creates PRs                                       │
└──────────────────────────┬───────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────┐
│                   pr-swarm.sh                        │
│  - Reviews PRs                                       │
│  - Fixes issues                                      │
│  - Posts comments                                    │
└──────────────────────────────────────────────────────┘
```
