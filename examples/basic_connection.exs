# Basic ESP32 connection with mTLS certificate authentication.
#
# The device certificate and key must be registered with the NervesHub server.
# See the NervesHub documentation for creating device certificates.

NervesHubLinkAVM.start_link(
  host: "your-nerveshub-server.com",
  port: 443,
  ssl: true,
  device_cert: "/path/to/device-cert.pem",
  device_key: "/path/to/device-key.pem",
  firmware_meta: %{
    "uuid" => "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "product" => "my-product",
    "architecture" => "esp32",
    "version" => "1.0.0",
    "platform" => "esp32"
  },
  fwup_writer: MyApp.ESP32Writer
)
