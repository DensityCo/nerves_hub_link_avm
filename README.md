# NervesHubLinkAVM

A [NervesHub](https://www.nerves-hub.org/) client for [AtomVM](https://www.atomvm.net/) devices.

NervesHubLinkAVM connects AtomVM-powered microcontrollers (ESP32, etc.) to a NervesHub server for over-the-air (OTA) firmware updates via WebSocket.

## Features

- WebSocket connection to NervesHub with Phoenix channel protocol
- OTA firmware updates with streaming download and progress reporting
- TLS support for both WebSocket (`wss://`) and HTTP (`https://`) connections
- Automatic reconnection with exponential backoff
- Heartbeat keep-alive
- Zero external dependencies -- uses AtomVM's built-in `ahttp_client`, `ssl`, and `socket` modules

## Requirements

- AtomVM 0.6.x or later (with TLS/Mbed TLS support for `wss://`)
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
  device_cert: device_cert_pem,
  device_key: device_key_pem,
  firmware_meta: %{
    "uuid" => "firmware-uuid",
    "version" => "1.0.0",
    "platform" => "esp32"
  },
  update_handler: MyApp.UpdateHandler
)
```

### Implementing an update handler

Create a module that implements the `NervesHubLinkAVM.UpdateHandler` behaviour:

```elixir
defmodule MyApp.UpdateHandler do
  @behaviour NervesHubLinkAVM.UpdateHandler

  @impl true
  def handle_begin(size, meta) do
    # Called before streaming. Initialize state for the update.
    {:ok, %{size: size, meta: meta}}
  end

  @impl true
  def handle_chunk(data, state) do
    # Called for each downloaded chunk. Write to flash, etc.
    {:ok, state}
  end

  @impl true
  def handle_finish(sha256, state) do
    # Called after all chunks. Verify hash, activate slot, trigger reboot.
    :ok
  end

  @impl true
  def handle_abort(state) do
    # Called on error. Clean up partial writes.
    :ok
  end
end
```

The optional `handle_confirm/0` callback can be implemented to confirm an update on first boot, preventing automatic rollback.

## Architecture

```
NervesHubLinkAVM (GenServer)
  |
  |-- Channel          JSON encode/decode for Phoenix channel protocol
  |-- HTTPClient       Firmware download via AtomVM's ahttp_client
  |-- UpdateHandler    Behaviour for firmware installation callbacks
  |
  +-- websocket.erl   WebSocket client (TCP + TLS) with RFC 6455 framing
```

## Author

Eliel A. Gordon (gordoneliel@gmail.com)

## License

Apache-2.0
