# agentic-dev-bench

Benchmarking AI agents on realistic software development workflows.

This first scaffold uses [Harbor](https://github.com/harbor-framework/harbor), Docker, and GitHub sandboxes. A scenario pins an existing public repository to a commit, creates a fresh private sandbox repository, creates an issue with the requirements, runs an agent through a Harbor adapter, and records run metrics.

## Requirements

- Ruby >= 3.2
- Docker
- Harbor installed and available as `harbor`
- A GitHub token that can create/delete repositories for the configured benchmark owner

## Setup

```bash
bundle install
export GITHUB_TOKEN=...
export GITHUB_OWNER=your-github-user-or-org
# Optional: least-privilege token handed to the agent container
# (contents:write, pull-requests:write, issues:read). Falls back to GITHUB_TOKEN.
export AGENT_GITHUB_TOKEN=...
```

Before running the sample, replace the source repository and immutable commit in `scenarios/add-greeting.yml`. The sample task is intentionally a scaffold: use a repository whose language/test setup matches the requirements you want to benchmark.

## Run

```bash
bundle exec bin/agentic-dev-bench list
bundle exec bin/agentic-dev-bench execute add-greeting
bundle exec bin/agentic-dev-bench execute add-greeting --keep
```

Runs are stored below `runs/` and include the sandbox metadata, Harbor stdout/stderr, and `result.yml`. Successful runs are cleaned up automatically; `--keep` preserves the sandbox for inspection.

## Design

```text
Scenario YAML
     |
     v
GitHub sandbox -----> Issue
     |
     v
Harbor + Docker -----> Agent
     |
     v
Verifier / metrics
     |
     v
Run result + CLI
```

The benchmark definitions contain scenario inputs, not mutable GitHub state. Each run gets a unique sandbox repository, so previous runs cannot affect future runs.

## Next steps

The Harbor adapter is deliberately isolated because Harbor's CLI/API evolves. The next implementation step should align `HarborRunner` with the exact Harbor release being used, then add a proper verifier that runs inside the isolated environment and richer metrics such as tests passed, cost, token usage, commits, PR state, and review comments resolved.

The verifier runs in a separate Harbor container (`environment_mode = "separate"`). Because a separate verifier starts from a fresh sandbox without the agent's filesystem changes, the generated `task.toml` declares the agent's `/workspace` as a top-level `artifacts` entry. Harbor collects that directory after the agent finishes and restores it to `/workspace` in the verifier, so `tests/test.sh` grades the agent's actual clone in place (the `destination` field only affects the host-side save path, not the verifier's copy).

## Security

Use a dedicated GitHub account or GitHub App with minimum required permissions. Do not give an agent credentials that can access unrelated repositories.

The agent container gets `AGENT_GITHUB_TOKEN` (or `GITHUB_TOKEN` as fallback) via Harbor `[environment.env]` interpolation at run time. The generated Dockerfile installs `git` + `gh` and wires `gh auth git-credential` as the git credential helper, but never bakes the token into image layers.
