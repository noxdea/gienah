# frozen_string_literal: true

module Gienah
  module Plugin
    module_function

    def export(name, &handler)
      raise ArgumentError, "name must be a nonempty String" unless name.is_a?(String) && !name.empty?
      raise ArgumentError, "handler required" unless handler

      exports[name] = handler
      nil
    end

    def on(event, &handler)
      raise ArgumentError, "event must be a nonempty String" unless event.is_a?(String) && !event.empty?
      raise ArgumentError, "handler required" unless handler

      listeners[event] << handler
      nil
    end

    def call(method, params = {})
      raise LifecycleError, "plugin is not running" unless running?

      id = next_id
      write(Protocol.request(id, method, params))
      loop do
        message = Protocol.read(@input)
        raise Error, "host closed the connection" unless message
        return response_value(message) if message["id"] == id && !message.key?("method")

        dispatch(message)
      end
    end

    def notify(method, params = {})
      raise LifecycleError, "plugin is not running" unless running?

      write(Protocol.notification(method, params))
      nil
    end

    def capability?(name)
      @capabilities.include?(name.to_s)
    end

    def run(input: $stdin, output: $stdout)
      @input = input
      @output = output
      @input.binmode if @input.respond_to?(:binmode)
      @output.binmode if @output.respond_to?(:binmode)
      @running = true
      loop do
        message = Protocol.read(@input)
        break unless message

        dispatch(message)
        break if @stopped
      end
      nil
    ensure
      @running = false
    end

    def reset!
      @exports = {}
      @listeners = Hash.new { |hash, key| hash[key] = [] }
      @capabilities = []
      @sequence = 0
      @running = false
      nil
    end

    def exports
      @exports ||= {}
    end

    def listeners
      @listeners ||= Hash.new { |hash, key| hash[key] = [] }
    end

    def running?
      !!@running
    end

    def next_id
      @sequence = (@sequence || 0) + 1
    end

    def write(message)
      @output.write(Protocol.frame(message))
      @output.flush
    end

    def dispatch(message)
      if message.key?("method")
        if message.key?("id")
          write(handle_request(message))
        else
          handle_notification(message)
        end
      end
    end

    def handle_request(message)
      method = message["method"]
      params = message.fetch("params", {})
      case method
      when "initialize"
        @capabilities = Array(params["capabilities"]).map(&:to_s).freeze
        Protocol.response(message["id"], result: {"api_version" => params["api_version"]})
      when "shutdown"
        @stopped = true
        Protocol.response(message["id"], result: nil)
      else
        handler = exports[method]
        unless handler
          return Protocol.response(message["id"], error: {"code" => -32601, "message" => "method not found: #{method}"})
        end
        result = handler.arity == 1 ? handler.call(params) : handler.call(self, params)
        Protocol.response(message["id"], result: result)
      end
    rescue StandardError => error
      Protocol.response(message["id"], error: {"code" => -32000, "message" => "#{error.class}: #{error.message}"})
    end

    def handle_notification(message)
      listeners.fetch(message["method"], []).each { |listener| listener.call(message.fetch("params", {})) }
    end

    def response_value(message)
      raise Error, message.fetch("error").fetch("message") if message.key?("error")

      message["result"]
    end

    reset!
  end
end
