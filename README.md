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
# Cline API key for the agent container's non-interactive (BYOK) auth.
# The `cline` CLI (driven by cline-rb via PTY.spawn) reads it so it does
# not fall back to an OAuth device-code flow that spawns xdg-open and
# crashes in the headless container. Injected at run time via Harbor
# [environment.env] interpolation; never baked into image layers.
export CLINE_API_KEY=...
# OpenRouter API key for the RubyLLM-driven x_aeon_agents helpers (diff
# interpreter, executor, one-line diff summarizer), configured to the
# `openrouter/free` model in templates/harbor_task/environment/x_aeon_agents_config.rb.
# XAeonAgents::Config reads it from the environment and installs it into
# RubyLLM.config; injected at run time via Harbor [environment.env]
# interpolation, never baked into image layers.
export OPENROUTER_API_KEY=...
```

Before running the sample, replace the source repository and immutable commit in `scenarios/add-greeting.yml`. The sample task is intentionally a scaffold: use a repository whose language/test setup matches the requirements you want to benchmark.

## Run

```bash
bundle exec bin/agentic-dev-bench list
bundle exec bin/agentic-dev-bench execute add-greeting
bundle exec bin/agentic-dev-bench execute add-greeting --keep
```

Runs are stored below `runs/` and include the sandbox metadata, Harbor stdout/stderr, `result.yml` (scalar metrics plus the diff `--stat`), and `git_diff.patch` (full unified diff of the pushed branch). Successful runs are cleaned up automatically; `--keep` preserves the sandbox for inspection.

## Custom bash-script agent

Scenarios can run any bash script as the agent instead of a catalog agent. The repository ships a Harbor custom agent (`bash_script_agent.agent:BashScriptAgent`) that uploads the scenario's script into the task container and executes it:

```yaml
agent:
  name: bash_script_agent.agent:BashScriptAgent
  # Repo-relative path to the bash script implementing the agent.
  model: agents/scripts/example-agent.sh
```

`HarborRunner` prepends the repository root to `PYTHONPATH` so the harbor process can import the custom agent class (no install step required), and validates the script path before invoking Harbor.

Script contract (see `agents/scripts/README.md`):

- Runs as the agent user in `/workspace` (the cloned GitHub sandbox repository), with `git` and authenticated `gh` available.
- The task prompt is exported in the `INSTRUCTION` environment variable.
- Exit non-zero to fail the trial; the scenario's separate verifier still decides the final reward.

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

The Harbor adapter is deliberately isolated because Harbor's CLI/API evolves. The next implementation step should align `HarborRunner` with the exact Harbor release being used, then add richer metrics such as cost, token usage, PR state, and review comments resolved.

### Interpreting run results

`result.yml` separates three distinct notions of success:

- `success` — whether the `harbor run` **CLI process** exited `0`. Harbor treats orchestration as successful even when the trial inside it errors, so `success: true` does **not** mean the agent passed.
- `agent_exception` — the exception type raised while the **agent** ran (e.g. `NonZeroAgentExitCodeError` when the agent script exits non-zero, including a failed PR-creation step after a successful push), or empty when the agent phase completed cleanly. Collection failures with no trial `result.json` (`ResultFileNotFound`, `ResultFileUnparseable`) are reported here.
- `verifier_reward` / `verifier_passed` / `verifier_exception` — the **verifier's actual verdict**, read from Harbor's per-trial `result.json` (`verifier_result.rewards.reward`). `verifier_passed` is `true` only when the reward is `>= 1.0`. `verifier_exception` records only an abort inside the separate verifier container's window; it is empty when the verifier phase completed cleanly.

The global `Overall:` status is strict: it is successful only when the verifier passes completely **and** neither phase raised an exception. A run can legitimately show `success: true` alongside `verifier_passed: true` but still be `Overall: FAIL` (for example, when the agent pushed the branch and the verifier graded `1.0`, but the agent's mandatory PR-creation step crashed with `422 base invalid`).

The verifier runs in a separate Harbor container (`environment_mode = "separate"`). Because a separate verifier starts from a fresh sandbox without the agent's filesystem changes, the generated `task.toml` declares the agent's `/workspace` as a top-level `artifacts` entry. Harbor collects that directory after the agent finishes and restores it to `/workspace` in the verifier, so `tests/test.sh` grades the agent's actual clone in place (the `destination` field only affects the host-side save path, not the verifier's copy).

## Security

Use a dedicated GitHub account or GitHub App with minimum required permissions. Do not give an agent credentials that can access unrelated repositories.

The agent container gets `AGENT_GITHUB_TOKEN` (or `GITHUB_TOKEN` as fallback) via Harbor `[environment.env]` interpolation at run time. The generated Dockerfile installs `git` + `gh` and wires `gh auth git-credential` as the git credential helper, but never bakes the token into image layers.

The agent container also gets `CLINE_API_KEY` the same way (required; `HarborRunner` fails fast if it is unset). The `cline` CLI authenticates with this key non-interactively (BYOK) instead of launching an OAuth device-code flow that would spawn `xdg-open` and crash in the headless container. Like the GitHub token, it is injected at run time and never baked into image layers; `Debug.redact` masks it in all logs.

The agent container also gets `OPENROUTER_API_KEY` the same way (required; `HarborRunner` fails fast if it is unset). The RubyLLM-driven AiAgents helpers (diff interpreter, executor, one-line diff summarizer), configured to the `openrouter/free` model in `templates/harbor_task/environment/x_aeon_agents_config.rb`, authenticate through it: `XAeonAgents::Config` reads it from the environment and installs it into `RubyLLM.config`. Without it those helpers fall back to an OpenAI-hosted default model and crash with `Missing configuration for OpenAI: openai_api_key`. Like the other keys, it is injected at run time and never baked into image layers; `Debug.redact` masks it in all logs.
