using MQTTnet;
using MQTTnet.Client;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

var device = "device1";

var caCert = X509Certificate2.CreateFromCertFile("ca.crt");
var clientCert = new X509Certificate2($"{device}.crt", device);

var mqttClientOptions = new MqttClientOptionsBuilder()
    .WithClientId("device1")
    .WithTlsOptions(
        new MqttClientTlsOptions()
        {
            UseTls = true,
            SslProtocol = System.Security.Authentication.SslProtocols.Tls12
        }
    )
    .WithTcpServer("localhost", 1883)
    .Build();

var mqttClient = new MqttFactory().CreateMqttClient();
await mqttClient.ConnectAsync(mqttClientOptions);

var deviceMetrics = new DeviceMetrics(device, 19.5, 50.0);
var payload = JsonSerializer.Serialize(deviceMetrics);

var message = new MqttApplicationMessageBuilder()
    .WithTopic($"devices/{device}/metrics")
    .WithPayload(payload)
    .Build();

await mqttClient.DisconnectAsync();

record DeviceMetrics(string DeviceId, double Temperature, double Humidity);
