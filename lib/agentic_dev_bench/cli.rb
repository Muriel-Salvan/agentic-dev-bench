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
  #   +-----------+---------------------------+
  #   | Metric    | Value                     |
  #   +-----------+---------------------------+
  #   | exit_code | 0                         |
  #   | success   | true                      |
  #   | ...       | ...                       |
  #   +-----------+---------------------------+
  #   --- git diff --stat ---
  #   Branch: origin/feature/add-greeting-helper (1 commit(s) ahead)
  #   lib/cline/config.rb | 7 +++++++
  #    1 file changed, 7 insertions(+)
  #   Full patch: runs/20261007T120000Z-3f9a2b1c/results/git_diff.patch
  #   Run: runs/20261007T120000Z-3f9a2b1c
  #
  # Scalar metrics (exit code, branch, commit/file counts) render in the
  # table; the multi-line diff --stat prints verbatim below it, and the
  # full unified diff is saved to results/git_diff.patch.
  #
  # With the +--keep+ option, the GitHub sandbox is preserved after the run:
  #
  #   $ bundle exec bin/agentic-dev-bench execute add-greeting --keep
  #
  class CLI < Thor
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
    end
  end
end
