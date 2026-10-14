require 'erubis'

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
  # The task files are rendered from the ERB templates under
  # +templates/harbor_task/+ (TEMPLATES_DIR) on every run:
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
  #     run_directory: run_directory
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

    # Repository root, used to resolve the repo-local custom Harbor agent
    # package (+bash_script_agent/+) and scenario-relative agent script
    # paths.
    REPO_ROOT = File.expand_path('.')

    # Directory containing the ERB templates for the generated Harbor task
    # directory (instruction, task configuration, Dockerfile environment,
    # entrypoint, and verification tests). Every run renders each template
    # with Erubis into the same relative path under the task directory,
    # with the trailing +.erb+ stripped (see #write_task_files), so the
    # task file contents live in the templates instead of in this file.
    TEMPLATES_DIR = File.expand_path('../../templates/harbor_task', __dir__)

    # Agent names starting with this prefix are the repo-local bash-script
    # custom agent (+bash_script_agent.agent:BashScriptAgent+). For those,
    # the scenario's +model+ value is the path to the bash script the agent
    # should run, relative to the repository root.
    BASH_SCRIPT_AGENT_PREFIX = 'bash_script_agent'

    # Resolves the scenario's +model+ value for the bash-script custom agent
    # into an absolute script path on the host, failing fast (before Harbor
    # and Docker get involved) when the script does not exist.
    #
    # @param model [String] Path to the agent's bash script, relative to the
    #   repository root (absolute paths are also accepted).
    # @return [String] Absolute path to an existing script file.
    # @raise [ArgumentError] If no script exists at the resolved path.
    def self.resolve_agent_script(model)
      path = File.expand_path(model, REPO_ROOT)
      raise ArgumentError, "Agent script not found: #{path} (from agent.model #{model.inspect})" unless File.file?(path)

      path
    end

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
    # @param run_directory [String] The path to the run_directory.
    def initialize(scenario:, sandbox:, run_directory:)
      @scenario = scenario
      @sandbox = sandbox
      @run_directory = run_directory
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
      Debug.with_debug_dir(File.join(@run_directory, 'task'), 'Harbor task directory') do |task_dir|
        # Harbor 0.24.0 task directory structure (instruction.md, task.toml,
        # environment/Dockerfile, environment/entrypoint.sh, tests/test.sh) is
        # rendered from the ERB templates in TEMPLATES_DIR; see #write_task_files.
        write_task_files(task_dir)

        # Harbor 0.24.0 CLI: harbor run -p <task_directory> -a <agent> -m <model>
        # The old `--task <file>` syntax is no longer supported in Harbor 0.24.0
        # In debug mode we pass Harbor's own `--debug` flag (listed under
        # `harbor run --help` Job Settings) plus Docker verbosity below
        # (harbor shells out to docker for builds/runs).
        agent_name = @scenario.agent.fetch('name')
        model = @scenario.agent.fetch('model')
        # For the repo-local bash-script agent, `model` names the bash script
        # implementing the agent; resolve it to a validated absolute host
        # path so the custom agent can upload it into the container.
        model = self.class.resolve_agent_script(model) if agent_name.start_with?(BASH_SCRIPT_AGENT_PREFIX)
        Debug.with_debug_dir(File.join(@run_directory, 'jobs'), 'Harbor jobs directory') do |jobs_dir|
          argv = [
            'harbor', 'run',
            '--yes',
            '--path', task_dir,
            '--agent', agent_name,
            '--model', model,
            '--jobs-dir', jobs_dir
          ]
          argv << '--debug' if Debug.enabled?
          Debug.debug("Executing Harbor run with command: #{argv.inspect}")
          # Harbor interpolates [environment.env] ${VAR} references from this
          # process's environment, so export the resolved agent token under
          # the name task.toml expects. Explicit (not shell-inherited) so
          # Harbor sees it even when spawned via bundler sanitization.
          # Values are redacted by Debug; never interpolate the token into
          # argv, task.toml, or instruction.md.
          agent_token = self.class.agent_token
          harbor_env = {
            AGENT_TOKEN_ENV => agent_token,
            # Force UTF-8 mode: Harbor's secret scrubber calls Path.read_text()
            # without an encoding, which defaults to cp1252 on Windows and turns
            # valid UTF-8 (e.g. emoji in agent output) into
            # "'charmap' codec can't decode byte 0x90" skips. PYTHONUTF8=1 makes
            # open()/read_text() default to UTF-8; PYTHONIOENCODING keeps Harbor's
            # own stdout/stderr UTF-8 through our Open3 pipes. Always set (not
            # debug-only) because scrubbing runs on every `harbor run`.
            'PYTHONUTF8' => '1',
            'PYTHONIOENCODING' => 'utf-8'
          }
          # Let the harbor process import the repo-local custom agent package
          # (bash_script_agent.agent:BashScriptAgent) referenced by scenarios as
          # an --agent import path. Prepended so a repo-local package wins over
          # any same-named module elsewhere; harmless for catalog agents.
          harbor_env['PYTHONPATH'] = [REPO_ROOT, ENV['PYTHONPATH']].compact.reject(&:empty?).join(File::PATH_SEPARATOR)
          harbor_env['GH_TOKEN'] = ENV['GH_TOKEN'] unless ENV['GH_TOKEN'].nil? || ENV['GH_TOKEN'].empty?
          Debug.debug("GitHub token source: #{ENV[AGENT_TOKEN_ENV].nil? || ENV[AGENT_TOKEN_ENV].empty? ? FALLBACK_TOKEN_ENV : AGENT_TOKEN_ENV} (value redacted)")
          env = harbor_env
          if Debug.enabled?
            # Docker's own debug knobs (harbor invokes docker under the hood) plus
            # PYTHONUNBUFFERED so Harbor's `--debug` lines aren't block-buffered
            # through the Open3.popen3 pipes (which Debug streams live).
            env = harbor_env.merge('DOCKER_DEBUG' => '1', 'BUILDKIT_PROGRESS' => 'plain', 'PYTHONUNBUFFERED' => '1')
            Debug.debug("Harbor debug env: #{Debug.redact({ 'DOCKER_DEBUG' => '1', 'BUILDKIT_PROGRESS' => 'plain', 'PYTHONUNBUFFERED' => '1' }.inspect)}")
          end
          stdout, stderr, status = Debug.debug_exec(env, *argv)
          Result.new(status.exitstatus, stdout, stderr)
        end
      end
    end

    private

    # Generates the Harbor task directory from the ERB templates in
    # TEMPLATES_DIR.
    #
    # Every template is rendered with Erubis using this runner's binding
    # (so templates can use +@scenario+ and +@sandbox+ directly) and
    # written to the same relative path under +task_dir+ with the trailing
    # +.erb+ stripped. The recursive glob means a file added under
    # +templates/harbor_task/+ automatically becomes a generated task file;
    # the file contents no longer live in this class.
    #
    # Line endings: templates may be checked out with CRLF on a Windows
    # host, so the rendered output is normalized to LF first.
    # +instruction.md+ and +task.toml+ are then written with File.write
    # (host text-mode newlines, as before), while every other file is
    # written with File.binwrite so the Linux container always receives
    # LF-only bytes (CRLF would mean `bad interpreter` / exit 255 before
    # any log line is produced). Executable shell scripts are chmod'ed to
    # 0o755 for the container.
    #
    # @param task_dir [String] The task directory to write the files into.
    def write_task_files(task_dir)
      templates = Dir.glob(File.join(TEMPLATES_DIR, '**', '*')).sort
      unless templates.any? { |template_path| File.file?(template_path) }
        raise ArgumentError, "No Harbor task templates found in #{TEMPLATES_DIR}"
      end

      templates.each do |template|
        next if File.directory?(template)

        relative = template.delete_prefix("#{TEMPLATES_DIR}#{File::SEPARATOR}")
        target = File.join(task_dir, relative.sub(/\.erb\z/, ''))
        FileUtils.mkdir_p(File.dirname(target))
        source = File.binread(template).force_encoding(Encoding::UTF_8)
        content = Erubis::Eruby.new(source).result(binding).gsub("\r\n", "\n")
        if target.end_with?('.md', '.toml')
          File.write(target, content)
        else
          File.binwrite(target, content)
          File.chmod(0o755, target) if target.end_with?('.sh')
        end
      end
    end
  end
end
