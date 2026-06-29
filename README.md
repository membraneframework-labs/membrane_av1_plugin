# Membrane AV1 Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_av1_plugin.svg)](https://hex.pm/packages/membrane_av1_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_av1_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_av1_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_av1_plugin)

This plugin provides a `Membrane.AV1.Encoder` element based on SVT-AV1 encoder library and a `Membrane.AV1.Decoder`
based on dav1d decoder library.

It's a part of the [Membrane Framework](https://membrane.stream).

## Installation

The package can be installed by adding `membrane_av1_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_av1_plugin, "~> 0.2.0"}
  ]
end
```

## Copyright and License

Copyright 2026, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_av1_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_av1_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
