# Connection with device logging enabled.
#
# Add `logging: true` to `extensions`, then wire AtomVM's built-in
# `:logger` through `NervesHubLinkAVM.LoggerHandler` to send normal
# `:logger.info/1`, `:logger.warning/1`, etc. to the NervesHub Logs tab.

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
  client: MyApp.Client,
  fwup_writer: MyApp.ESP32Writer,
  extensions: [
    logging: true
  ]
)

:logger_manager.start_link(%{
  log_level: :info,
  logger: [
    {:handler, :default, :logger_std_h, %{}},
    {:handler, :nerveshub, NervesHubLinkAVM.LoggerHandler,
     %{config: %{server: NervesHubLinkAVM}}}
  ]
})

:logger.info(~c"boot complete")
:logger.warning(~c"wifi signal is low")

# Explicit log forwarding is still available when you want to bypass :logger.
NervesHubLinkAVM.log(:error, "battery critically low")
