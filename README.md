# NervesHubLinkAVM

[![Hex.pm](https://img.shields.io/hexpm/v/nerves_hub_link_avm.svg)](https://hex.pm/packages/nerves_hub_link_avm)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/nerves_hub_link_avm)

A [NervesHub](https://www.nerves-hub.org/) client for [AtomVM](https://www.atomvm.net/) devices.

NervesHubLinkAVM connects AtomVM-powered microcontrollers (ESP32, etc.) to a NervesHub server for over-the-air (OTA) firmware updates via WebSocket.

## Features

- WebSocket connection to NervesHub with Phoenix channel protocol (v2.0.0)
- Mutual TLS (mTLS) or shared secret (HMAC) authentication
- OTA firmware updates with streaming download and SHA256 verification
- Pluggable firmware writer for different hardware platforms
- Update lifecycle status reporting (received, downloading, updating, complete, failed)
- Update decision control (apply, ignore, reschedule)
- Firmware validation tracking across reboots
- Pluggable extension system (health reporting, etc.)
- Device identification support (e.g., blink LED on server request)
- Automatic reconnection with exponential backoff
- Heartbeat keep-alive
- Nameable GenServer (supports multiple instances)
- Zero external dependencies -- uses AtomVM's built-in modules

## Requirements

- AtomVM with OTP 28 support (with TLS/Mbed TLS for `wss://`)
- Elixir ~> 1.15 (for compilation)

## Installation

Add `nerves_hub_link_avm` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:nerves_hub_link_avm, "~> 0.1.0"}
  ]
end
```

## Usage

### Starting the client

```elixir
NervesHubLinkAVM.start_link(
  host: "your-nerveshub-server.com",
  port: 443,
  ssl: true,
  device_cert: "/path/to/device-cert.pem",
  device_key: "/path/to/device-key.pem",
  firmware_meta: %{
    "uuid" => "firmware-uuid",
    "product" => "my-product",
    "architecture" => "esp32",
    "version" => "1.0.0",
    "platform" => "esp32"
  },
  client: MyApp.Client,
  fwup_writer: MyApp.ESP32Writer
)
```

Or with shared secret authentication:

```elixir
NervesHubLinkAVM.start_link(
  host: "your-nerveshub-server.com",
  product_key: "nhp_...",
  product_secret: "...",
  identifier: "my-device-001",
  firmware_meta: %{ ... },
  client: MyApp.Client,
  fwup_writer: MyApp.ESP32Writer
)
```

Required firmware metadata keys: `uuid`, `product`, `architecture`, `version`, `platform`.

### Public API

```elixir
# Force a reconnection (resets backoff)
NervesHubLinkAVM.reconnect()

# Confirm firmware is valid after an update (prevents rollback)
NervesHubLinkAVM.confirm_update()

# With a named instance
NervesHubLinkAVM.reconnect(MyDevice)
NervesHubLinkAVM.confirm_update(MyDevice)
```

### Client behaviour

The `Client` controls update decisions, progress reporting, and device actions. All callbacks are optional with sensible defaults (auto-apply updates, no-op for everything else).

```elixir
defmodule MyApp.Client do
  @behaviour NervesHubLinkAVM.Client

  @impl true
  def update_available(_meta), do: :apply  # or :ignore or {:reschedule, 60_000}

  @impl true
  def fwup_progress(percent), do: IO.puts("Progress: #{percent}%")

  @impl true
  def fwup_error(error), do: IO.puts("Error: #{inspect(error)}")

  @impl true
  def reboot, do: :ok

  @impl true
  def identify, do: :ok

  @impl true
  def handle_connected, do: :ok

  @impl true
  def handle_disconnected, do: :ok
end
```

A default implementation (`NervesHubLinkAVM.Client.Default`) is used if no `:client` is provided.

### FwupWriter behaviour

The `FwupWriter` handles hardware-specific firmware write operations. Implement this for your target platform.

```elixir
defmodule MyApp.ESP32Writer do
  @behaviour NervesHubLinkAVM.FwupWriter

  @impl true
  def fwup_begin(size, _meta) do
    # Erase inactive partition, allocate buffers
    {:ok, %{offset: 0, size: size}}
  end

  @impl true
  def fwup_chunk(data, state) do
    # Write chunk to flash
    {:ok, %{state | offset: state.offset + byte_size(data)}}
  end

  @impl true
  def fwup_finish(_state) do
    # Activate new slot, reboot
    :ok
  end

  @impl true
  def fwup_abort(_state) do
    # Clean up partial writes
    :ok
  end

  # Optional: confirm firmware on first boot
  @impl true
  def fwup_confirm, do: :ok
end
```

### Extensions

Extensions are opt-in and pluggable. Currently supported: health reporting.

```elixir
NervesHubLinkAVM.start_link(
  ...
  extensions: [health: MyApp.HealthProvider]
)
```

Implement the `HealthProvider` behaviour:

```elixir
defmodule MyApp.HealthProvider do
  @behaviour NervesHubLinkAVM.HealthProvider

  @impl true
  def health_check do
    %{"cpu_temp" => 42.5, "mem_used_percent" => 65}
  end
end
```

Custom extensions can implement the `NervesHubLinkAVM.Extension` behaviour directly.

### Update lifecycle

When the server pushes a firmware update:

1. `Client.update_available/1` is called -- returns `:apply`, `:ignore`, or `{:reschedule, ms}`
2. If `:apply`, calls `FwupWriter.fwup_begin/2`
3. Reports `"downloading"` and streams chunks through `FwupWriter.fwup_chunk/2`
4. Verifies SHA256 hash of the downloaded firmware
5. Reports `"updating"` and calls `FwupWriter.fwup_finish/1`
6. Reports `"fwup_complete"` on success

If SHA256 verification fails or any step errors, `FwupWriter.fwup_abort/1` is called and `"update_failed"` is reported.

### Channel messages handled

| Server Event | Client Action |
|---|---|
| `update` | Runs update pipeline via UpdateManager |
| `reboot` | Calls `Client.reboot/0` |
| `identify` | Calls `Client.identify/0` |
| `extensions:get` | Joins extensions channel if configured |
| `health:check` | Calls `HealthProvider.health_check/0` |

## Architecture

```
NervesHubLinkAVM (GenServer)    -- connection lifecycle, message dispatch
  |
  |-- Client (behaviour)        -- update decisions, progress, lifecycle hooks
  |   +-- Client.Default        -- auto-apply, log everything
  |
  |-- FwupWriter (behaviour)    -- hardware-specific firmware writes
  |
  |-- Configurator              -- builds config from opts (auth, URL, SSL)
  |-- UpdateManager             -- orchestrates Client + FwupWriter + Downloader
  |-- Downloader                -- HTTP streaming + SHA256 verification
  |
  |-- Extension (behaviour)     -- pluggable extension interface
  |   +-- Extension.Health      -- wraps HealthProvider for health reporting
  |-- Extensions                -- routes extension events by key prefix
  |
  |-- SharedSecret              -- HMAC signing for shared secret auth
  |-- Channel                   -- Phoenix channel protocol codec
  |-- HTTPClient                -- HTTP layer (AtomVM ahttp_client)
  |-- JSON                      -- JSON codec (AtomVM compatible)
  |
  +-- websocket.erl             -- WebSocket client (TCP + TLS) RFC 6455
```

## Author

Eliel A. Gordon (gordoneliel@gmail.com)

## License

MIT
