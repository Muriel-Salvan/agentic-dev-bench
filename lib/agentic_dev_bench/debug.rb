require 'open3'

module AgenticDevBench
  # Central debug-logging helper.
  #
  # The --debug flag is set once via Debug.set_debug!() (called from the CLI)
  # and read via Debug.enabled?. All logging funnels through this
  # module so output has a consistent timestamped format.
  #
  # Subprocess helpers redact embedded credentials (e.g. x-access-token
  # URLs) before logging, and automatically enable each tool's own
  # verbose mode when debug is on:
  # * git: GIT_TRACE=1 + GIT_CURL_VERBOSE=1
  # * docker (via harbor): DOCKER_DEBUG=1 + BUILDKIT_PROGRESS=plain
  # * harbor: logged command + exit status + output tails (no extra flag
  #   injected, since `harbor run` has no stable --debug flag)
  module Debug
    # Matches embedded credentials in URLs (tokens, passwords).
    REDACTED = '[REDACTED]'.freeze

    class << self
      # Enable or disable debug logging.
      #
      # @param value [Boolean] True to enable debug logging.
      def set_debug!(value)
        @debug = !!value
      end

      # Return whether debug logging is enabled.
      #
      # @return [Boolean]
      def enabled?
        !!@debug
      end

      # Log an info-level debug message with a UTC timestamp.
      #
      # @param msg [String] The message to log.
      def debug(msg)
        return unless enabled?

        puts "[DEBUG #{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}] #{msg}"
      end

      # Redact credentials from a string before logging.
      #
      # Strips `x-access-token:...@`, `:password@`, and
      # `?token=...` style secrets.
      #
      # @param str [String] Raw string that may contain secrets.
      # @return [String] Redacted string safe to log.
      def redact(str)
        s = str.to_s.dup
        s.gsub!(%r{(x-access-token:)[^@\s'"]+@}i, '\1' + REDACTED + '@')
        s.gsub!(%r{(://)[^/\s:'"@]+:[^/\s:'"@]+@}i, '\1' + REDACTED + '@')
        s.gsub!(/([?&]token=)[^&\s'"]+/i, '\1' + REDACTED)
        s
      end

      # Env vars that enable git's own trace output when debugging.
      #
      # @return [Hash] Extra env for git child processes.
      def git_debug_env
        return {} unless enabled?

        { 'GIT_TRACE' => '1', 'GIT_CURL_VERBOSE' => '1' }
      end

      # Log a debug message before running a subprocess, then delegate to
      # Open3.capture3 with the same arguments.
      #
      # Accepts either `debug_exec(['git', 'status'])` or
      # `debug_exec('git', 'status')`. An optional leading Hash is treated
      # as env (merged with git trace env for git commands).
      #
      # @param cmd [Array<String>] The command and arguments to run.
      # @param opts [Hash] Options forwarded to Open3.capture3.
      # @return [Array<String, String, Process::Status>] stdout, stderr, status.
      def debug_exec(*cmd, **opts)
        argv = cmd.length == 1 && cmd.first.is_a?(Array) ? cmd.first.dup : cmd.dup
        env = argv.first.is_a?(Hash) ? argv.shift : {}
        # Auto-enable git tracing for git invocations.
        env = git_debug_env.merge(env) if argv.first.to_s == 'git' && enabled?
        debug("Running: #{redact(argv.inspect)}")
        debug("  env: #{redact(env.inspect)}") unless env.empty?
        stdout, stderr, status = Open3.capture3(env, *argv, **opts)
        if enabled?
          debug("  exit=#{status.exitstatus}")
          debug("  stdout tail: #{redact(stdout.to_s.lines.last(5)&.join.to_s.strip)}") unless stdout.to_s.empty?
          debug("  stderr tail: #{redact(stderr.to_s.lines.last(5)&.join.to_s.strip)}") unless stderr.to_s.empty?
        end
        [stdout, stderr, status]
      end

      # Log and run a command via Kernel.system, returning its boolean
      # status. Merges git trace env for git commands when debugging.
      #
      # @param cmd [Array<String>] Command and args.
      # @return [Boolean] True if the command exited successfully.
      def debug_system(*cmd)
        argv = cmd.length == 1 && cmd.first.is_a?(Array) ? cmd.first.dup : cmd.dup
        env = argv.first.is_a?(Hash) ? argv.shift : {}
        env = git_debug_env.merge(env) if argv.first.to_s == 'git' && enabled?
        debug("Running (system): #{redact(argv.inspect)}")
        system(env, *argv, exception: true)
      end
    end
  end
end
