# Connecting with shared secret (HMAC) authentication.
#
# Use this when devices don't have individual certificates.
# The product key and secret are created in the NervesHub web UI
# under your product's settings.

NervesHubLinkAVM.start_link(
  host: "your-nerveshub-server.com",
  port: 443,
  ssl: true,
  product_key: "nhp_your_product_key",
  product_secret: "your_product_secret",
  identifier: "my-device-001",
  firmware_meta: %{
    "uuid" => "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "product" => "my-product",
    "architecture" => "esp32",
    "version" => "1.0.0",
    "platform" => "esp32"
  },
  firmware_writer: MyApp.ESP32Writer
)
