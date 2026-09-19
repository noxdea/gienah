# frozen_string_literal: true

module Gienah
  class Host
    Definition = Value.define(:method, :capability, :handler)
    DEFAULT_RESTART = {attempts: 3, window: 60, backoff: [1, 5, 30]}.freeze

    attr_reader :api_version

    def initialize(api_version:, dispatch: nil, sandbox: true, restart: {}, limits: {}, transport_factory: nil)
      raise ArgumentError, "api_version must be positive" unless api_version.is_a?(Integer) && api_version.positive?

      @api_version = api_version
      @dispatch = dispatch
      @sandbox = sandbox
      @restart = restart || {}
      @limits = limits || {}
      @transport_factory = transport_factory
      @manifests = {}
      @instances = {}
      @definitions = {}
      @contribution_handlers = []
      @error_handlers = []
      @lock = Mutex.new
      @restart_history = Hash.new { |hash, key| hash[key] = [] }
      @shutting_down = false
    end

    def expose(method, capability: nil, &handler)
      raise ArgumentError, "method must be a nonempty String" unless method.is_a?(String) && !method.empty?
      raise ArgumentError, "handler required" unless handler
      raise ArgumentError, "capability must be a String" unless capability.nil? || capability.is_a?(String)

      @definitions[method] = Definition.new(method, capability, handler)
      self
    end

    def discover(directories)
      manifests = Array(directories).flat_map do |directory|
        path = File.expand_path(directory.to_s)
        candidates = if File.file?(path)
          [path]
        else
          Dir[File.join(path, "**", "plugin.{json,jsonc}")]
        end
        candidates.sort.map { |manifest| Manifest.load(manifest) }
      end
      manifests.each { |manifest| add(manifest) }
      manifests
    end

    def add(manifest)
      raise ArgumentError, "expected Gienah::Manifest" unless manifest.is_a?(Manifest)
      raise LifecycleError, "unsupported plugin api version #{manifest.api_version}" unless manifest.api_version == @api_version

      @lock.synchronize { @manifests[manifest.id] = manifest }
      @contribution_handlers.each { |handler| handler.call(manifest.id, manifest.contributes) }
      manifest
    end

    def activate(id, reason:)
      manifest = @lock.synchronize { @manifests.fetch(id.to_s) { raise ArgumentError, "unknown plugin: #{id}" } }
      return @instances[id.to_s] if @instances.key?(id.to_s)
      return nil unless activation_matches?(manifest.activation, reason.to_s)

      instance = Instance.new(self, manifest)
      @lock.synchronize { @instances[manifest.id] = instance }
      begin
        instance.start
      rescue StandardError
        @lock.synchronize { @instances.delete(manifest.id) }
        raise
      end
      instance
    end

    def deactivate(id)
      instance = @lock.synchronize { @instances.delete(id.to_s) }
      instance&.shutdown
    end

    def instances
      @lock.synchronize { @instances.values.dup }
    end

    def on_contribution(&block)
      raise ArgumentError, "callback required" unless block

      @contribution_handlers << block
      self
    end

    def on_error(&block)
      raise ArgumentError, "callback required" unless block

      @error_handlers << block
      self
    end

    def shutdown
      @shutting_down = true
      instances.each(&:shutdown)
      @lock.synchronize { @instances.clear }
      nil
    end

    def dispatch_request(instance, message)
      method = message["method"]
      definition = @definitions[method]
      unless definition
        return Protocol.response(message["id"], error: {"code" => -32601, "message" => "method not found: #{method}"})
      end
      if definition.capability && !instance.granted?(definition.capability)
        return Protocol.response(message["id"], error: {"code" => -32001, "message" => "capability denied: #{definition.capability}"})
      end

      params = message.fetch("params", {})
      result = if definition.handler.arity == 1
        definition.handler.call(params)
      else
        definition.handler.call(instance, params)
      end
      Protocol.response(message["id"], result: result)
    rescue CapabilityDenied => error
      Protocol.response(message["id"], error: {"code" => -32001, "message" => error.message})
    rescue StandardError => error
      report_error(error, instance)
      Protocol.response(message["id"], error: {"code" => -32000, "message" => "#{error.class}: #{error.message}"})
    end

    def dispatch_notification(instance, message)
      @dispatch&.call(instance, message["method"], message.fetch("params", {}))
    rescue StandardError => error
      report_error(error, instance)
    end

    def report_error(error, instance = nil)
      @error_handlers.each { |handler| handler.call(error, instance) }
    rescue StandardError
      nil
    end

    def instance_failed(instance, error)
      report_error(error, instance)
      config = DEFAULT_RESTART.merge(@restart.transform_keys(&:to_sym))
      attempts = config.fetch(:attempts).to_i
      return if attempts <= 0 || @shutting_down
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      history = @lock.synchronize do
        next unless @instances[instance.id].equal?(instance)

        @restart_history[instance.id].reject! { |started| now - started >= config.fetch(:window).to_f }
        if @restart_history[instance.id].length < attempts
          @restart_history[instance.id] << now
        else
          nil
        end
      end
      return unless history

      index = history.length - 1
      backoff = Array(config.fetch(:backoff))
      delay = backoff[index] || backoff.last || 0
      Thread.new do
        sleep(delay.to_f) if delay.to_f.positive?
        next unless @lock.synchronize { !@shutting_down && @instances[instance.id].equal?(instance) && instance.state == :failed }

        instance.restart
      rescue StandardError => restart_error
        report_error(restart_error, instance)
      end
    end

    def transport_for(instance, &receive)
      if @transport_factory
        @transport_factory.call(instance.manifest, &receive)
      else
        Sandbox.ensure_safe!(instance.manifest.capabilities) if @sandbox
        entry = File.expand_path(instance.manifest.entry, instance.manifest.root)
        raise Error, "plugin entry does not exist: #{entry}" unless File.file?(entry)
        command = [RbConfig.ruby, "-I", File.expand_path("..", __dir__), entry]
        policy = @sandbox && Sandbox.available? ? Sandbox.policy_for(instance.manifest.capabilities, root: instance.manifest.root) : nil
        Transport.open(command, cwd: instance.manifest.root, env: {}, policy: policy, &receive)
      end
    end

    def request_timeout(manifest)
      value = manifest.limits.fetch("request_timeout_ms", @limits.fetch(:request_timeout_ms, 2_000))
      value.to_f / 1_000
    end

    private

    def activation_matches?(patterns, reason)
      patterns.empty? || patterns.any? do |pattern|
        pattern == reason || (pattern.end_with?("*") && reason.start_with?(pattern.delete_suffix("*")))
      end
    end
  end

  class Instance
    STATES = %i[inactive starting ready stopping failed].freeze

    attr_reader :id, :manifest, :state

    def initialize(host, manifest)
      @host = host
      @manifest = manifest
      @id = manifest.id
      @state = :inactive
      @lock = Mutex.new
      @pending = {}
      @next_id = 0
    end

    def start
      transition(:starting, from: :inactive)
      @transport = @host.transport_for(self) { |message, error| receive(message, error) }
      response = request("initialize", {
        "api_version" => @host.api_version,
        "capabilities" => @manifest.capabilities,
        "host" => {"name" => "gienah", "version" => Gienah::VERSION}
      }).await(timeout: @manifest.limits.fetch("startup_timeout_ms", 5_000).to_f / 1_000)
      raise LifecycleError, "plugin initialization failed" unless response.is_a?(Hash)

      transition(:ready, from: :starting)
      self
    rescue StandardError => error
      @lock.synchronize { @state = :failed }
      @host.report_error(error, self)
      close_transport
      raise
    end

    def call(method, params = {}, timeout: nil)
      ensure_ready!
      request(method, params, timeout: timeout)
    end

    def notify(method, params = {})
      ensure_ready!
      @transport.write(Protocol.notification(method, params), max_size: max_message_size)
      nil
    end

    def granted?(capability)
      @manifest.capabilities.include?(capability.to_s)
    end

    def kill
      @lock.synchronize { @state = :inactive }
      fail_pending(Error.new("plugin terminated"))
      close_transport
      nil
    end

    def restart
      @lock.synchronize { @state = :inactive if @state == :failed }
      start
    end

    def shutdown
      current = @lock.synchronize { @state }
      return if current == :inactive

      if current == :ready
        @lock.synchronize { @state = :stopping }
        begin
          request("shutdown", {}).await(timeout: 0.5)
        rescue StandardError
          nil
        end
      end
      kill
    end

    private

    def request(method, params, timeout: nil)
      id = @lock.synchronize do
        @next_id += 1
        @next_id
      end
      future = Future.new(id, on_cancel: ->(request_id) {
        @transport&.write(Protocol.notification("$/cancel", {"id" => request_id}), max_size: max_message_size)
      })
      @lock.synchronize { @pending[id] = future }
      begin
        @transport.write(Protocol.request(id, method, params), max_size: max_message_size)
      rescue StandardError => error
        @lock.synchronize { @pending.delete(id) }
        future.fulfill(error: error)
      end
      future
    end

    def receive(message, error)
      if error
        @lock.synchronize { @state = :failed unless %i[inactive stopping].include?(@state) }
        fail_pending(error)
        @host.instance_failed(self, error)
        return
      end
      return unless message
      if message.key?("method")
        response = if message.key?("id")
          @host.dispatch_request(self, message)
        else
          @host.dispatch_notification(self, message)
          nil
        end
        @transport.write(response, max_size: max_message_size) if response
      else
        future = @lock.synchronize { @pending.delete(message["id"]) }
        return unless future
        message.key?("error") ? future.fulfill(error: Error.new(message["error"]["message"].to_s)) : future.fulfill(message["result"])
      end
    rescue StandardError => dispatch_error
      @host.report_error(dispatch_error, self)
    end

    def ensure_ready!
      raise LifecycleError, "plugin #{@id} is #{@state}" unless @lock.synchronize { @state == :ready }
    end

    def transition(target, from:)
      @lock.synchronize do
        raise LifecycleError, "cannot transition #{@state} to #{target}" unless @state == from
        @state = target
      end
    end

    def fail_pending(error)
      futures = @lock.synchronize { pending, @pending = @pending.values, {}; pending }
      futures.each { |future| future.fulfill(error: error) }
    end

    def close_transport
      @transport&.close
      @transport = nil
    end

    def max_message_size
      @manifest.limits.fetch("max_message_bytes", Protocol::MAX_MESSAGE)
    end
  end
end
