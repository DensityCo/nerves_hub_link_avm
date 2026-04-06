# Changelog

## v0.1.1

### Fixed

- Add `nerves_fw_` prefix to firmware metadata in join payload (required by NervesHub server)
- `websocket.new/2` now returns `{:ok, pid}` / `{:error, reason}` instead of bare pid
- Add CHANGELOG.md to hex package and docs extras
- Add `.formatter.exs` to hex package files
- Bump Elixir requirement to `~> 1.18` (OTP 28)

### Added

- Hex.pm and hexdocs.pm badges in README
- Hex.pm link in package metadata
- `@moduledoc` documentation for all public modules
- ExDoc dev dependency for hex docs publishing

## v0.1.0

Initial release.

### Features

- WebSocket connection to NervesHub with Phoenix channel protocol (v2.0.0)
- Mutual TLS (mTLS) device authentication with client certificates
- Shared secret (HMAC) authentication with product key/secret
- OTA firmware updates with streaming download and SHA256 verification
- Pluggable `Client` behaviour for update decisions, progress, and lifecycle hooks
- Pluggable `FirmwareWriter` behaviour for hardware-specific firmware writes
- `Client.Default` implementation that auto-applies all updates
- Update lifecycle status reporting (received, downloading, updating, fwup_complete, update_failed)
- Update decision control (apply, ignore, reschedule)
- Firmware validation tracking across reboots (`confirm_update/0`)
- Device identification support (`identify` server event)
- Reboot handling (`reboot` server event)
- Generic extension system with `Extension` behaviour
- Built-in health extension with `HealthProvider` behaviour
- Automatic reconnection with exponential backoff (1s to 30s)
- Heartbeat keep-alive (30s interval)
- Nameable GenServer (supports multiple instances)
- `Configurator` module for runtime config building
- `Downloader` module for HTTP streaming with SHA256 verification
- `UpdateManager` to orchestrate Client + FirmwareWriter + Downloader
- Custom JSON encoder/decoder for AtomVM compatibility
- Custom WebSocket client (RFC 6455) with TCP and TLS support
- Case-insensitive HTTP header parsing for server compatibility
- Zero external dependencies — uses AtomVM's built-in modules

### Architecture

```
NervesHubLinkAVM (GenServer)
├── Client / Client.Default
├── FirmwareWriter
├── Configurator
├── UpdateManager + Downloader
├── Extension / Extension.Health / HealthProvider
├── Extensions (router)
├── SharedSecret
├── Channel / JSON / HTTPClient
└── websocket.erl
```
