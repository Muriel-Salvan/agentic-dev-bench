module AgenticDevBench
  # Represents a benchmark scenario loaded from a YAML file.
  #
  # A scenario defines a complete benchmark task including the source
  # repository to clone, the GitHub sandbox configuration, the issue
  # to create, the agent and model to use, and the evaluation criteria.
  #
  # == JSON/YAML File Structure
  #
  # The scenario YAML file must contain the following keys:
  # * +id+ - A unique identifier for the scenario
  # * +name+ - A human-readable name
  # * +source+ - Repository to clone (+repository+, +commit+)
  # * +sandbox+ - GitHub sandbox configuration (+owner_env+, +name_prefix+)
  # * +issue+ - Issue to create (+title+, +body+)
  # * +agent+ - Agent configuration (+name+, +model+)
  # * +evaluation+ - Evaluation criteria and metrics
  #
  # == Example
  #
  #   scenario = AgenticDevBench::Scenario.new('scenarios/add-greeting.yml')
  #   puts scenario.id      # => "add-greeting"
  #   puts scenario.name    # => "Add greeting helper"
  #   puts scenario.source  # => { repository: "...", commit: "..." }
  #
  class Scenario
    # @return [String] The file path this scenario was loaded from.
    attr_reader :path

    # @return [Hash] The parsed YAML content of the scenario file.
    attr_reader :data

    # Initializes a new Scenario from a YAML file.
    #
    # Opens the specified file, expands the path to an absolute path,
    # and parses its contents as YAML.
    #
    # @param path [String] The path to the scenario YAML file.
    def initialize(path)
      @path = File.expand_path(path)
      @data = YAML.load_file(@path)
    end

    # @return [String] The scenario's unique identifier (from +id+ field).
    def id = data.fetch('id')

    # @return [String] The scenario's human-readable name (from +name+ field).
    def name = data.fetch('name')

    # @return [Hash] The source repository configuration (+repository+, +commit+).
    def source = data.fetch('source')

    # @return [Hash] The GitHub sandbox configuration (+owner_env+, +name_prefix+).
    def sandbox = data.fetch('sandbox')

    # @return [Hash] The issue definition (+title+, +body+).
    def issue = data.fetch('issue')

    # @return [Hash] The agent configuration (+name+, +model+).
    def agent = data.fetch('agent')

    # @return [Hash] The evaluation configuration (+command+, +metrics+).
    def evaluation = data.fetch('evaluation')
  end
end
