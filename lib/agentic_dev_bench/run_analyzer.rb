require 'thor'
require 'yaml'

module AgenticDevBench
  # Analyzes a completed benchmark run and writes a human-readable report.
  #
  # A run stores its collected metrics in +runs/<run_id>/results/result.yml+
  # (see AgenticDevBench::Metrics). RunAnalyzer reads that file, inspects the
  # +verifier_passed+ verdict, and writes a Markdown report to
  # +runs/<run_id>/analysis.md+.
  #
  # The report is deliberately minimal for now: it only states whether the
  # verifier passed. The verdict analyzed is +verifier_passed+, not +success+:
  # +success+ only reflects whether the +harbor run+ CLI process exited 0,
  # while +verifier_passed+ is the verifier's actual grade (see
  # AgenticDevBench::Metrics).
  #
  # == Example
  #
  #   analyzer = AgenticDevBench::RunAnalyzer.new('202610141540011-greeting-cline-ok')
  #   analyzer.analyze!
  #   # => "C:/.../agentic-dev-bench/runs/202610141540011-greeting-cline-ok/analysis.md"
  #   puts analyzer.passed? ? 'Run passed' : 'Run failed'
  #
  class RunAnalyzer
    # Name of the Markdown report written into the run directory.
    ANALYSIS_FILE = 'analysis.md'

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
    # @raise [Thor::Error] When no run directory exists for +run_id+.
    def initialize(run_id)
      @run_id = run_id
      @directory = Run.directory_for(run_id)
      return if File.directory?(@directory)

      available = Run.all_ids
      raise Thor::Error, "Run '#{run_id}' not found. Available: #{available.empty? ? '(none)' : available.join(', ')}"
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
    # @raise [Thor::Error] When +result.yml+ is missing or cannot be parsed.
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
    # Reads +results/result.yml+, checks the +verifier_passed+ verdict, and
    # writes +analysis.md+ into the run directory. Running it twice overwrites
    # the previous report.
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

    # Builds the Markdown report content.
    #
    # @return [String] The report, stating whether the verifier passed.
    def analysis_content
      status = passed? ? 'SUCCESS' : 'FAILURE'
      verdict = passed? ? 'passed' : 'did not pass'
      <<~MARKDOWN
        # Run analysis: #{run_id}

        Result: #{status}

        The verifier #{verdict} for this run (verifier_passed: #{result['verifier_passed'].inspect}).
      MARKDOWN
    end
  end
end
