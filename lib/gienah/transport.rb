# frozen_string_literal: true

module Gienah
  class Transport
    attr_reader :pid

    def self.open(command, cwd: nil, env: {}, policy: nil, &receive)
      raise ArgumentError, "receiver required" unless receive
      raise ArgumentError, "command must be a nonempty Array" unless command.is_a?(Array) && !command.empty?

      input_read, input_write = IO.pipe
      output_read, output_write = IO.pipe
      error_read, error_write = IO.pipe
      options = {in: input_read, out: output_write, err: error_write, close_others: true}
      options[:chdir] = cwd if cwd
      pid = if policy
        require "saiph"
        Saiph.spawn(command, policy: policy, **options, env: env)
      else
        Process.spawn(env, *command, **options)
      end
      [input_read, output_write, error_write].each(&:close)
      new(input_write, output_read, error_read, pid, receive)
    rescue Exception
      [input_read, input_write, output_read, output_write, error_read, error_write].compact.each do |io|
        io.close unless io.closed?
      end
      Process.kill("KILL", pid) if pid
      Process.wait(pid) if pid
      raise
    end

    def initialize(input, output, error, pid, receive)
      @input = input
      @output = output
      @error = error
      @pid = pid
      @receive = receive
      @write_lock = Mutex.new
      @closed = false
      @reader = Thread.new { read_loop }
      @reader.report_on_exception = false
      @stderr_reader = Thread.new { drain_stderr }
      @stderr_reader.report_on_exception = false
    end

    def write(message, max_size: Protocol::MAX_MESSAGE)
      frame = Protocol.frame(message, max_size: max_size)
      @write_lock.synchronize do
        raise Error, "transport is closed" if closed?

        @input.write(frame)
        @input.flush
      end
      nil
    rescue IOError, Errno::EPIPE => error
      raise Error, "transport write failed: #{error.message}"
    end

    def alive?
      !closed? && (@pid.nil? || process_alive?)
    end

    def close(grace: 0.5)
      @closed = true
      @input.close unless @input.closed?
      joined = @reader == Thread.current || @reader.join(grace)
      unless joined
        terminate("TERM")
        joined = @reader.join(grace)
      end
      unless joined
        terminate("KILL")
        @reader.join
      end
      @stderr_reader.join(grace) unless @stderr_reader == Thread.current
      [@output, @error].each { |io| io.close unless io.closed? }
      if @pid && process_alive?
        terminate("TERM")
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
        until Process.waitpid(@pid, Process::WNOHANG)
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep(0.01)
        end
        if process_alive?
          terminate("KILL")
          Process.wait(@pid)
        end
      end
      true
    rescue IOError, Errno::ECHILD
      true
    end

    private

    def read_loop
      loop do
        message = Protocol.read(@output)
        break unless message

        @receive.call(message, nil)
      end
      @receive.call(nil, Error.new("transport closed")) unless @closed
    rescue StandardError => error
      @receive.call(nil, error) unless @closed
    ensure
      @closed = true
    end

    def drain_stderr
      while @error.read(8_192)
        break if @closed
      end
    rescue IOError
      nil
    end

    def closed?
      @closed
    end

    def process_alive?
      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH, Errno::ECHILD
      false
    rescue Errno::EPERM
      true
    end

    def terminate(signal)
      Process.kill(signal, @pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
