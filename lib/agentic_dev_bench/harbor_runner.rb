module AgenticDevBench
  # Runs benchmark scenarios in a Harbor task environment.
  #
  # HarborRunner prepares a Harbor-compatible task directory structure (instruction,
  # task configuration, Dockerfile environment, and verification tests) and executes
  # the Harbor CLI to have an AI agent complete the task. It captures the agent's
  # output and exit status for metrics collection.
  #
  # == Harbor Task Directory Structure
  #
  #   task_dir/
  #     instruction.md     # The prompt for the AI agent
  #     task.toml          # Harbor task configuration
  #     environment/
  #       Dockerfile       # Container image definition
  #     tests/
  #       test.sh          # Verification script run after the agent finishes
  #
  # == Example
  #
  #   runner = AgenticDevBench::HarborRunner.new(
  #     scenario: scenario,
  #     sandbox: sandbox_info,
  #     workspace: workspace_path
  #   )
  #   result = runner.run!
  #   # => #<struct AgenticDevBench::HarborRunner::Result
  #   #      exit_code=0, stdout="...", stderr="...">
  #
  class HarborRunner
    # Result of a Harbor run, capturing the agent's execution status.
    #
    # @!attribute [rw] exit_code
    #   @return [Integer] The agent process exit status code.
    # @!attribute [rw] stdout
    #   @return [String] The standard output captured from the Harbor run.
    # @!attribute [rw] stderr
    #   @return [String] The standard error captured from the Harbor run.
    Result = Data.define(:exit_code, :stdout, :stderr)

    # Environment variable holding the token the agent uses inside the
    # Harbor container. Falls back to GITHUB_TOKEN so existing setups
    # keep working; prefer a dedicated least-privilege token
    # (contents:write, pull-requests:write, issues:read on the sandbox
    # owner) per README's security guidance.
    AGENT_TOKEN_ENV = 'AGENT_GITHUB_TOKEN'
    FALLBACK_TOKEN_ENV = 'GITHUB_TOKEN'

    # Resolves the token handed to the agent container. Never logs the
    # value itself (see Debug.redact).
    #
    # @return [String] The agent-facing GitHub token.
    # @raise [KeyError] If neither AGENT_GITHUB_TOKEN nor GITHUB_TOKEN is set.
    def self.agent_token
      token = ENV[AGENT_TOKEN_ENV]
      token = ENV[FALLBACK_TOKEN_ENV] if token.nil? || token.empty?
      raise KeyError, "Either #{AGENT_TOKEN_ENV} or #{FALLBACK_TOKEN_ENV} must be set" if token.nil? || token.empty?

      token
    end

    # Initializes a new HarborRunner.
    #
    # @param scenario [AgenticDevBench::Scenario] The benchmark scenario to run.
    # @param sandbox [Hash] The sandbox repository information (as returned by
    #   GitHubSandbox#provision!).
    # @param workspace [String] The path to the workspace directory where the
    #   task files will be written and the Harbor run will be executed.
    def initialize(scenario:, sandbox:, workspace:)
      @scenario = scenario
      @sandbox = sandbox
      @workspace = workspace
    end

    # Runs the agent in the Harbor environment.
    #
    # Prepares the task directory structure and executes the Harbor CLI with
    # the agent and model specified in the scenario. Captures all output and
    # returns a Result object.
    #
    # @return [HarborRunner::Result] A Data object with:
    #   * +exit_code+ [Integer] The Harbor process exit status.
    #   * +stdout+ [String] The captured stdout.
    #   * +stderr+ [String] The captured stderr.
    #
    # @raise [SystemCallError] If the Harbor CLI command fails to execute.
    def run!
      task_dir = File.join(@workspace, 'task')
      Debug.debug("Preparing Harbor task directory in #{task_dir}")
      FileUtils.mkdir_p(task_dir)

      # Harbor 0.24.0 task directory structure:
      #   task_dir/
      #     instruction.md
      #     task.toml
      #     environment/
      #       Dockerfile
      #     tests/
      #       test.sh
      File.write(
        File.join(task_dir, 'instruction.md'),
        <<~TXT
          Work on the GitHub repository #{@sandbox['repository_url']}.
          Implement the Github issue number #{@sandbox['issue_number']}.
          Use a new git feature branch for this implementation instead of main.
          Implement the requirements, add appropriate tests, update documentation, and create a pull request when appropriate.
        TXT
      )
      File.write(
        File.join(task_dir, 'task.toml'),
        <<~TOML
          # Harbor task configuration
          language = "ruby"
          framework = "unknown"
          environment_type = "docker"

          # Copy the agent's working tree into the verifier before grading.
          # With [verifier] environment_mode = "separate" below, Harbor starts
          # the verifier from a fresh sandbox WITHOUT the agent's filesystem
          # changes. Declaring /workspace as an artifact makes Harbor collect
          # it after the agent finishes and restore it to its original path
          # (/workspace) in the verifier, so tests/test.sh grades the agent's
          # actual clone in place. `destination` only affects the host-side
          # save path; the verifier always receives the source path.
          artifacts = [
            { source = "/workspace", destination = "workspace" },
          ]

          # Sandbox baseline: GitHub credentials for the agent container.
          # Harbor interpolates ${VAR} from the `harbor run` process
          # environment at run time, so the secret never lands in the
          # Docker image layers. HarborRunner#run! always exports
          # AGENT_GITHUB_TOKEN (= AGENT_GITHUB_TOKEN or GITHUB_TOKEN
          # from the host) into that process env, hence the simple
          # ${AGENT_GITHUB_TOKEN} references below (no nested fallback
          # syntax, which Harbor does not support).
          # GH_TOKEN and GITHUB_TOKEN both feed `gh` headless auth;
          # GIT_TERMINAL_PROMPT=0 turns auth failures into fast errors
          # instead of interactive prompts.
          [environment.env]
          GH_TOKEN = "${AGENT_GITHUB_TOKEN}"
          GITHUB_TOKEN = "${AGENT_GITHUB_TOKEN}"
          GIT_TERMINAL_PROMPT = "0"
          GH_PROMPT_DISABLED = "1"

          # Run the verifier in a dedicated, separate container so the
          # tests/ folder never lands in the agent's environment and
          # grading is isolated from whatever the agent left in its own
          # filesystem. Without a verifier-specific image or build
          # definition, Harbor starts a fresh copy of the agent
          # environment (built from environment/Dockerfile) and uploads
          # tests/ to /tests/ there. A separate verifier does NOT inherit
          # the agent's filesystem changes on its own, but the top-level
          # `artifacts` declaration above copies the agent's /workspace
          # into this verifier first, so tests/test.sh grades the agent's
          # actual working tree in place (its `origin` points at the
          # GitHub sandbox and carries the pushed branch).
          [verifier]
          environment_mode = "separate"

          # The verifier clones the sandbox GitHub repository to grade the
          # pushed branch, so give it read access too.
          [verifier.env]
          GH_TOKEN = "${AGENT_GITHUB_TOKEN}"
          GITHUB_TOKEN = "${AGENT_GITHUB_TOKEN}"
        TOML
      )
      env_dir = File.join(task_dir, 'environment')
      FileUtils.mkdir_p(env_dir)
      File.write(
        File.join(env_dir, 'Dockerfile'),
        <<~DOCKERFILE
          # Base image for the Harbor task environment
          FROM ruby:3.4-bookworm

          # Install required system packages.
          # git: clone/push the sandbox repo; gh: issues/PRs/API without
          # interactive login (reads GH_TOKEN/GITHUB_TOKEN at run time).
          # ca-certificates/curl/gnupg: fetch the official gh apt keyring.
          RUN apt-get update -qq && apt-get install -y --no-install-recommends \
            ca-certificates \
            curl \
            git \
            gnupg \
            && rm -rf /var/lib/apt/lists/*

          # Install the official GitHub CLI from cli.github.com packages.
          # Key fingerprints (SHA256): see https://github.com/cli/cli/blob/trunk/docs/install_linux.md
          RUN mkdir -p /usr/share/keyrings \\
            && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \\
              -o /usr/share/keyrings/githubcli-archive-keyring.gpg \\
            && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \\
            && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \\
              > /etc/apt/sources.list.d/github-cli.list \\
            && apt-get update -qq && apt-get install -y --no-install-recommends gh \\
            && rm -rf /var/lib/apt/lists/* \\
            && git --version && gh --version

          # Non-secret git/gh defaults baked into the image. Credentials
          # themselves are injected at run time via [environment.env]
          # (GH_TOKEN/GITHUB_TOKEN) so they never appear in image layers.
          RUN git config --global --add safe.directory /workspace \\
            && git config --global user.name "agentic-dev-bench" \\
            && git config --global user.email "agentic-dev-bench@local" \\
            && git config --global credential.helper "" \\
            && git config --global --add credential.helper "!gh auth git-credential"
          ENV GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1 GCM_INTERACTIVE=never

          # Clone the sandbox repository at container start (run time), NOT at
          # build time: the GitHub token is injected only via [environment.env]
          # at run time and the sandbox repo is private, so a build-time clone
          # is impossible and would risk baking credentials into image layers.
          # entrypoint.sh performs the authenticated clone once GH_TOKEN /
          # GITHUB_TOKEN are available (the image wires `gh auth git-credential`
          # as the git credential helper). The repository URL is not secret.
          COPY entrypoint.sh /usr/local/bin/adb-entrypoint.sh
          RUN chmod +x /usr/local/bin/adb-entrypoint.sh
          ENV REPO_URL="#{@sandbox['repository_url']}" BASE_BRANCH="main"

          # Set the working directory inside the container
          WORKDIR /workspace

          # Harbor overrides the image CMD (`sh -c "sleep infinity"`) but honors
          # ENTRYPOINT, so adb-entrypoint.sh runs the clone first, then hands
          # off via `exec "$@"` to keep the container alive for the agent.
          ENTRYPOINT ["/usr/local/bin/adb-entrypoint.sh"]
        DOCKERFILE
      )
      entrypoint_file = File.join(env_dir, 'entrypoint.sh')
      File.write(
        entrypoint_file,
        <<~BASH
          #!/bin/sh
          set -eu

          # Harbor task environment entrypoint.
          #
          # The GitHub token is injected only at run time via task.toml
          # [environment.env] (never baked into image layers) and the sandbox
          # repository is private, so a build-time `git clone` cannot work. We
          # clone here, at container start, when GH_TOKEN/GITHUB_TOKEN are
          # present and the `gh auth git-credential` helper (configured in the
          # Dockerfile) authenticates headlessly.
          #
          # Harbor starts the container with `sh -c "sleep infinity"`; this
          # ENTRYPOINT prepares /workspace first, then `exec "$@"` hands off to
          # that command so the container stays alive for the agent.
          REPO_URL="${REPO_URL:?REPO_URL must be set}"
          BASE_BRANCH="${BASE_BRANCH:-main}"
          WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"

          # Fail loudly instead of letting `set -e` kill the container with an
          # opaque status (which Harbor surfaces only as
          # `docker compose ... exited (255)` -> RuntimeError). Capture git's
          # real output to a log AND stderr so it lands in `docker logs` and in
          # Harbor's exception output. NOTE: this is /bin/sh (dash, no
          # pipefail), so we capture via a temp file rather than a pipeline
          # (a pipeline would mask git's non-zero exit code).
          if [ ! -d "$WORKSPACE_DIR/.git" ]; then
            echo "Cloning $REPO_URL into $WORKSPACE_DIR (branch: $BASE_BRANCH)"
            rm -rf "$WORKSPACE_DIR"
            clone_log="$(mktemp)"
            if git clone "$REPO_URL" "$WORKSPACE_DIR" >"$clone_log" 2>&1; then
              cat "$clone_log"
              rm -f "$clone_log"
              git -C "$WORKSPACE_DIR" checkout "$BASE_BRANCH"
            else
              clone_status=$?
              echo "adb-entrypoint: ERROR: 'git clone $REPO_URL' failed (exit $clone_status)." >&2
              echo "adb-entrypoint: This is almost always an auth or network problem. Verify that:" >&2
              echo "adb-entrypoint:   * AGENT_GITHUB_TOKEN / GH_TOKEN is set, valid, and not expired," >&2
              echo "adb-entrypoint:   * it has contents:read on this PRIVATE sandbox repo, and" >&2
              echo "adb-entrypoint:   * this container has network egress to github.com." >&2
              echo "adb-entrypoint: --- git output follows ---" >&2
              cat "$clone_log" >&2
              exit "$clone_status"
            fi
          else
            # Idempotent: Harbor restores the agent's /workspace into the
            # verifier before tests run, so an existing checkout is left as-is.
            echo "$WORKSPACE_DIR already contains a git checkout; leaving it in place"
          fi

          exec "$@"
        BASH
      )
      File.chmod(0o755, entrypoint_file)
      test_file = File.join(task_dir, 'tests', 'test.sh')
      FileUtils.mkdir_p(File.dirname(test_file))
      File.write(
        test_file,
        <<~BASH
          #!/bin/bash
          set -e

          # Harbor runs this verifier in a separate container (see task.toml
          # [verifier] environment_mode = "separate"). The agent's workspace
          # is copied into this verifier via the top-level `artifacts`
          # declaration in task.toml (restored to its original /workspace
          # path), so we grade the agent's clone of the sandbox repository
          # in place (its `origin` points at the GitHub sandbox and carries
          # the pushed branch). WORKSPACE_DIR can override the location if
          # it ever differs from the image's /workspace WORKDIR.
          REPO_DIR="${WORKSPACE_DIR:-/workspace}"
          if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "FAIL: $REPO_DIR is not a git workspace (set WORKSPACE_DIR to the agent workspace)" >&2
            exit 1
          fi
          cd "$REPO_DIR"

          BASE_BRANCH="main"

          fail() {
            echo "FAIL: $1" >&2
            exit 1
          }

          # Refresh origin's view of the pushed branches. Non-fatal: if the
          # remote is unreachable we fall back to the remote-tracking refs
          # already present in the workspace clone.
          if ! git fetch --prune origin "+refs/heads/*:refs/remotes/origin/*" 2>/tmp/adb_fetch_err; then
            echo "WARN: could not refresh origin ($(head -n1 /tmp/adb_fetch_err 2>/dev/null)); using existing remote-tracking refs" >&2
          fi

          # Check that a new branch (anything other than the base branch) has
          # been pushed to origin.
          FEATURE_BRANCHES="$(git for-each-ref --format="%(refname:strip=3)" refs/remotes/origin | grep -vx "$BASE_BRANCH" | grep -vx "HEAD" || true)"
          if [ -z "$FEATURE_BRANCHES" ]; then
            fail "no new branch was pushed to origin (expected a branch other than $BASE_BRANCH)"
          fi

          # ...and that it carries at least one commit beyond the base branch.
          FEATURE_BRANCH=""
          for candidate in $FEATURE_BRANCHES; do
            ahead="$(git rev-list --count "origin/$BASE_BRANCH..origin/$candidate" 2>/dev/null || echo 0)"
            if [ "$ahead" -ge 1 ]; then
              FEATURE_BRANCH="$candidate"
              break
            fi
          done
          if [ -z "$FEATURE_BRANCH" ]; then
            fail "no pushed branch contains at least 1 commit beyond $BASE_BRANCH"
          fi
          echo "PASS: feature branch $FEATURE_BRANCH pushed to origin with $(git rev-list --count "origin/$BASE_BRANCH..origin/$FEATURE_BRANCH") commit(s) beyond $BASE_BRANCH"

          # Check that the branch diff against the base branch modifies at
          # least one file under ./lib and one under ./spec.
          CHANGED_FILES="$(git diff --name-only "origin/$BASE_BRANCH" "origin/$FEATURE_BRANCH")"
          if ! grep -q "^lib/" <<< "$CHANGED_FILES"; then
            fail "branch $FEATURE_BRANCH does not modify any file under ./lib"
          fi
          if ! grep -q "^spec/" <<< "$CHANGED_FILES"; then
            fail "branch $FEATURE_BRANCH does not modify any file under ./spec"
          fi
          echo "PASS: branch $FEATURE_BRANCH modifies files under ./lib and ./spec"

          # Grade the code the agent actually pushed.
          git checkout --quiet -f -B "$FEATURE_BRANCH" "origin/$FEATURE_BRANCH"

          # Install dependencies and run the test suite.
          if ! bundle install; then
            fail "bundle install failed"
          fi
          if ! bundle exec rspec; then
            fail "bundle exec rspec reported failures"
          fi
          echo "PASS: bundle exec rspec succeeded"

          # Execute the scenario's evaluation Ruby snippet with bundler.
          EVAL_FILE="$(mktemp)"
          cat > "$EVAL_FILE" <<'AGENTIC_EVAL_EOF'
          #{@scenario.evaluation['ruby']}
          AGENTIC_EVAL_EOF
          if ! bundle exec ruby "$EVAL_FILE"; then
            fail "scenario evaluation script exited with a non-zero status"
          fi
          echo "PASS: scenario evaluation script succeeded"

          echo "PASS: all verification checks succeeded"
          exit 0
        BASH
      )
      File.chmod(0o755, test_file)

      # Harbor 0.24.0 CLI: harbor run -p <task_directory> -a <agent> -m <model>
      # The old `--task <file>` syntax is no longer supported in Harbor 0.24.0
      # Note: `harbor run` has no stable --debug flag, so in debug mode we
      # rely on our own command/exit/output logging plus Docker verbosity
      # below (harbor shells out to docker for builds/runs).
      agent_name = @scenario.agent.fetch('name')
      model = @scenario.agent.fetch('model')
      argv = [
        'harbor', 'run',
        '--yes',
        '--path', task_dir,
        '--agent', agent_name,
        '--model', model,
        '--jobs-dir', File.join(@workspace, 'jobs')
      ]
      Debug.debug("Executing Harbor run with command: #{argv.inspect}")
      # Harbor interpolates [environment.env] ${VAR} references from this
      # process's environment, so export the resolved agent token under
      # the name task.toml expects. Explicit (not shell-inherited) so
      # Harbor sees it even when spawned via bundler sanitization.
      # Values are redacted by Debug; never interpolate the token into
      # argv, task.toml, or instruction.md.
      agent_token = self.class.agent_token
      harbor_env = { AGENT_TOKEN_ENV => agent_token }
      harbor_env['GH_TOKEN'] = ENV['GH_TOKEN'] unless ENV['GH_TOKEN'].nil? || ENV['GH_TOKEN'].empty?
      Debug.debug("GitHub token source: #{ENV[AGENT_TOKEN_ENV].nil? || ENV[AGENT_TOKEN_ENV].empty? ? FALLBACK_TOKEN_ENV : AGENT_TOKEN_ENV} (value redacted)")
      env = harbor_env
      if Debug.enabled?
        # Docker's own debug knobs (harbor invokes docker under the hood).
        env = harbor_env.merge('DOCKER_DEBUG' => '1', 'BUILDKIT_PROGRESS' => 'plain')
        Debug.debug("Harbor docker debug env: #{Debug.redact({ 'DOCKER_DEBUG' => '1', 'BUILDKIT_PROGRESS' => 'plain' }.inspect)}")
      end
      stdout, stderr, status = Debug.debug_exec(env, *argv)
      Debug.debug("Harbor run finished with exit_code=#{status.exitstatus}")
      Result.new(status.exitstatus, stdout, stderr)
    end
  end
end
