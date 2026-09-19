# Gienah

Gienah (γ Corvi) is an IAU-approved star name derived from Arabic *al-janāḥ*,
“the wing”. It is a small, Canopus-independent host for out-of-process Ruby
plugins.

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add gienah
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install gienah
```

## Usage

A host registers application-specific methods and activates a manifest only
when its activation reason occurs:

```ruby
require "gienah"

host = Gienah::Host.new(api_version: 1)
host.expose("workspace/notify") { |params| puts params.fetch("message") }
host.discover(["plugins"])
instance = host.activate("example", reason: "onStartup")
instance&.call("refresh", {}).await(timeout: 2)
```

Plugin entrypoints use the SDK:

```ruby
require "gienah"
Gienah::Plugin.export("refresh") { {"ok" => true} }
Gienah::Plugin.run
```

`gienah` treats capabilities as opaque strings, but rejects unknown manifest
capabilities and denies host methods until the declared capability is granted.
Dangerous filesystem, network, and process capabilities require `saiph`.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/noxdea/gienah.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
