# NervesHubLinkAVM

A [NervesHub](https://www.nerves-hub.org/) client for [AtomVM](https://www.atomvm.net/) devices.

NervesHubLinkAVM connects AtomVM-powered microcontrollers (ESP32, etc.) to a NervesHub server for over-the-air (OTA) firmware updates via WebSocket.

## Features

- WebSocket connection to NervesHub with Phoenix channel protocol (v2.0.0)
- Mutual TLS (mTLS) device authentication with client certificates
- OTA firmware updates with streaming download and SHA256 verification
- Update lifecycle status reporting (received, downloading, updating, complete, failed)
- Firmware validation tracking across reboots
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
  device_handler: MyApp.DeviceHandler
)
```

Required firmware metadata keys: `uuid`, `product`, `architecture`, `version`, `platform`. The client validates these at startup and raises if any are missing.

An optional `:name` can be passed to run multiple instances.

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

### Implementing a device handler

Create a module that implements the `NervesHubLinkAVM.DeviceHandler` behaviour:

```elixir
defmodule MyApp.DeviceHandler do
  @behaviour NervesHubLinkAVM.DeviceHandler

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
  def handle_finish(state) do
    # Called after SHA256 verification passes. Activate firmware slot, reboot.
    :ok
  end

  @impl true
  def handle_abort(state) do
    # Called on error or SHA256 mismatch. Clean up partial writes.
    :ok
  end

  # Optional callbacks:

  @impl true
  def handle_confirm do
    # Called via confirm_update/0. Commit firmware on first boot.
    :ok
  end

  @impl true
  def handle_identify do
    # Called when the server requests device identification.
    # Blink an LED, beep, etc.
    :ok
  end
end
```

### Update lifecycle

When the server pushes a firmware update, the client:

1. Reports `"received"` status to the server
2. Calls `handle_begin/2` with the firmware size and metadata
3. Reports `"downloading"` and streams chunks through `handle_chunk/2`
4. Verifies SHA256 hash of the downloaded firmware
5. Reports `"updating"` and calls `handle_finish/1`
6. Reports `"fwup_complete"` on success

If SHA256 verification fails or any step errors, `handle_abort/1` is called and `"update_failed"` is reported.

### Channel messages handled

| Server Event | Client Action |
|---|---|
| `update` | Starts firmware download pipeline |
| `reboot` | Sends `"rebooting"` acknowledgment |
| `identify` | Calls `handle_identify/0` if implemented |

## Architecture

```
NervesHubLinkAVM (GenServer)
  |
  |-- Channel          JSON encode/decode for Phoenix channel protocol
  |-- HTTPClient       Firmware download via AtomVM's ahttp_client
  |-- DeviceHandler    Behaviour for device callbacks
  |
  +-- websocket.erl   WebSocket client (TCP + TLS) with RFC 6455 framing
```

## Author

Eliel A. Gordon (gordoneliel@gmail.com)

## License

MIT
