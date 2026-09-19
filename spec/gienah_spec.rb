# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Gienah do
  def manifest(overrides = {})
    Gienah::Manifest.from_hash({
      "id" => "example", "name" => "Example", "version" => "1.0.0", "api_version" => 1,
      "entry" => "lib/example.rb", "activation" => ["onStartup"], "capabilities" => ["buffer.read"],
      "contributes" => {"commands" => []}, "limits" => {}
    }.merge(overrides))
  end

  describe Gienah::Protocol do
    it "frames and reads adjacent messages" do
      first = described_class.frame(described_class.request(1, "one"))
      second = described_class.frame(described_class.notification("two"))
      io = StringIO.new(first + second)
      expect(described_class.read(io)).to eq(JSON.parse(first.split("\r\n\r\n", 2).last))
      expect(described_class.read(io)).to eq(JSON.parse(second.split("\r\n\r\n", 2).last))
    end

    it "rejects truncated and oversized bodies" do
      expect { described_class.read(StringIO.new("Content-Length: 5\r\n\r\n{}")) }.to raise_error(Gienah::ProtocolError)
      message = {"jsonrpc" => "2.0", "id" => 1, "result" => "x" * 10}
      expect { described_class.frame(message, max_size: 4) }.to raise_error(Gienah::ProtocolError)
    end
  end

  describe Gienah::Manifest do
    it "loads JSONC and rejects unknown capabilities" do
      Dir.mktmpdir do |directory|
        path = File.join(directory, "plugin.jsonc")
        File.write(path, <<~JSONC)
          {
            // static metadata
            "id": "example", "name": "Example", "version": "1.0.0", "api_version": 1,
            "entry": "main.rb", "capabilities": ["fs.read:${workspaceFolder}/**",],
          }
        JSONC
        expect(described_class.load(path).root).to eq(directory)
        expect { described_class.from_hash({"id" => "x", "name" => "x", "version" => "1", "api_version" => 1, "entry" => "x", "capabilities" => ["made.up"]}) }
          .to raise_error(Gienah::ProtocolError, /unknown capability/)
      end
    end
  end

  describe Gienah::Host do
    it "activates a fake plugin only for a matching reason" do
      fake = Gienah::Testing::FakePlugin.new.export("echo") { |params| params["value"] }
      host = described_class.new(api_version: 1, sandbox: false,
        transport_factory: ->(manifest, &receive) { fake.transport(manifest, &receive) })
      host.add(manifest)
      expect(host.activate("example", reason: "onCommand:other")).to be_nil
      instance = host.activate("example", reason: "onStartup")
      expect(instance.state).to eq(:ready)
      expect(instance.call("echo", {"value" => 42}).await).to eq(42)
      host.shutdown
    end

    it "denies an exposed method without its capability" do
      fake = Gienah::Testing::FakePlugin.new
      host = described_class.new(api_version: 1, sandbox: false,
        transport_factory: ->(manifest, &receive) { fake.transport(manifest, &receive) })
      host.expose("buffer/text", capability: "buffer.read") { "ok" }
      host.add(manifest("capabilities" => []))
      instance = host.activate("example", reason: "onStartup")
      response = host.dispatch_request(instance, Gienah::Protocol.request(1, "buffer/text"))
      expect(response.fetch("error").fetch("code")).to eq(-32001)
      host.shutdown
    end

    it "round trips with the real plugin SDK" do
      Dir.mktmpdir do |directory|
        File.write(File.join(directory, "main.rb"), <<~RUBY)
          require "gienah"
          Gienah::Plugin.export("echo") { |params| params["value"] }
          Gienah::Plugin.run
        RUBY
        plugin = manifest("entry" => "main.rb")
        plugin = Gienah::Manifest.from_hash(plugin.to_h, root: directory)
        host = described_class.new(api_version: 1, sandbox: false)
        host.add(plugin)
        instance = host.activate("example", reason: "onStartup")
        expect(instance.call("echo", {"value" => "ok"}).await).to eq("ok")
        host.shutdown
      end
    end
  end

  describe Gienah::Future do
    it "supports callbacks and cancellation" do
      cancelled = []
      future = described_class.new(1, on_cancel: ->(id) { cancelled << id })
      values = []
      future.then { |value, error| values << [value, error] }
      future.fulfill("done")
      expect(future.await).to eq("done")
      expect(values).to eq([["done", nil]])
      expect(future.cancel).to be(false)
      expect(cancelled).to be_empty
    end
  end
end
