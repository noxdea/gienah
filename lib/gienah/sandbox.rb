# frozen_string_literal: true

module Gienah
  module Sandbox
    module_function

    DANGEROUS = /\A(?:fs\.write:|net:|exec\z|process\.exec\z)/

    def dangerous?(capabilities)
      Array(capabilities).any? { |capability| capability.match?(DANGEROUS) }
    end

    def policy_for(capabilities, root:)
      require "saiph"
      root = File.expand_path(root.to_s)
      reads = []
      writes = []
      network = false
      exec = false
      Array(capabilities).each do |capability|
        case capability
        when /\Afs\.read:(.+)/
          reads << path_for(Regexp.last_match(1), root)
        when /\Afs\.write:(.+)/
          writes << path_for(Regexp.last_match(1), root)
        when /\Anet:/
          network = true
        when "exec", "process.exec"
          exec = true
        end
      end
      Saiph::Policy.new((reads + [root]).uniq, writes.uniq, network, exec, ENV.keys)
    end

    def available?
      require "saiph"
      Saiph.available?
    rescue LoadError, StandardError
      false
    end

    def ensure_safe!(capabilities)
      raise Error, "OS sandbox is unavailable for dangerous capabilities" if dangerous?(capabilities) && !available?
    end

    def path_for(pattern, root)
      pattern = pattern.sub("${workspaceFolder}", root)
      return root if pattern.include?("*") && !pattern.start_with?("/")

      path = pattern.start_with?("/") ? pattern : File.join(root, pattern)
      wildcard = path.index(/[*?\[]/)
      File.expand_path(wildcard ? path[0...wildcard].sub(%r{[/\\]\z}, "") : path)
    end
    private_class_method :path_for
  end
end
