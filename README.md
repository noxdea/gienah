<h1 align="center">Gienah</h1>

<p align="center">
  <strong>Run Ruby plugins outside your host process.</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/gienah"><img src="https://img.shields.io/gem/v/gienah?style=flat-square" alt="Gem version"></a>
  <a href="https://rubygems.org/gems/gienah"><img src="https://img.shields.io/gem/dt/gienah?style=flat-square" alt="Gem downloads"></a>
  <a href="https://github.com/noxdea/gienah/actions/workflows/main.yml"><img src="https://github.com/noxdea/gienah/actions/workflows/main.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Ruby-%3E%3D%203.1-CC342D?style=flat-square" alt="Ruby 3.1 or newer">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://noxdea.github.io/gienah/">Website</a> ·
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#capability-gates">Capability gates</a> ·
  <a href="#development">Development</a>
</p>

---

Gienah is a small, Canopus-independent plugin host for Ruby applications. It
launches each plugin in a separate Ruby process and communicates over
Content-Length-framed JSON-RPC 2.0, keeping plugin failures and permissions
outside the application core.

The name comes from Gienah (γ Corvi), the IAU-approved star name derived from
Arabic *al-janāḥ* — “the wing”.

## Features

- **Process isolation** — plugins run outside the host process.
- **Capability gates** — host methods are denied unless the plugin declares the required capability.
- **Lifecycle management** — activation events, graceful shutdown, bounded restart attempts, and crash disabling.
- **Bounded RPC** — startup and request deadlines, cancellation, and message-size limits.
- **Portable manifests** — recursive discovery of `plugin.json` and `plugin.jsonc` files.
- **Small plugin SDK** — export methods, handle events, and call back into the host.
- **OS sandbox policies** — dangerous filesystem, network, and process capabilities are delegated to [Saiph](https://github.com/noxdea/saiph).

## Installation

Add Gienah to your bundle:

```bash
bundle add gienah
```

Or install it directly:

```bash
gem install gienah
```

Gienah requires Ruby 3.1 or newer. When an OS sandbox is unavailable, plugins
requesting write, network, or process-execution capabilities fail closed before
startup.

## Quick start

Create a plugin manifest at `plugins/hello/plugin.json`:

```json
{
  "id": "hello",
  "name": "Hello",
  "version": "1.0.0",
  "api_version": 1,
  "entry": "main.rb",
  "activation": ["onStartup"],
  "capabilities": []
}
```

Add the plugin entrypoint at `plugins/hello/main.rb`:

```ruby
require "gienah"

Gienah::Plugin.export("greet") do |params|
  {"message" => "Hello, #{params.fetch("name")}!"}
end

Gienah::Plugin.run
```

Discover and activate it from the host:

```ruby
require "gienah"

host = Gienah::Host.new(api_version: 1)

begin
  host.discover("plugins")
  plugin = host.activate("hello", reason: "onStartup")
  result = plugin.call("greet", {"name" => "Ruby"}).await
  puts result.fetch("message")
ensure
  host.shutdown
end
```

```text
Hello, Ruby!
```

## Capability gates

The host decides which application methods a plugin may call:

```ruby
host.expose("workspace/name", capability: "workspace.read") do
  {"name" => "my-project"}
end
```

The call is accepted only when the plugin manifest declares `workspace.read`.
Unknown capabilities are rejected while loading the manifest.

| Capability form | Scope |
|---|---|
| `buffer.read`, `workspace.read`, `ui.command` | Built-in host capabilities |
| `fs.read:<path>`, `fs.write:<path>` | Filesystem paths or globs |
| `net:<host-pattern>` | Network hosts |
| `process.exec`, `exec` | Process execution |

## Lifecycle

1. `Host#discover` loads manifests and their contributions.
2. `Host#activate` starts a plugin only when its activation reason matches.
3. Host and plugin exchange an initialization handshake with the API version and granted capabilities.
4. Calls return a `Gienah::Future`; deadlines and cancellation keep requests bounded.
5. Failed plugins restart with bounded backoff and are disabled after repeated crashes.

Call `Host#shutdown` to stop every active plugin cleanly.

## Development

```bash
bundle install
bundle exec rake
```

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/noxdea/gienah).

## License

Gienah is available under the [MIT License](LICENSE.txt).
