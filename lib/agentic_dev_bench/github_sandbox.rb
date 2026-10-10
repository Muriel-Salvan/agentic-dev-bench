require 'git'
require 'octokit'
require 'uri'
require 'cgi'

module AgenticDevBench
  # Manages the creation and destruction of ephemeral GitHub repositories
  # to serve as sandboxed environments for benchmark runs.
  #
  # GitHubSandbox clones a source repository at a specific commit into a
  # new private repository owned by the benchmark user, and creates the
  # corresponding GitHub issue with the requirements.
  #
  # == Environment Variables
  #
  # The following environment variables must be set:
  # * +GITHUB_TOKEN+ - A GitHub personal access token with repository
  #   creation and deletion permissions for the configured owner.
  # * The value of +scenario.sandbox['owner_env']+ - the environment
  #   variable name that resolves to the GitHub owner (user/org) name.
  #
  # == Example
  #
  #   sandbox = AgenticDevBench::GitHubSandbox.new(
  #     scenario: scenario,
  #     run: run
  #   )
  #   info = sandbox.provision!
  #   # => { repository: "...", repository_url: "...", issue_number: 1, ... }
  #   sandbox.destroy!  # clean up the repository
  #
  class GitHubSandbox
    # Initializes a new GitHubSandbox.
    #
    # Loads the GitHub owner from the environment (via +scenario.sandbox['owner_env'])
    # and sets up the Octokit client with the provided token.
    #
    # @param scenario [AgenticDevBench::Scenario] The scenario definition.
    # @param run [AgenticDevBench::Run] The current benchmark run.
    # @param keep [Boolean] When +true+, preserves the temporary clone directory
    #   and the sandbox repository for debugging purposes. Default: +false+.
    def initialize(scenario:, run:, keep: false)
      @scenario = scenario
      @run = run
      @keep = keep
      @owner = ENV.fetch(scenario.sandbox.fetch('owner_env'))
      @token = ENV.fetch('GITHUB_TOKEN')
      @client = Octokit::Client.new(access_token: @token)
      @name = "#{scenario.sandbox.fetch('name_prefix')}-#{scenario.id}-#{run.id}"
    end

    # Provisions an ephemeral GitHub sandbox repository for the benchmark run.
    #
    # This method performs the following steps:
    # 1. Clones the source repository at the specified commit into a temporary directory.
    # 2. Creates a new private repository with a generated name.
    # 3. Pushes the original commit to the new repository (located at +refs/heads/main+).
    # 4. Creates a GitHub issue with the scenario's requirements in the new repository.
    #
    # @return [Hash] A hash containing:
    #   * +repository+ [String] The full name of the created repository (owner/repo).
    #   * +repository_url+ [String] The HTML URL of the created repository.
    #   * +issue_number+ [Integer] The number of the created GitHub issue.
    #   * +issue_url+ [String] The HTML URL of the created issue.
    #   * +original_commit+ [String] The SHA of the commit pushed to the new repository.
    def provision!
      Debug.debug("Creating GitHub repository: #{@name}")

      source = @scenario.source.fetch('repository')
      commit = @scenario.source.fetch('commit')
      repo = @client.create_repository(
        @name,
        description: "Ephemeral sandbox for agentic-dev-bench run #{@run.id}",
        private: true,
        auto_init: false
      )
      Debug.debug("GitHub repository created: #{repo.full_name}")

      original_commit = nil
      dir = Dir.mktmpdir('agentic-dev-bench-source', @run.directory)
      begin
        Debug.debug("Cloning source repository: #{source} to #{dir}")
        git = with_git_trace { Git.clone("https://github.com/#{source}.git", dir) }
        Debug.debug('Source repository cloned successfully')

        Debug.debug("Checking out commit: #{commit}")
        with_git_trace { git.checkout(commit) }
        original_commit = with_git_trace { git.rev_parse('HEAD') }
        Debug.debug("Checked out commit #{original_commit}")

        Debug.debug('Setting git remote URL for push (redacted)')
        with_git_trace { git.remote_set_url('origin', push_url(repo.clone_url)) }
        Debug.debug('Git remote updated')

        Debug.debug('Pushing to origin main')
        with_git_trace { git.push('origin', 'HEAD:refs/heads/main') }
        Debug.debug('Push completed')
      ensure
        if Debug.enabled?
          Debug.debug("Keeping temporary clone directory #{dir}")
        else
          FileUtils.rm_rf(dir)
        end
      end

      Debug.debug("Creating GitHub issue in #{@owner}/#{@name}")
      issue = @client.create_issue("#{@owner}/#{@name}", @scenario.issue.fetch('title'), @scenario.issue.fetch('body'))
      Debug.debug("GitHub issue created: ##{issue.number}")

      {
        'repository' => repo.full_name,
        'repository_url' => repo.html_url,
        'issue_number' => issue.number,
        'issue_url' => issue.html_url,
        'original_commit' => original_commit
      }
    end

    # Converts a GitHub repository clone URL to an authenticated URL.
    #
    # Injects the GitHub token into the URL to allow authenticated git operations
    # (e.g., pushing code) via HTTPS.
    #
    # @param url [String] The clone URL (e.g. https://github.com/owner/repo.git).
    #
    # @return [String] The authenticated URL with the token embedded:
    #   e.g. https://x-access-token:TOKEN@github.com/owner/repo.git
    #
    # @note The token is URL-encoded if it contains special characters.
    def push_url(url)
      uri = URI(url)
      uri.user = 'x-access-token'
      uri.password = CGI.escape(@token)
      uri.to_s
    end

    # Destroys the sandbox repository on GitHub.
    #
    # When +keep+ is +true+, the repository is preserved for debugging
    # and this method is a no-op.
    #
    # @return [nil] Always returns +nil+. If the repository has already
    #   been deleted (HTTP 404), this method silently swallows the error
    #   and returns +nil+.
    #
    # @raise [Octokit::NotFound] Never raised; always rescues +Octokit::NotFound+.
    def destroy!
      if @keep
        Debug.debug("Keeping GitHub repository #{@owner}/#{@name}")
      else
        Debug.debug("Destroying GitHub repository #{@owner}/#{@name}")
        @client.delete_repository("#{@owner}/#{@name}")
        Debug.debug('Sandbox repository destroyed')
      end
    end

    private

    # Runs a ruby-git operation with git's own trace output enabled when
    # debugging, mirroring the previous +Debug.debug_system+ behavior
    # (which merged +Debug.git_debug_env+ into git child processes).
    #
    # The ruby-git gem does not accept a per-call +env+ hash, so the trace
    # variables are temporarily merged into +ENV+ for the duration of the block
    # and restored afterwards (including on exception).
    #
    # @yield The ruby-git operation to run.
    # @return [Object] The block's return value.
    def with_git_trace(&block)
      trace_env = Debug.git_debug_env
      return block.call if trace_env.empty?

      saved = {}
      begin
        trace_env.each do |key, value|
          saved[key] = ENV[key]
          ENV[key] = value
        end
        block.call
      ensure
        saved.each do |key, value|
          if value.nil?
            ENV.delete(key)
          else
            ENV[key] = value
          end
        end
      end
    end

  end
end
