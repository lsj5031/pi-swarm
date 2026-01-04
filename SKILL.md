---
name: pi-swarm
description: Spawns parallel pi agents to work on multiple GitHub issues using git worktrees. Use when asked to work on multiple issues in parallel, batch process issues, or run pi agents on a list of issues.
---

# Pi Swarm

Orchestrates parallel headless pi agents across isolated git worktrees to work on multiple GitHub issues simultaneously.

## Usage

Run the swarm script with issue numbers:

```bash
scripts/swarm.sh 48 50 52
```

Or with options:

```bash
scripts/swarm.sh --model sonnet 48 50 52
```

## What It Does

For each issue number:

1. **Fetches** issue title and body from GitHub API
2. **Creates** a git worktree at `.worktrees/issue-<number>/`
3. **Creates** a branch `issue/<number>`
4. **Spawns** `pi -p "<prompt>"` in the worktree
5. **Commits** changes (agent is instructed to commit; script prompts agent again if it forgets)
6. **Logs** output to `.worktrees/issue-<number>.log`

All issues run in **parallel** using background jobs.

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--model <name>` | Model to use (sonnet, opus, etc.) | (default model) |
| `--push` / `--no-push` | Push branches after completion | enabled |
| `--pr` / `--no-pr` | Create PRs after completion | enabled |
| `--cleanup` / `--no-cleanup` | Delete worktrees after success | enabled |
| `-j, --jobs <n>` | Max parallel jobs | unlimited |
| `--timeout <min>` | Timeout per issue in minutes | no timeout |
| `--dry-run` | Preview actions without executing | disabled |

## Requirements

- `gh` CLI authenticated
- `jq` for JSON parsing
- `pi` installed (Anthropic's pi agent)
- Git repository with GitHub remote

## Monitoring

Watch progress:
```bash
tail -f .worktrees/issue-*.log
```

Check running jobs:
```bash
jobs -l
```

## Output Structure

```
.worktrees/
├── issue-48/           # Worktree for issue 48
├── issue-48.log        # Agent output log
├── issue-50/
├── issue-50.log
└── ...
```

## Example

```bash
# Work on 3 issues in parallel
scripts/swarm.sh 48 50 52

# With specific model and auto-push
scripts/swarm.sh --model sonnet --push 48 50 52

# Without creating PRs
scripts/swarm.sh --no-pr 48 50 52

# Limit to 2 concurrent agents with 30-minute timeout each
scripts/swarm.sh -j 2 --timeout 30 48 50 52 54 56

# Preview what would happen without executing
scripts/swarm.sh --dry-run 48 50 52
```

## Prompt Template

Each agent receives:

```
Work on GitHub Issue #<number>: <title>

<issue body>

Instructions:
1. Read the issue carefully and understand what needs to be done
2. Implement the changes described
3. Run tests to verify your changes work
4. Run linting and formatting
5. Commit your changes with a descriptive message that references issue #<number>
6. Summarize what you did at the end
```
