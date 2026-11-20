require 'thor'
require 'tty-table'

module AgenticDevBench
  # Command-line interface for agentic-dev-bench.
  #
  # == Commands
  #
  # === list
  #
  # Lists all available scenario files in the +scenarios/+ directory.
  #
  #   $ bundle exec bin/agentic-dev-bench list
  #   add-greeting	Add greeting helper
  #
  # Each line shows the scenario ID and name, separated by a tab.
  #
  # === execute SCENARIO
  #
  # Executes a benchmark scenario.
  #
  #   $ bundle exec bin/agentic-dev-bench execute add-greeting
  #   +-----------------+---------------------------+
  #   | Metric          | Value                     |
  #   +-----------------+---------------------------+
  #   | exit_code       | 0                         |
  #   | success         | true                      |
  #   | verifier_reward | 1.0                       |
  #   | verifier_passed | true                      |
  #   | ...             | ...                       |
  #   +-----------------+---------------------------+
  #   --- git diff --stat ---
  #   Branch: origin/feature/add-greeting-helper (1 commit(s) ahead)
  #   lib/cline/config.rb | 7 +++++++
  #    1 file changed, 7 insertions(+)
  #   Full patch: runs/20261007T120000Z-3f9a2b1c/results/git_diff.patch
  #   Run: runs/20261007T120000Z-3f9a2b1c
  #   Overall: PASS (all metrics successful)
  #
  # Scalar metrics (exit code, success, verifier_reward, verifier_passed,
  # agent/verifier exceptions, branch, commit/file counts) render in the table; the
  # multi-line diff --stat prints verbatim below it, and the full unified
  # diff is saved to results/git_diff.patch. Note that +success+ only
  # reflects the Harbor CLI process; +verifier_passed+ is the verifier's
  # actual verdict (they can differ when the CLI exits 0 despite a failing
  # trial).
  #
  # The final +Overall:+ line is the global success status: every
  # success-relevant metric is validated against +SUCCESS_PREDICATES+.
  # When all checks pass the command prints +Overall: PASS+ and exits 0;
  # otherwise it prints +Overall: FAIL+ listing the failing metrics,
  # repeats them on stderr via +Thor::Error+, and exits 1 (see
  # +Cli.exit_on_failure?+).
  #
  # With the +--keep+ option, the GitHub sandbox is preserved after the run:
  #
  #   $ bundle exec bin/agentic-dev-bench execute add-greeting --keep
  #
  # === list-runs
  #
  # Lists all available run IDs, one per line. Each sub-folder of +runs/+ is
  # one benchmark run and its folder name is the run ID accepted by
  # +analyze-run+. IDs are sorted, so the most recent run is printed last.
  # When no run exists yet, a hint is printed on stderr and nothing is
  # written to stdout (keeping the output safe to pipe).
  #
  #   $ bundle exec bin/agentic-dev-bench list-runs
  #   202610141540011-greeting-cline-ok
  #   202610160855161-greeting-xaa-ok
  #   202611131127241-interactive-xaa-ok
  #   202611131237301-interactive-cline-ko
  #
  # === analyze-run RUN_ID
  #
  # Analyzes a completed run and writes a human-readable report to
  # +runs/RUN_ID/analysis.md+.
  #
  #   $ bundle exec bin/agentic-dev-bench analyze-run 202611131237301-interactive-cline-ko
  #   Result: FAILURE
  #   Analysis written: runs/202611131237301-interactive-cline-ko/analysis.md
  #
  # The report is deliberately minimal for now: it reads
  # +results/result.yml+ and states whether the verifier passed. The verdict
  # analyzed is +verifier_passed+ (the verifier's actual grade), not
  # +success+ (which only reflects the Harbor CLI exit code) — see the
  # +execute+ section above and AgenticDevBench::Metrics.
  #
  # The command prints the verdict and the path of the generated file, and
  # raises +Thor::Error+ (exit status 1, see +Cli.exit_on_failure?+) when the
  # run does not exist or its +results/result.yml+ is missing or unparsable.
  # Use +--debug+ to trace which files are read and written.
  #
  class Cli < Thor
    # Exits with status 1 when a command raises +Thor::Error+.
    #
    # +Thor::Base.start+ rescues +Thor::Error+, prints the message on
    # stderr, and only calls <tt>exit(false)</tt> when this returns
    # +true+ (the Thor default prints the error, emits a deprecation
    # warning, and still exits 0). This makes both the unknown-scenario
    # error and a failed global status (see +#report_overall_status!+)
    # end the process with a non-zero status.
    #
    # @return [Boolean] Always +true+.
    def self.exit_on_failure?
      true
    end

    # Success criteria for the global status printed at the end of
    # +execute+ (see +#report_overall_status!+). The status is strict: it
    # is successful only when the verifier passes completely and neither
    # the agent nor the verifier phase raised an exception (a passing
    # grade with an agent crash — e.g. a failed PR-creation step after a
    # successful push — still fails).
    #
    # Maps every scalar metric that has a notion of "successful" (as
    # produced by +Metrics.collect+) to a predicate over its value;
    # +true+ means the metric is successful. Metrics without such a
    # notion are deliberately absent: +elapsed_seconds+ is
    # informational (any duration is valid), while +feature_branches+
    # and +git_diff_stat+ restate +feature_branch+ (+git_diff_stat+
    # is also multi-line and printed separately).
    SUCCESS_PREDICATES = {
      'exit_code' => ->(value) { value == 0 },
      'success' => ->(value) { value == true },
      'verifier_reward' => ->(value) { value.is_a?(Numeric) && value >= 1.0 },
      'verifier_passed' => ->(value) { value == true },
      'agent_exception' => ->(value) { value.nil? },
      'verifier_exception' => ->(value) { value.nil? },
      'feature_branch' => ->(value) { !value.to_s.empty? },
      'commits_ahead' => ->(value) { value.to_i >= 1 },
      'files_changed' => ->(value) { value.to_i >= 1 }
    }.freeze

    # Lists all available scenario files in the +scenarios/+ directory.
    #
    # Iterates over all +.yml+ files in the +scenarios/+ directory,
    # creates a Scenario object for each, and prints the scenario ID
    # and name (tab-separated) to standard output.
    #
    # @example
    #   $ bundle exec bin/agentic-dev-bench list
    #   add-greeting	Add greeting helper
    desc 'list', 'Lists all available scenario files in the +scenarios/+ directory.'
    def list
      Scenario.all.each do |scenario|
        puts "#{scenario.id}\t#{scenario.name}"
      end
    end

    # Runs a benchmark scenario.
    #
    # Loads the scenario, executes it via +AgenticDevBench::Run+, and
    # displays the results in a table. Also prints the run directory path.
    #
    # @param name [String] The scenario name (e.g. +add-greeting+,
    #   resolved to +scenarios/add-greeting.yml+).
    #
    # @option options [Boolean] :keep (false)
    #   When +true+, preserves the GitHub sandbox after the run
    #   completes for debugging purposes.
    #
    # @raise [Thor::Error] When the scenario is unknown or the global
    #   success status fails; +Cli.exit_on_failure?+ turns the error
    #   into exit status 1.
    #
    # @example Basic execution
    #   $ bundle exec bin/agentic-dev-bench execute add-greeting
    #
    desc 'execute SCENARIO', 'Executes a benchmark scenario.'
    option :keep, type: :boolean, default: false, desc: 'Preserves the GitHub sandbox after the run for debugging purposes.'
    option :debug, type: :boolean, default: false, desc: 'Enable debug logging for setup, harbor, git, and docker operations.'
    def execute(name)
      all_scenarios = Scenario.all
      scenario = all_scenarios.find { |s| s.id == name }
      raise Thor::Error, "Scenario '#{name}' not found. Available: #{all_scenarios.map(&:id).join(', ')}" if scenario.nil?

      Debug.set_debug!(options[:debug])
      Debug.debug("Executing scenario #{scenario.id} (#{scenario.name})")
      Debug.debug("Options: keep=#{options[:keep]} debug=#{options[:debug]}")
      run_id, result = Run.new(scenario).execute!(keep: options[:keep])
      # Multi-line values (git_diff_stat) mangle TTY::Table columns, so
      # keep the table to single-line scalars and print the diff verbatim
      # below. Full unified diff lives in runs/<id>/results/git_diff.patch.
      scalar, multiline = result.partition { |key, _| key != 'git_diff_stat' }
      puts TTY::Table.new(
        header: %w[Metric Value],
        rows: scalar.map { |key, value| [key, value] }
      )
      stat = multiline.to_h['git_diff_stat'].to_s
      if stat.empty?
        puts 'git diff: (no pushed feature branch)'
      else
        puts '--- git diff --stat ---'
        puts stat
      end
      puts "Full patch: runs/#{run_id}/results/git_diff.patch"
      puts "Run: runs/#{run_id}"
      report_overall_status!(result)
    end

    # Lists all available run IDs in the +runs/+ directory.
    #
    # Each sub-folder of +runs/+ is one benchmark run (see
    # AgenticDevBench::Run) and its folder name is the run ID accepted by
    # +analyze-run+.
    #
    # @return [void]
    #
    # @example
    #   $ bundle exec bin/agentic-dev-bench list-runs
    #   202610141540011-greeting-cline-ok
    #   202610160855161-greeting-xaa-ok
    desc 'list-runs', 'Lists all available run IDs from the +runs/+ directory.'
    def list_runs
      ids = Run.all_ids
      if ids.empty?
        warn "No runs found in #{Run::RUNS_DIR}/."
      else
        ids.each { |id| puts id }
      end
    end

    # Analyzes a benchmark run and writes a human-readable report.
    #
    # Reads +runs/RUN_ID/results/result.yml+ via
    # AgenticDevBench::RunAnalyzer, checks the +verifier_passed+ verdict, and
    # writes +runs/RUN_ID/analysis.md+, then prints the verdict and the path
    # of the generated report.
    #
    # @param run_id [String] The run ID to analyze (a sub-folder name under
    #   +runs/+, as listed by +list-runs+).
    #
    # @option options [Boolean] :debug (false)
    #   When +true+, enables debug logging (files read and written).
    #
    # @return [void]
    #
    # @raise [Thor::Error] When the run does not exist or its
    #   +results/result.yml+ is missing or unparsable; +Cli.exit_on_failure?+
    #   turns the error into exit status 1.
    #
    # @example
    #   $ bundle exec bin/agentic-dev-bench analyze-run 202610141540011-greeting-cline-ok
    #   Result: SUCCESS
    #   Analysis written: runs/202610141540011-greeting-cline-ok/analysis.md
    desc 'analyze-run RUN_ID', 'Analyzes a run and writes analysis.md into its run folder.'
    option :debug, type: :boolean, default: false, desc: 'Enable debug logging for the analysis.'
    def analyze_run(run_id)
      Debug.set_debug!(options[:debug])
      analyzer = RunAnalyzer.new(run_id)
      analyzer.analyze!
      puts "Result: #{analyzer.passed? ? 'SUCCESS' : 'FAILURE'}"
      puts "Analysis written: #{File.join(Run::RUNS_DIR, run_id, RunAnalyzer::ANALYSIS_FILE)}"
    end

    private

    # Prints the global success status line and enforces it.
    #
    # Evaluates +SUCCESS_PREDICATES+ against the collected metrics. When
    # every check passes, prints <tt>Overall: PASS (all metrics
    # successful)</tt> and returns. Otherwise prints <tt>Overall: FAIL
    # (metrics not successful: ...)</tt> with the failing metric names
    # (their values are already in the table above) and raises
    # +Thor::Error+ carrying the same detail, so Thor prints it on
    # stderr and the process exits 1 (see +Cli.exit_on_failure?+).
    #
    # @param result [Hash<String, Object>] The scalar metrics produced
    #   by +Metrics.collect+ (multi-line +git_diff_stat+ is ignored
    #   here, as in +SUCCESS_PREDICATES+).
    #
    # @return [void]
    #
    # @raise [Thor::Error] When any metric check fails.
    def report_overall_status!(result)
      failed = SUCCESS_PREDICATES.reject { |metric, successful| successful.call(result[metric]) }.keys
      if failed.empty?
        puts 'Overall: PASS (all metrics successful)'
      else
        puts "Overall: FAIL (metrics not successful: #{failed.join(', ')})"
        raise Thor::Error, "Overall status failed: metrics not successful: #{failed.join(', ')}"
      end
    end
  end
end
