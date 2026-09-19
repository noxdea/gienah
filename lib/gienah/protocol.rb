# frozen_string_literal: true

module Gienah
  module Protocol
    MAX_MESSAGE = 4 * 1024 * 1024
    MAX_HEADER = 16 * 1024
    module_function

    def frame(message, max_size: MAX_MESSAGE)
      validate_message(message)
      body = JSON.generate(message).b
      raise ProtocolError, "message exceeds #{max_size} bytes" unless body.bytesize.between?(1, max_size)

      "Content-Length: #{body.bytesize}\r\n\r\n".b + body
    rescue JSON::GeneratorError => error
      raise ProtocolError, "invalid JSON: #{error.message}"
    end

    def read(io, max_size: MAX_MESSAGE)
      headers = {}
      bytes = 0
      loop do
        line = io.gets("\r\n", MAX_HEADER + 1)
        return nil if line.nil? && headers.empty?
        raise ProtocolError, "truncated header" unless line&.end_with?("\r\n")
        raise ProtocolError, "oversized header" if line.bytesize > MAX_HEADER
        break if line == "\r\n"

        bytes += line.bytesize
        raise ProtocolError, "oversized headers" if bytes > MAX_HEADER
        raise ProtocolError, "non-ASCII header" unless line.ascii_only?

        key, value = line.delete_suffix("\r\n").split(":", 2)
        raise ProtocolError, "invalid header" unless key&.match?(/\A[A-Za-z][A-Za-z0-9-]*\z/) && value
        key = key.downcase
        raise ProtocolError, "duplicate header" if headers.key?(key)
        headers[key] = value.strip
      end

      raw_length = headers["content-length"]
      raise ProtocolError, "missing or invalid Content-Length" unless raw_length&.match?(/\A\d+\z/)
      length = Integer(raw_length, 10)
      raise ProtocolError, "message exceeds #{max_size} bytes" unless length.between?(1, max_size)
      body = read_exact(io, length)
      raise ProtocolError, "truncated body" unless body&.bytesize == length
      body.force_encoding(Encoding::UTF_8)
      raise ProtocolError, "invalid UTF-8 body" unless body.valid_encoding?
      validate_message(JSON.parse(body))
    rescue JSON::ParserError => error
      raise ProtocolError, "invalid JSON: #{error.message}"
    end

    def validate_message(message)
      raise ProtocolError, "message must be an object" unless message.is_a?(Hash)
      version = message["jsonrpc"] || message[:jsonrpc]
      raise ProtocolError, "jsonrpc must be \"2.0\"" unless version == "2.0"
      method = message["method"] || message[:method]
      id_present = message.key?("id") || message.key?(:id)
      has_result = message.key?("result") || message.key?(:result)
      has_error = message.key?("error") || message.key?(:error)
      raise ProtocolError, "method must be a nonempty String" if method && (!method.is_a?(String) || method.empty?)
      if method
        raise ProtocolError, "request cannot contain result or error" if has_result || has_error
        params = message["params"] || message[:params]
        raise ProtocolError, "params must be an object or array" if params && !params.is_a?(Hash) && !params.is_a?(Array)
      elsif id_present
        id = message["id"] || message[:id]
        raise ProtocolError, "invalid response id" unless id.is_a?(Integer) || id.is_a?(String)
        raise ProtocolError, "response must contain exactly one result or error" unless has_result ^ has_error
        error = message["error"] || message[:error]
        raise ProtocolError, "invalid response error" if has_error && (!error.is_a?(Hash) || !error["message"].is_a?(String))
      else
        raise ProtocolError, "message must contain method or id"
      end
      message
    end

    def request(id, method, params = {})
      {"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    end

    def notification(method, params = {})
      {"jsonrpc" => "2.0", "method" => method, "params" => params}
    end

    def response(id, result: nil, error: nil)
      raise ArgumentError, "result and error are exclusive" if !error.nil? && !result.nil?
      value = {"jsonrpc" => "2.0", "id" => id}
      error.nil? ? value["result"] = result : value["error"] = error
      value
    end

    def read_exact(io, size)
      data = +"".b
      while data.bytesize < size
        chunk = io.read(size - data.bytesize)
        return nil if chunk.nil? || chunk.empty?
        data << chunk
      end
      data
    end
    private_class_method :read_exact
  end
end
