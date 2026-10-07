require 'thor'
require 'tty-table'

module AgenticDevBench
  # Command-line interface for agentic-dev-bench.
  #
  # The CLI is built on Thor (http://whatisthor.com/) and provides two
  # commands for managing and executing benchmark scenarios.
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
  #   $ bundle exec bin/agentic-dev-bench execute scenarios/add-greeting.yml
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
  #   $ bundle exec bin/agentic-dev-bench execute scenarios/add-greeting.yml --keep
  #
  # == Example
  #
  #   CLI.new.start(ARGV)
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
      Dir['scenarios/*.yml'].sort.each do |path|
        scenario = Scenario.new(path)
        puts "#{scenario.id}\t#{scenario.name}"
      end
    end

    # Runs a benchmark scenario.
    #
    # Loads the scenario, executes it via +AgenticDevBench::Run+, and
    # displays the results in a table. Also prints the run directory path.
    #
    # @param path [String] The path to the scenario YAML file (e.g.
    #   +scenarios/add-greeting.yml+ or the full path to a .yml file).
    #
    # @option options [Boolean] :keep (false)
    #   When +true+, preserves the GitHub sandbox after the run
    #   completes for debugging purposes.
    #
    # @example Basic execution
    #   $ bundle exec bin/agentic-dev-bench execute scenarios/add-greeting.yml
    #
    desc 'execute SCENARIO', 'Executes a benchmark scenario.'
    option :keep, type: :boolean, default: false, desc: 'Preserves the GitHub sandbox after the run for debugging purposes.'
    # @example Keep the sandbox
    #   $ bundle exec bin/agentic-dev-bench execute scenarios/add-greeting.yml --keep
    def execute(path)
      scenario = Scenario.new(path)
      run_id, result = AgenticDevBench::Run.new(scenario).execute!(keep: options[:keep])
      puts TTY::Table.new(
        header: %w[Metric Value],
        rows: result.map { |key, value| [key, value] }
      )
      puts "Run: runs/#{run_id}"
    end
  end
end
