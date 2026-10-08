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
  #   +-----------+--------------------------------+
  #   | Metric    | Value                          |
  #   +-----------+--------------------------------+
  #   | exit_code | 0                              |
  #   | success   | true                           |
  #   | elapsed_seconds | 12.345                   |
  #   | git_diff_stat | +10 -2                    |
  #   +-----------+--------------------------------+
  #   Run: runs/20261007T120000Z-3f9a2b1c
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
      puts TTY::Table.new(
        header: %w[Metric Value],
        rows: result.map { |key, value| [key, value] }
      )
      puts "Run: runs/#{run_id}"
    end
  end
end
