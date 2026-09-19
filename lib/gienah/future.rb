# frozen_string_literal: true

module Gienah
  class Future
    def initialize(id, on_cancel: nil)
      @id = id
      @on_cancel = on_cancel
      @lock = Mutex.new
      @ready = ConditionVariable.new
      @callbacks = []
    end

    attr_reader :id

    def fulfill(value = nil, error: nil)
      callbacks = @lock.synchronize do
        return self if @done
        @value = value
        @error = error
        @done = true
        @ready.broadcast
        callbacks, @callbacks = @callbacks, []
        callbacks
      end
      callbacks.each { |callback| callback.call(@value, @error) }
      self
    end

    def await(timeout: nil)
      validate_timeout(timeout)
      deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      timed_out = false
      result = @lock.synchronize do
        until @done
          remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining && remaining <= 0
            timed_out = true
            break
          end
          @ready.wait(@lock, remaining)
        end
        break if timed_out
        raise @error if @error
        @value
      end
      if timed_out
        cancel
        raise Gienah::Timeout, "request #{@id} timed out"
      end
      result
    end

    def then(&callback)
      raise ArgumentError, "callback required" unless callback
      ready = @lock.synchronize do
        @callbacks << callback unless @done
        @done
      end
      callback.call(@value, @error) if ready
      self
    end

    def cancel
      callback = @lock.synchronize do
        return false if @done || @cancelling
        @cancelling = true
        @on_cancel
      end
      begin
        callback&.call(@id)
      rescue StandardError
        nil
      end
      fulfill(error: Error.new("request #{@id} cancelled"))
      true
    end

    def done?
      @lock.synchronize { !!@done }
    end

    private

    def validate_timeout(timeout)
      return if timeout.nil? || (timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0)
      raise ArgumentError, "timeout must be finite and nonnegative"
    end
  end
end
