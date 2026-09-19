# frozen_string_literal: true

module Gienah
  module Testing
    class FakePlugin
      attr_reader :capabilities

      def initialize(capabilities: [])
        @exports = {}
        @notifications = []
        @capabilities = capabilities.map(&:to_s)
      end

      def export(method, &handler)
        @exports[method] = handler
        self
      end

      def on_notification(&handler)
        @notifications << handler
        self
      end

      def transport(manifest, &receive)
        FakeTransport.new(self, manifest, receive)
      end

      def dispatch(message)
        method = message["method"]
        params = message.fetch("params", {})
        case method
        when "initialize"
          @capabilities = Array(params["capabilities"]).map(&:to_s)
          Protocol.response(message["id"], result: {"api_version" => params["api_version"]})
        when "shutdown"
          Protocol.response(message["id"], result: nil)
        else
          handler = @exports[method]
          return Protocol.response(message["id"], error: {"code" => -32601, "message" => "method not found: #{method}"}) unless handler
          result = handler.arity == 1 ? handler.call(params) : handler.call(self, params)
          Protocol.response(message["id"], result: result)
        end
      rescue StandardError => error
        Protocol.response(message["id"], error: {"code" => -32000, "message" => "#{error.class}: #{error.message}"})
      end

      def notify(method, params = {})
        @notifications.each { |handler| handler.call(method, params) }
      end
    end

    class FakeTransport
      attr_reader :pid

      def initialize(plugin, manifest, receive)
        @plugin = plugin
        @manifest = manifest
        @receive = receive
        @pid = Process.pid
        @closed = false
      end

      def write(message, **)
        raise Error, "transport is closed" if @closed
        response = @plugin.dispatch(message)
        @receive.call(response, nil) if response
        nil
      end

      def alive?
        !@closed
      end

      def close(**)
        @closed = true
        true
      end
    end
  end
end
