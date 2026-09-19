# frozen_string_literal: true

module Gienah
  Manifest = Value.define(:id, :name, :version, :api_version, :entry, :activation,
    :capabilities, :contributes, :limits, :root)

  class Manifest
    REQUIRED = %w[id name version api_version entry].freeze
    EXACT_CAPABILITIES = %w[
      buffer.read buffer.edit workspace.read ui.panel ui.command ui.statusbar
      ui.decoration completion.provide language.define process.exec exec
    ].freeze
    LIMITS = %w[memory_mb request_timeout_ms max_message_bytes max_concurrent_requests startup_timeout_ms].freeze

    class << self
      def load(path)
        path = File.expand_path(path.to_s)
        raise ArgumentError, "manifest does not exist" unless File.file?(path)

        from_hash(JSON.parse(strip_jsonc(File.binread(path))), root: File.dirname(path))
      rescue JSON::ParserError => error
        raise ProtocolError, "invalid manifest JSON: #{error.message}"
      end

      def from_hash(value, root: Dir.pwd)
        raise ProtocolError, "manifest must be an object" unless value.is_a?(Hash)
        value = value.transform_keys(&:to_s)
        REQUIRED.each { |key| raise ProtocolError, "manifest missing #{key}" unless value.key?(key) }
        id = text(value["id"], "id")
        name = text(value["name"], "name")
        version = text(value["version"], "version")
        api_version = positive_integer(value["api_version"], "api_version")
        entry = text(value["entry"], "entry")
        raise ProtocolError, "entry must be relative" if Pathname.new(entry).absolute? || entry.split(File::SEPARATOR).include?("..")

        activation = array(value.fetch("activation", []), "activation").map { |item| text(item, "activation") }
        capabilities = array(value.fetch("capabilities", []), "capabilities").map do |item|
          capability = text(item, "capability")
          validate_capability(capability)
          capability
        end.uniq.freeze
        contributes = value.fetch("contributes", {})
        raise ProtocolError, "contributes must be an object" unless contributes.is_a?(Hash)
        limits = validate_limits(value.fetch("limits", {}))

        new(id, name, version, api_version, entry, activation.freeze, capabilities,
          deep_freeze(contributes), limits, File.expand_path(root.to_s)).freeze
      end

      private

      def text(value, field)
        raise ProtocolError, "#{field} must be a nonempty String" unless value.is_a?(String) && !value.empty? && !value.include?("\0")

        value
      end

      def array(value, field)
        raise ProtocolError, "#{field} must be an Array" unless value.is_a?(Array)

        value
      end

      def positive_integer(value, field)
        raise ProtocolError, "#{field} must be a positive Integer" unless value.is_a?(Integer) && value.positive?

        value
      end

      def validate_capability(value)
        return if EXACT_CAPABILITIES.include?(value)
        return if value.match?(/\A(?:fs\.read|fs\.write|net):.+\z/)

        raise ProtocolError, "unknown capability: #{value}"
      end

      def validate_limits(value)
        raise ProtocolError, "limits must be an object" unless value.is_a?(Hash)

        normalized = value.transform_keys(&:to_s)
        normalized.each do |key, number|
          raise ProtocolError, "unknown limit: #{key}" unless LIMITS.include?(key)
          raise ProtocolError, "#{key} must be positive" unless number.is_a?(Numeric) && number.finite? && number.positive?
        end
        deep_freeze(normalized)
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, item| deep_freeze(key); deep_freeze(item) }
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end

      def strip_jsonc(source)
        output = +""
        quote = false
        escaped = false
        index = 0
        while index < source.length
          char = source[index]
          if quote
            output << char
            if escaped
              escaped = false
            elsif char == "\\"
              escaped = true
            elsif char == '"'
              quote = false
            end
          elsif char == '"'
            quote = true
            output << char
          elsif char == "/" && source[index + 1] == "/"
            index += 2
            index += 1 while index < source.length && source[index] != "\n"
            output << "\n"
          elsif char == "/" && source[index + 1] == "*"
            index += 2
            index += 1 while index + 1 < source.length && source[index, 2] != "*/"
            index += 1
          else
            output << char
          end
          index += 1
        end
        output.gsub(/,\s*([}\]])/, '\1')
      end
    end
  end
end
