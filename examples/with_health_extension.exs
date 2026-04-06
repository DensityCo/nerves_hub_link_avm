# Connection with health extension enabled.
#
# The server will periodically request health metrics from the device.
# Requires a module implementing the NervesHubLinkAVM.HealthProvider behaviour
# (see health_provider.ex for an example).

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
  firmware_writer: MyApp.ESP32Writer,
  client: MyApp.Client,
  extensions: [
    health: MyApp.HealthProvider
  ]
)
