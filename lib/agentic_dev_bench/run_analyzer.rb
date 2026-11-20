require 'fileutils'
require 'git'
require 'logger'
require 'yaml'

module AgenticDevBench
  # Analyzes a completed benchmark run and writes a human-readable report.
  class RunAnalyzer
    # A run stores its collected metrics in +runs/<run_id>/results/result.yml+
    # (see AgenticDevBench::Metrics) and its artifacts under +runs/<run_id>/+:
    # +sandbox.yml+, +task/+ (the generated Harbor task), +jobs/+ (trial logs,
    # session messages and verifier output) and +git-diff/+ (the clone of the
    # sandbox repository kept by Metrics#compute_git_diff). RunAnalyzer reads
    # those artifacts, inspects the run's diff and verifier output, and writes
    # a Markdown report to +runs/<run_id>/analysis.md+.
    #
    # The report contains:
    # * The task and source repository metadata, read from the scenario file
    #   matching the run's sandbox repository.
    # * The agent name and model, read from the scenario file and, for
    #   +x_aeon_agents+ runs, from the generated
    #   +task/environment/x_aeon_agents_config.rb+.
    # * An overview of the verifier-observed facts: branch pushed, pull
    #   request created, production/tests/documentation modified, tests
    #   passing and feature working.
    # * An analysis of the production code, the tests and the documentation,
    #   each produced by a dedicated ComposableAgents::Cline::Agent reviewing
    #   only the relevant part of the run's diff.
    # * A chronological summary of the agent run, produced by another Cline
    #   agent that reads the whole run directory (logs, sessions, metrics).
    #
    # == Analysis agents
    #
    # The analysis agents authenticate with +CLINE_API_KEY+ and can be pointed
    # at another provider/model through the +ANALYSIS_PROVIDER+ and
    # +ANALYSIS_MODEL+ environment variables (defaults: +cline+ and
    # +nvidia/nemotron-3.5-lightning-free+). They log to
    # +runs/<run_id>/analysis.log+. Their answers are limited to
    # ANALYSIS_ANSWER_MAX_LINES (30) lines for the analyses and
    # SUMMARY_ANSWER_MAX_LINES (60) lines for the run summary, and an answer
    # that misses or breaks its output artifact is retried up to
    # ANALYSIS_AGENT_MAX_RETRIES (3) times (see the Retriable and
    # RetriableArtifacts mixins). They run from
    # +runs/<run_id>/analysis/workdir+ (the Cline CLI and the agents' file
    # tools create files in their working directory), so analyzing a run never
    # writes into the project repository. A section whose agent still fails to
    # produce its analysis (missing API key, no network...) is rendered with
    # the error instead of failing the whole report, so the deterministic part
    # of the report is always written.
    #
    # The verdict reported is +verifier_passed+, not +success+: +success+ only
    # reflects whether the +harbor run+ CLI process exited 0, while
    # +verifier_passed+ is the verifier's actual grade (see
    # AgenticDevBench::Metrics).
    #
    # == Example
    #
    #   analyzer = AgenticDevBench::RunAnalyzer.new('202610141540011-greeting-cline-ok')
    #   analyzer.analyze!
    #   # => "C:/.../agentic-dev-bench/runs/202610141540011-greeting-cline-ok/analysis.md"
    #   puts analyzer.passed? ? 'Run passed' : 'Run failed'

    # Name of the Markdown report written into the run directory.
    ANALYSIS_FILE = 'analysis.md'

    # Name of the log file receiving the analysis agents' output.
    ANALYSIS_LOG_FILE = 'analysis.log'

    # Sub-directory of the run's +analysis/+ directory used as the analysis
    # agents' working directory (see #with_analysis_workdir).
    ANALYSIS_WORKDIR = 'workdir'

    # Sub-directory of the run directory holding the clone of the sandbox
    # repository that Metrics#compute_git_diff keeps (debug runs).
    GIT_DIFF_DIR = 'git-diff'

    # Glob, relative to the run directory, matching the verifier's stdout.
    VERIFIER_STDOUT_GLOB = File.join('jobs', '*', 'task__*', 'verifier', 'test-stdout.txt')

    # Git identity configured in the Harbor task image (see
    # templates/harbor_task/environment/Dockerfile.erb). Commits made by the
    # +x_aeon_agents+ pipeline are authored with it.
    AGENT_GIT_USER_NAME = 'agentic-dev-bench'

    # Harbor agent identifier of the Cline CLI agent (see scenarios/*.yml).
    CLINE_AGENT_NAME = 'cline-cli'

    # Label used in the report for the +x_aeon_agents+ pipeline, which runs
    # through the +bash_script_agent.agent:BashScriptAgent+ Harbor agent.
    XAA_AGENT_NAME = 'x_aeon_agents'

    # Bash script identifying an +x_aeon_agents+ run among the bash-script
    # agent scenarios (see agents/scripts/xaa.sh).
    XAA_AGENT_SCRIPT = 'xaa.sh'

    # Maximum length of an agent error message rendered in the report.
    ANALYSIS_FAILURE_MAX_LENGTH = 500

    # Maximum number of lines of a production code / tests / documentation analysis.
    ANALYSIS_ANSWER_MAX_LINES = 30

    # Maximum number of lines of the run summary.
    SUMMARY_ANSWER_MAX_LINES = 60

    # Maximum number of retries of an analysis agent when its answer misses or
    # breaks an output artifact (see ComposableAgents::Mixins::RetriableArtifacts).
    ANALYSIS_AGENT_MAX_RETRIES = 3

    # Default provider of the analysis agents (overridden by ANALYSIS_PROVIDER).
    DEFAULT_ANALYSIS_PROVIDER = 'cline'

    # Default model of the analysis agents (overridden by ANALYSIS_MODEL).
    DEFAULT_ANALYSIS_MODEL = 'nvidia/nemotron-3.5-lightning-free'

    # Output artifact name of the production/tests/documentation analyses.
    ANALYSIS_OUTPUT_ARTIFACT = :analysis

    # Output artifact name of the run summary agent.
    SUMMARY_OUTPUT_ARTIFACT = :summary

    # Regexp matching one +configure_agent ... model:+ block of the rendered
    # x_aeon_agents configuration (see
    # templates/harbor_task/environment/x_aeon_agents_config.rb).
    # Captures the agent class names of the preceding +%i[...]+ list, and the
    # model they are configured with.
    #
    # +%r!...!+ is used instead of +/.../+ because the comments of an extended
    # regexp cannot contain a slash.
    XAA_CONFIGURE_AGENT_REGEXP = %r!
      %i\[([^\]]+)\]                          # %i[AgentOne AgentTwo]
      \s*\.each\s+do\s*\|[^|]+\|               # .each do |agent_class_name|
      \s*configure_agent\([^)]*\)              # configure_agent(agent_class_name)
      \s*\{\s*\{\s*model:\s*['"]([^'"]+)['"]  # { { model: 'provider-model'
    !x

    # Prompt given to the run summary agent.
    #
    # Adapted from prompt.txt: instead of pointing the agent at the most recent
    # folder of +./runs+, the prompt is rendered with the run directory being
    # analyzed (see #run_summary_prompt).
    RUN_SUMMARY_PROMPT = <<~PROMPT
      Have a look at the Harbor run whose full logs and results are in the directory `%<run_directory>s`.
      Give me a chronological summary of all the steps the Harbor agent was going through. You can see the main agent log file, and also all the session messages that the agent is using (especially the Cline ones), under that directory.
      For each one of those steps, see if you see some rooms for improvements, so that the agent could have performed its task in a faster or more efficient way. Check potential errors, useless loops or inefficient prompts.
      In case of failure at the end, analyze the root cause of this failure and explain what could be done to prevent this failure.
      After this, give me also a summary of the main patterns you see that could be improved (bugs, infinite loops, prompts, timeouts, inconsistencies...).
      Do not exceed #{SUMMARY_ANSWER_MAX_LINES} lines in your whole answer, and do not add any preamble or conclusion.
    PROMPT

    # One file of the run's diff: its repository-relative path, its git status
    # (+A+, +M+, +D+ or +R+) and its unified diff text.
    AnalysisDiffChunk = Data.define(:path, :status, :text)

    # @return [String] The ID of the analyzed run.
    attr_reader :run_id

    # @return [String] The absolute path of the analyzed run directory.
    attr_reader :directory

    # Initializes a new RunAnalyzer.
    #
    # Resolves the run directory from the run ID; the directory must already
    # exist (runs are created by AgenticDevBench::Run).
    #
    # @param run_id [String] The run ID to analyze (a sub-folder name under
    #   +runs/+, as listed by the +list-runs+ CLI command).
    #
    # @raise [ArgumentError] When no run directory exists for +run_id+.
    def initialize(run_id)
      @run_id = run_id
      @directory = Run.directory_for(run_id)
      return if File.directory?(@directory)

      available = Run.all_ids
      raise ArgumentError, "Run '#{run_id}' not found. Available: #{available.empty? ? '(none)' : available.join(', ')}"
    end

    # @return [String] The absolute path of the generated Markdown report.
    def analysis_path
      File.join(directory, ANALYSIS_FILE)
    end

    # Returns the run's collected metrics.
    #
    # Reads +results/result.yml+ on first access and memoizes the parsed YAML.
    #
    # @return [Hash] The parsed metrics (see AgenticDevBench::Metrics).
    #
    # @raise [Errno::ENOENT] When +result.yml+ is missing.
    # @raise [Psych::Exception] When +result.yml+ cannot be parsed.
    def result
      @result ||= YAML.load_file(File.join(directory, 'results', 'result.yml'))
    end

    # Reports whether the run's verifier passed.
    #
    # @return [Boolean] +true+ only when the +verifier_passed+ metric is
    #   +true+; a missing or non-boolean value is treated as a failure.
    def passed?
      result['verifier_passed'] == true
    end

    # Analyzes the run and writes the Markdown report.
    #
    # Reads the run artifacts, checks the +verifier_passed+ verdict, runs the
    # analysis agents and writes +analysis.md+ into the run directory.
    # Running it twice overwrites the previous report.
    #
    # @return [String] The absolute path of the written report.
    #
    # @example
    #   AgenticDevBench::RunAnalyzer.new('202610141540011-greeting-cline-ok').analyze!
    def analyze!
      Debug.debug("Analyzing run #{run_id} in #{directory}")
      File.write(analysis_path, analysis_content)
      Debug.debug("Wrote analysis to #{analysis_path}")
      analysis_path
    end

    private

    # Returns the scenario of this run.
    #
    # The scenario is not referenced in the run artifacts: it is recovered from
    # the sandbox repository name (+<name_prefix>-<scenario id>-<run id>+, see
    # AgenticDevBench::GithubSandbox#initialize) read from +sandbox.yml+.
    # Run folders may have been renamed by hand after the run, so only the
    # +<name_prefix>-<scenario id>-+ prefix is matched, and the longest matching
    # scenario ID wins.
    #
    # @return [AgenticDevBench::Scenario] The scenario that produced this run.
    #
    # @raise [ArgumentError] When no scenario matches the run's repository.
    def scenario
      @scenario ||= begin
        candidates = Scenario.all
        name = sandbox_repository_name
        matches = candidates.select { |candidate| scenario_repository_match?(candidate, name) }
        matches = candidates.select { |candidate| name.include?("-#{candidate.id}-") } if matches.empty?
        match = matches.max_by { |candidate| candidate.id.length }
        unless match
          raise ArgumentError,
                "No scenario matches the sandbox repository '#{name}' of run '#{run_id}'. " \
                "Available scenarios: #{candidates.map(&:id).sort.join(', ')}"
        end

        Debug.debug("Run #{run_id} was produced by scenario #{match.id}")
        match
      end
    end

    # Reports whether the given scenario produced the sandbox repository +name+.
    #
    # @param candidate [AgenticDevBench::Scenario] The scenario to test.
    # @param name [String] The sandbox repository name (owner/name).
    #
    # @return [Boolean]
    def scenario_repository_match?(candidate, name)
      base = File.basename(name)
      prefix = candidate.sandbox['name_prefix'].to_s
      return base.start_with?("#{prefix}-#{candidate.id}-") unless prefix.empty?

      base.start_with?("#{candidate.id}-")
    end

    # @return [String] The source repository of the scenario (owner/name).
    def github_repository
      scenario.source.fetch('repository')
    end

    # @return [String] The source repository commit ref of the scenario.
    def commit_ref
      scenario.source.fetch('commit')
    end

    # @return [String] The GitHub issue title the agent had to implement.
    def issue_title
      scenario.issue.fetch('title')
    end

    # @return [String] The GitHub issue body the agent had to implement.
    def issue_description
      scenario.issue.fetch('body')
    end

    # @return [String] The task description given to the review agents.
    def task_description
      @task_description ||= "# #{issue_title}\n\n#{issue_description}\n"
    end

    # Returns the sandbox metadata saved in the run directory.
    #
    # @return [Hash] The parsed +sandbox.yml+ (see GithubSandbox#provision!).
    #
    # @raise [Errno::ENOENT] When +sandbox.yml+ is missing.
    def sandbox
      @sandbox ||= YAML.load_file(sandbox_path)
    end

    # @return [String] The absolute path of the run's sandbox metadata.
    def sandbox_path
      File.join(directory, 'sandbox.yml')
    end

    # @return [String] The sandbox repository name (owner/name).
    def sandbox_repository_name
      @sandbox_repository_name ||= begin
        repository = sandbox['repository'] || sandbox['repository_url']
        raise ArgumentError, "No sandbox repository found in #{sandbox_path}" unless repository

        repository.to_s.sub(%r{\Ahttps?://github\.com/}i, '').sub(/\.git\z/i, '')
      end
    end

    # Returns the unified diff of the run's work, against the base branch.
    #
    # The diff is computed from the clone of the sandbox repository kept in
    # +git-diff/+ (see Metrics#compute_git_diff): it compares the base branch
    # with the latest commit the agent pushed on a feature branch. Commits
    # authored by AGENT_GIT_USER_NAME are preferred (the x_aeon_agents
    # pipeline commits with that identity); the tip of the newest branch ahead
    # of the base is used otherwise (agents such as +cline-cli+ commit with
    # their own identity).
    #
    # @return [String] The unified diff, or +''+ when the run pushed nothing.
    def files_diff
      @files_diff ||= compute_files_diff
    end

    # Computes {#files_diff} with the git Rubygem.
    #
    # @return [String] The unified diff, or +''+ when there is nothing to diff.
    def compute_files_diff
      unless File.directory?(File.join(diff_clone_directory, '.git'))
        Debug.debug("No git clone found in #{diff_clone_directory}; the run diff is empty")
        return ''
      end

      with_safe_directory(diff_clone_directory) do
        repo = Git.open(diff_clone_directory)
        commit = agent_commit(repo)
        if commit.nil?
          Debug.debug("No branch ahead of #{Metrics::BASE_BRANCH} found; the run diff is empty")
          return ''
        end

        Debug.debug(
          "Computing git diff #{Metrics::BASE_BRANCH}..#{commit.sha} (author: #{commit.author.name}, #{commit.committer.date})"
        )
        repo.diff_full(Metrics::BASE_BRANCH, commit.sha)
      end
    rescue Git::Error => e
      Debug.debug("Could not compute the run diff: #{e.class}: #{e.message}")
      ''
    end

    # @return [String] The absolute path of the sandbox repository clone.
    def diff_clone_directory
      File.join(directory, GIT_DIFF_DIR)
    end

    # Returns the commit holding the work of the run.
    #
    # @param repo [Git::Repository] The sandbox repository clone.
    #
    # @return [Git::Object::Commit, nil] The newest commit authored by the
    #   agent on the newest feature branch, or +nil+ when the agent pushed no
    #   branch ahead of the base branch.
    def agent_commit(repo)
      tip = feature_branch_tips(repo).max_by { |commit| commit.committer.date }
      return nil if tip.nil?

      repo.log(:all).between(Metrics::BASE_BRANCH, tip.sha).author(AGENT_GIT_USER_NAME).execute.first || tip
    end

    # Lists the tips of the branches ahead of the base branch.
    #
    # @param repo [Git::Repository] The sandbox repository clone.
    #
    # @return [Array<Git::Object::Commit>] One commit per branch ahead of
    #   Metrics::BASE_BRANCH (the base branch and +HEAD+ are ignored).
    def feature_branch_tips(repo)
      repo.branch_list
          .reject { |branch| [Metrics::BASE_BRANCH, 'HEAD'].include?(branch.short_name) }
          .filter_map { |branch| branch.target_oid && repo.gcommit(branch.target_oid) }
          .uniq(&:sha)
          .select { |commit| ahead_of_base?(repo, commit) }
    end

    # Reports whether +commit+ is ahead of the base branch.
    #
    # @param repo [Git::Repository] The sandbox repository clone.
    # @param commit [Git::Object::Commit] The commit to test.
    #
    # @return [Boolean]
    def ahead_of_base?(repo, commit)
      repo.merge_base(commit.sha, Metrics::BASE_BRANCH) != [commit.sha]
    rescue Git::Error => e
      Debug.debug("Could not compute the merge base of #{commit.sha}: #{e.class}: #{e.message}")
      false
    end

    # Runs a block of git operations with +safe.directory+ pointing at +dir+.
    #
    # Run artifacts are written by the Harbor containers, so on some hosts
    # (notably Windows) they are owned by another user than the one running
    # the analysis, and git then refuses every command with "detected dubious
    # ownership". The git Rubygem does not expose per-call global options, so
    # the setting is passed through git's GIT_CONFIG_* environment interface
    # (the equivalent of <tt>git -c safe.directory=DIR</tt>) temporarily merged
    # into ENV for the duration of the block, and restored afterwards
    # (including on exception), mirroring GithubSandbox#with_git_trace.
    #
    # @param dir [String] The repository directory to trust.
    # @yield The git operations to run.
    # @return [Object] The block's return value.
    def with_safe_directory(dir)
      overrides = {
        'GIT_CONFIG_COUNT' => '1',
        'GIT_CONFIG_KEY_0' => 'safe.directory',
        'GIT_CONFIG_VALUE_0' => File.expand_path(dir)
      }
      saved = overrides.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      begin
        overrides.each { |key, value| ENV[key] = value }
        yield
      ensure
        saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end
    end

    # Returns the run diff split per file.
    #
    # @return [Array<AnalysisDiffChunk>] One chunk per changed file.
    def diff_chunks
      @diff_chunks ||= files_diff.split(/^(?=diff --git )/).filter_map do |text|
        path = diff_chunk_path(text)
        next if path.nil?

        AnalysisDiffChunk.new(path:, status: diff_chunk_status(text), text:)
      end
    end

    # Returns the repository-relative path of a diff chunk.
    #
    # @param text [String] One <tt>diff --git</tt> section of the diff.
    #
    # @return [String, nil] The path (the +b/+ side), or +nil+ when the chunk
    #   has no parsable header.
    def diff_chunk_path(text)
      match = text.lines.first.to_s.chomp.match(%r{\Adiff --git a/(.+) b/(.+)\z})
      match && match[2]
    end

    # Returns the git status of a diff chunk.
    #
    # @param text [String] One <tt>diff --git</tt> section of the diff.
    #
    # @return [String] +A+ for a new file, +D+ for a deleted one, +R+ for a
    #   rename, +M+ otherwise.
    def diff_chunk_status(text)
      return 'A' if text.match?(/^new file mode /)
      return 'D' if text.match?(/^deleted file mode /)
      return 'R' if text.match?(/^rename from /)

      'M'
    end

    # Returns the part of the run diff matching some paths.
    #
    # @param prefixes [Array<String>] Directory prefixes to keep (e.g. +lib/+).
    # @param files [Array<String>] Exact paths to keep (e.g. +README.md+).
    #
    # @return [String] The unified diff of the matching files (empty when none).
    def filtered_diff(prefixes: [], files: [])
      diff_chunks
        .select { |chunk| prefixes.any? { |prefix| chunk.path.start_with?(prefix) } || files.include?(chunk.path) }
        .map(&:text)
        .join("\n")
    end

    # Reports whether the run added or modified some files under +prefix+.
    #
    # @param prefix [String] The directory prefix (e.g. +lib/+).
    #
    # @return [Boolean] +true+ when a file was added, modified or renamed
    #   under +prefix+ (deletions alone do not count).
    def changed_under?(prefix)
      diff_chunks.any? { |chunk| chunk.path.start_with?(prefix) && chunk.status != 'D' }
    end

    # @return [Boolean] +true+ when some production code (+lib/+) was modified.
    def production_changed?
      changed_under?('lib/')
    end

    # @return [Boolean] +true+ when some tests (+spec/+) were modified.
    def tests_changed?
      changed_under?('spec/')
    end

    # @return [Boolean] +true+ when README.md was added or modified.
    def documentation_changed?
      diff_chunks.any? { |chunk| chunk.path == 'README.md' && chunk.status != 'D' }
    end

    # Returns the verifier's standard output.
    #
    # Concatenates every +jobs/*/task__*/verifier/test-stdout.txt+ file of the
    # run (a run normally has exactly one).
    #
    # @return [String] The verifier output (empty when the run has none).
    def verifier_output
      @verifier_output ||= Dir[File.join(directory, VERIFIER_STDOUT_GLOB)]
                           .sort
                           .map { |path| File.binread(path).force_encoding(Encoding::UTF_8).scrub }
                           .join("\n")
    end

    # @return [Boolean] +true+ when the verifier saw a feature branch pushed.
    def branch_pushed?
      verifier_output.match?(/^PASS: feature branch .+ pushed to origin/)
    end

    # @return [Boolean] +true+ when the verifier saw an open pull request.
    def pr_created?
      verifier_output.match?(/^PASS: open pull request .+ found for feature branch/)
    end

    # @return [Boolean] +true+ when the verifier saw the test suite pass.
    def tests_passing?
      verifier_output.match?(/^PASS: bundle exec rspec succeeded/)
    end

    # @return [Boolean] +true+ when the verifier saw the scenario evaluation pass.
    def feature_working?
      verifier_output.match?(/^PASS: scenario evaluation script succeeded/)
    end

    # Returns the name of the agent that performed the run, normalized.
    #
    # @return [String] +cline-cli+ for the Cline CLI agent, +x_aeon_agents+ for
    #   the x_aeon_agents pipeline (run through the bash-script Harbor agent),
    #   or the raw scenario agent name for any other agent.
    def agent_name
      @agent_name ||= begin
        name = scenario.agent.fetch('name')
        if name == CLINE_AGENT_NAME
          CLINE_AGENT_NAME
        elsif File.basename(scenario.agent['model'].to_s) == XAA_AGENT_SCRIPT
          XAA_AGENT_NAME
        else
          name
        end
      end
    end

    # Returns the model used by the run's agent, normalized as
    # +provider/model+ (e.g. +nvidia/nemotron-3.5-lightning-free+).
    #
    # @return [String] The model configured for the agent.
    def agent_model
      @agent_model ||= agent_name == XAA_AGENT_NAME ? xaa_agent_model : cline_agent_model
    end

    # Returns the model of a +cline-cli+ run, as configured in the scenario.
    #
    # The scenario uses Harbor's +<provider>:<model>+ notation
    # (e.g. +cline:nvidia/nemotron-3.5-lightning-free+), so the provider
    # prefix is stripped to keep only the model.
    #
    # @return [String] The model identifier.
    def cline_agent_model
      scenario.agent.fetch('model').to_s.sub(/\Acline:/, '')
    end

    # Returns the model of an +x_aeon_agents+ run.
    #
    # The model is not part of the scenario (it only names the agent script):
    # it is configured in the run's generated
    # +task/environment/x_aeon_agents_config.rb+. The block configuring
    # +CoderAgent+ is authoritative (the other blocks configure the AiAgents
    # helpers, which use OpenRouter directly); the first non-OpenRouter model,
    # then the first model found, are used as fallbacks.
    #
    # @return [String] The model identifier.
    def xaa_agent_model
      by_class = xaa_agent_models_by_class
      by_class['CoderAgent'] ||
        by_class.values.find { |model| model != 'openrouter/free' } ||
        xaa_config_models.first ||
        'unknown'
    end

    # Returns the models configured in the x_aeon_agents configuration, per
    # agent class name.
    #
    # @return [Hash{String => String}] Model per agent class name.
    def xaa_agent_models_by_class
      @xaa_agent_models_by_class ||=
        xaa_config_text.scan(XAA_CONFIGURE_AGENT_REGEXP).each_with_object({}) do |(class_names, model), models|
          class_names.split.each { |class_name| models[class_name] = model }
        end
    end

    # Returns every model mentioned in the x_aeon_agents configuration.
    #
    # @return [Array<String>] The models, in file order.
    def xaa_config_models
      @xaa_config_models ||= xaa_config_text.scan(/model:\s*['"]([^'"]+)['"]/).flatten
    end

    # Returns the content of the run's x_aeon_agents configuration.
    #
    # @return [String] The configuration file content (empty when absent).
    def xaa_config_text
      @xaa_config_text ||= begin
        path = File.join(directory, 'task', 'environment', 'x_aeon_agents_config.rb')
        Debug.debug("Reading the x_aeon_agents configuration from #{path}")
        File.exist?(path) ? File.read(path, encoding: 'UTF-8').scrub : ''
      end
    end

    # Builds a Cline agent used for one section of the report.
    #
    # The agent's provider and model come from the ANALYSIS_PROVIDER and
    # ANALYSIS_MODEL environment variables (defaults: cline and
    # nvidia/nemotron-3.5-lightning-free), it stores its temporary state under
    # the run directory and logs to +runs/<run_id>/analysis.log+.
    #
    # @param name [String] The agent name (used in logs).
    # @param role [String] The agent's role.
    # @param objective [String] The agent's objective.
    # @param instructions [String] The agent's system instructions.
    # @param input_artifacts [Hash{Symbol => Hash}] The input artifacts contracts.
    # @param output_artifacts [Hash{Symbol => Hash}] The output artifacts contracts.
    # @param max_lines [Integer] The maximum number of lines of the agent's
    #   answer (defaults to ANALYSIS_ANSWER_MAX_LINES).
    #
    # @return [ComposableAgents::Cline::Agent] The configured agent.
    def cline_agent(name:, role:, objective:, instructions:, input_artifacts:, output_artifacts:,
                    max_lines: ANALYSIS_ANSWER_MAX_LINES)
      require 'composable_agents'

      Debug.debug("Creating analysis agent #{name} (#{analysis_provider}/#{analysis_model})")
      analysis_agent_class.new(
        name:,
        role:,
        objective:,
        system_instructions: instructions,
        constraints: 'This is a read-only analysis: never modify, create or delete any file. ' \
                     "Your whole answer must be shorter than #{max_lines} lines: " \
                     'no preamble, no conclusion, just the requested content.',
        provider: analysis_provider,
        model: analysis_model,
        logger: analysis_logger,
        composable_agents_dir: File.join(directory, 'analysis'),
        artifacts_errors_max_retries: ANALYSIS_AGENT_MAX_RETRIES,
        input_artifacts_contracts: input_artifacts,
        output_artifacts_contracts: output_artifacts
      )
    end

    # Returns the ComposableAgents class used for the analyses.
    #
    # ComposableAgents::Cline::Agent does not include the ArtifactContract,
    # Retriable and RetriableArtifacts mixins by itself (they must be added by
    # the user), so the artifacts contracts given to #cline_agent would
    # otherwise be rejected as unknown keywords, and a run whose answer misses
    # or breaks the expected output artifact would not be retried.
    #
    # The mixins are prepended in the order required by
    # ComposableAgents::Mixins::RetriableArtifacts: RetriableArtifacts first
    # (it registers the retry-on-missing-artifacts policy), then Retriable
    # (which wraps #run with the retry loop), then ArtifactContract (which
    # validates the artifacts and feeds the retry policy).
    #
    # @return [Class] The agent class to instantiate.
    def analysis_agent_class
      @analysis_agent_class ||= Class.new(ComposableAgents::Cline::Agent) do
        prepend ComposableAgents::Mixins::ArtifactContract
        prepend ComposableAgents::Mixins::Retriable
        prepend ComposableAgents::Mixins::RetriableArtifacts
      end
    end

    # @return [String] The provider of the analysis agents.
    def analysis_provider
      ENV.fetch('ANALYSIS_PROVIDER', DEFAULT_ANALYSIS_PROVIDER)
    end

    # @return [String] The model of the analysis agents.
    def analysis_model
      ENV.fetch('ANALYSIS_MODEL', DEFAULT_ANALYSIS_MODEL)
    end

    # Returns the logger shared by the analysis agents.
    #
    # Writes to +runs/<run_id>/analysis.log+ (at DEBUG level when --debug is
    # used), so the agents' traces never pollute the CLI's stdout.
    #
    # @return [ComposableAgents::Logger] The agents' logger.
    def analysis_logger
      @analysis_logger ||= begin
        require 'composable_agents'

        logger = ComposableAgents::Logger.new(File.join(directory, ANALYSIS_LOG_FILE))
        logger.level = Debug.enabled? ? ::Logger::DEBUG : ::Logger::INFO
        logger
      end
    end

    # Returns the working directory given to the analysis agents.
    #
    # @return [String] The absolute path of the agents' working directory.
    def analysis_workdir
      @analysis_workdir ||= begin
        path = File.join(directory, 'analysis', ANALYSIS_WORKDIR)
        FileUtils.mkdir_p(path)
        path
      end
    end

    # Runs a block with the analysis agents' working directory as cwd.
    #
    # The Cline CLI creates files in its working directory (its Node PTY
    # dependencies: +node_modules/+, +package.json+...), and an agent's own
    # file tools write relative to it too. Running the agents from a dedicated
    # directory inside the run folder keeps the project repository clean; the
    # agents still receive the run directory as an absolute path when they need
    # to read it (see #run_summary_prompt).
    #
    # The analyzer is single-threaded, so changing the process working
    # directory for the duration of a run is safe here.
    #
    # @yield The agent run to perform.
    # @return [Object] The block's return value.
    def with_analysis_workdir
      Dir.chdir(analysis_workdir) { yield }
    end

    # Renders the failure of one analysis section.
    #
    # A failing agent (missing +CLINE_API_KEY+, no network, missing output
    # artifact...) must not prevent the deterministic part of the report from
    # being written: its section states the failure instead.
    #
    # @param name [String] The name of the failing analysis.
    # @param error [StandardError] The error raised by the agent.
    #
    # @return [String] The Markdown content of the failed section.
    def analysis_failure(name, error)
      message = error.message.to_s
      Debug.debug("Analysis '#{name}' failed: #{error.class}: #{message}")
      Debug.debug(error.backtrace.first(20).join("\n")) if error.backtrace
      summary = "#{error.class}: #{summarize_message(message)}"
      warn "Could not generate the #{name} analysis: #{summary}"
      "_Analysis could not be generated: #{summary}_"
    end

    # Condenses an error message onto a single, readable line.
    #
    # Agent errors (notably cline-rb's UnexpectedExitStatusError) embed the
    # whole command line, which makes a report section unreadable. Both the
    # beginning (error class context) and the end (exit status) of the message
    # carry information, so a long message is shortened in its middle.
    #
    # @param message [String] The raw error message.
    #
    # @return [String] The condensed message.
    def summarize_message(message)
      condensed = message.gsub(/\s+/, ' ').strip
      return condensed if condensed.length <= ANALYSIS_FAILURE_MAX_LENGTH

      half = ANALYSIS_FAILURE_MAX_LENGTH / 2
      "#{condensed[0, half]} [...] #{condensed[-half..]}"
    end

    # Returns the prompt of the run summary agent.
    #
    # @return [String] The prompt, pointing at this run's directory.
    def run_summary_prompt
      format(RUN_SUMMARY_PROMPT, run_directory: directory)
    end

    # Analyzes the production code of the run with a Cline agent.
    #
    # @return [String] The Markdown analysis of the +lib/+ changes.
    def production_analysis
      @production_analysis ||= cline_analysis(
        name: 'ProductionCodeAnalyst',
        role: "You are a senior Ruby developer reviewing a contribution to the #{github_repository} repository.",
        objective: 'Assess whether the production code of a benchmark run implements the task properly, ' \
                   'and whether it is well written and designed, following the repository conventions.',
        instructions: <<~INSTRUCTIONS,
          Analyze the production code modifications of the run, given the `task` and `diff` artifacts.
          The `diff` artifact only contains the changes made under `./lib` (the production code).

          Summarize quickly, in a few bullet points:
          - Does the code implement the requirements of the task properly and completely?
          - Is it well written and designed (naming, structure, error handling, idiomatic Ruby)?
          - Does it follow the repository conventions visible in the diff and in the surrounding code?
          - Any bug, missing edge case or unintended behavior worth flagging?

          Finish with a one-line verdict on the production code.
          Do not exceed #{ANALYSIS_ANSWER_MAX_LINES} lines in your whole answer, and do not add any preamble or conclusion.
        INSTRUCTIONS
        diff: filtered_diff(prefixes: ['lib/']),
        empty_message: 'No production code (`./lib`) was modified by this run.'
      )
    end

    # Analyzes the tests of the run with a Cline agent.
    #
    # @return [String] The Markdown analysis of the +spec/+ changes.
    def tests_analysis
      @tests_analysis ||= cline_analysis(
        name: 'TestsAnalyst',
        role: "You are a senior Ruby developer reviewing the tests of a contribution to the #{github_repository} repository.",
        objective: 'Assess whether the tests added by a benchmark run cover the new feature properly, ' \
                   'including corner cases, and whether they are well written and designed, following the repository conventions.',
        instructions: <<~INSTRUCTIONS,
          Analyze the tests of the run, given the `task` and `diff` artifacts.
          The `diff` artifact contains the changes made under `./lib` (the tested production code) and `./spec` (the tests).

          Summarize quickly, in a few bullet points:
          - Do the tests cover the new feature properly, including corner cases and failure modes?
          - Are they well written and designed (structure, naming, clarity), following the repository conventions?
          - Do they really exercise the production code, rather than restating its implementation?
          - Which corner cases or behaviors are left untested?

          Finish with a one-line verdict on the tests.
          Do not exceed #{ANALYSIS_ANSWER_MAX_LINES} lines in your whole answer, and do not add any preamble or conclusion.
        INSTRUCTIONS
        diff: filtered_diff(prefixes: %w[lib/ spec/]),
        empty_message: 'No tests (`./spec`) were modified by this run.'
      )
    end

    # Analyzes the documentation of the run with a Cline agent.
    #
    # @return [String] The Markdown analysis of the README.md changes.
    def documentation_analysis
      @documentation_analysis ||= cline_analysis(
        name: 'DocumentationAnalyst',
        role: "You are a senior Ruby developer reviewing the documentation of a contribution to the #{github_repository} repository.",
        objective: 'Assess whether the documentation added by a benchmark run reflects the feature properly, ' \
                   'at the right place, and whether it is well written, following the repository conventions.',
        instructions: <<~INSTRUCTIONS,
          Analyze the documentation of the run, given the `task` and `diff` artifacts.
          The `diff` artifact contains the changes made under `./lib` (the documented production code) and `README.md` (the documentation).

          Summarize quickly, in a few bullet points:
          - Does the documentation describe the new feature properly, at the right place in the document?
          - Is it well written and consistent with the existing documentation style and conventions?
          - Is anything missing (usage, parameters, examples) or outdated in the modified documentation?

          Finish with a one-line verdict on the documentation.
          Do not exceed #{ANALYSIS_ANSWER_MAX_LINES} lines in your whole answer, and do not add any preamble or conclusion.
        INSTRUCTIONS
        diff: filtered_diff(prefixes: ['lib/'], files: ['README.md']),
        empty_message: 'No documentation (`README.md`) was modified by this run.'
      )
    end

    # Summarizes the whole run with a Cline agent.
    #
    # The agent reads the run directory itself (Harbor logs, agent session
    # messages and metrics) following #run_summary_prompt. Its answer is
    # limited to SUMMARY_ANSWER_MAX_LINES (60) lines, as it needs more room
    # than the per-code analyses.
    #
    # @return [String] The Markdown summary of the run.
    def run_summary
      @run_summary ||= begin
        Debug.debug("Running the run summary agent on #{directory}")
        agent = cline_agent(
          name: 'RunSummarizer',
          role: 'You are a meticulous reviewer of AI coding agents, analyzing how they performed on a real software engineering task.',
          objective: 'Summarize chronologically what an AI agent did during a benchmark run, explain the root cause ' \
                     'of any failure, and surface the improvements and recurring patterns that would make it more efficient.',
          instructions: run_summary_prompt,
          max_lines: SUMMARY_ANSWER_MAX_LINES,
          input_artifacts: {
            user_instructions: {
              description: 'The user request for this summary',
              optional: true
            }
          },
          output_artifacts: {
            SUMMARY_OUTPUT_ARTIFACT => {
              description: 'The chronological summary of the agent run, with improvement opportunities and recurring patterns, ' \
                           "shorter than #{SUMMARY_ANSWER_MAX_LINES} lines",
              type: :markdown
            }
          }
        )
        with_analysis_workdir do
          agent.run(user_instructions: 'Write the summary of the run now.').fetch(SUMMARY_OUTPUT_ARTIFACT)
        end
      rescue StandardError => e
        analysis_failure('run summary', e)
      end
    end

    # Runs a Cline agent to analyze part of the run's diff.
    #
    # @param name [String] The agent name (used in logs).
    # @param role [String] The agent's role.
    # @param objective [String] The agent's objective.
    # @param instructions [String] The agent's system instructions.
    # @param diff [String] The part of the run diff to analyze.
    # @param empty_message [String] The content used when there is no diff.
    #
    # @return [String] The Markdown analysis (nested one level below the
    #   report's section headers).
    def cline_analysis(name:, role:, objective:, instructions:, diff:, empty_message:)
      return empty_message if diff.strip.empty?

      Debug.debug("Running the #{name} analysis on #{diff.bytesize} bytes of diff")
      agent = cline_agent(
        name:,
        role:,
        objective:,
        instructions:,
        input_artifacts: {
          user_instructions: {
            description: 'The user request for this analysis',
            optional: true
          },
          task: {
            description: "The GitHub issue the agent had to implement: #{issue_title}",
            type: :markdown
          },
          diff: {
            description: 'The unified git diff of the code to analyze',
            type: :text
          }
        },
        output_artifacts: {
          ANALYSIS_OUTPUT_ARTIFACT => {
            description: "A Markdown analysis shorter than #{ANALYSIS_ANSWER_MAX_LINES} lines, ending with a one-line verdict",
            type: :markdown
          }
        }
      )
      analysis = with_analysis_workdir do
        agent.run(user_instructions: 'Give your analysis now.', task: task_description, diff:).fetch(ANALYSIS_OUTPUT_ARTIFACT)
      end
      ComposableAgents::Utils::Markdown.align_markdown_headers(analysis, level: 3)
    rescue StandardError => e
      analysis_failure(name, e)
    end

    # Builds the Markdown report content.
    #
    # @return [String] The report, covering the task, the agent, the
    #   verifier-observed results, the analyses of the production code, the
    #   tests and the documentation, and the summary of the run.
    def analysis_content
      <<~MARKDOWN
        # Task

        ## Github source repository

        - Repository slug: #{github_repository}
        - Commit ref: #{commit_ref}

        ## Issue description

        #{issue_title}

        #{issue_description}

        # Agent

        - Name: #{agent_name}
        - Model: #{agent_model}

        # Results

        ## Overview - #{passed? ? '✅' : '❌'}

        - #{branch_pushed? ? '✅' : '❌'} Branch pushed on the Github repository
        - #{pr_created? ? '✅' : '❌'} Pull Request created on the Github repository
        - #{production_changed? ? '✅' : '❌'} Production code modified
        - #{tests_changed? ? '✅' : '❌'} Tests modified
        - #{documentation_changed? ? '✅' : '❌'} Documentation modified
        - #{tests_passing? ? '✅' : '❌'} Tests passing 100%
        - #{feature_working? ? '✅' : '❌'} Feature working

        ## Production code analysis

        #{production_analysis}

        ## Tests analysis

        #{tests_analysis}

        ## Documentation analysis

        #{documentation_analysis}

        # Summary of the agent run

        #{run_summary}

      MARKDOWN
    end
  end
end
