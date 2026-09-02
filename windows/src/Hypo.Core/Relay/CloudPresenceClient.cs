using System.Net.Http.Json;
using System.Text.Json.Serialization;

namespace Hypo.Core.Relay;

/// <summary>
/// Asks the relay which of our peers are connected to it right now.
///
/// <para>Plain HTTP, deliberately: presence is a question about other devices, and
/// answering it does not need our own socket to be up. Tying it to the socket is
/// how the Mac spent a day reporting every peer as offline while a missing auth
/// token kept its own connection down.</para>
/// </summary>
public sealed class CloudPresenceClient(HttpClient http, Uri? relayBase = null)
{
    private readonly HttpClient _http = http ?? throw new ArgumentNullException(nameof(http));
    private readonly Uri _base = relayBase ?? new Uri("https://hypo.fly.dev/");

    /// <summary>
    /// The subset of <paramref name="deviceIds"/> the relay currently holds a
    /// connection for. Empty when the question cannot be answered -- a network
    /// failure is not evidence that everyone is offline, but the caller has
    /// nothing better to go on either, so it is reported as "none seen".
    /// </summary>
    public async Task<IReadOnlyCollection<string>> ConnectedAsync(
        IEnumerable<string> deviceIds,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(deviceIds);

        var ids = deviceIds
            .Where(id => !string.IsNullOrWhiteSpace(id))
            .Select(id => id.Trim().ToLowerInvariant())
            .Distinct()
            .ToArray();

        if (ids.Length == 0)
        {
            return [];
        }

        var uri = new Uri(_base, $"peers?device_id={Uri.EscapeDataString(string.Join(",", ids))}");

        try
        {
            var response = await _http.GetAsync(uri, ct).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return [];
            }

            var payload = await response.Content
                .ReadFromJsonAsync<ConnectedPeersResponse>(cancellationToken: ct)
                .ConfigureAwait(false);

            return payload?.ConnectedDevices
                       .Select(device => device.DeviceId.ToLowerInvariant())
                       .ToArray()
                   ?? [];
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            // Unreachable, slow, or answering with something we cannot read. None
            // of those tell us a peer is offline, but they do not tell us it is
            // online either, and the caller only acts on a device coming back.
            return [];
        }
    }

    private sealed record ConnectedPeersResponse
    {
        [JsonPropertyName("connected_devices")]
        public IReadOnlyList<ConnectedDevice> ConnectedDevices { get; init; } = [];
    }

    private sealed record ConnectedDevice
    {
        [JsonPropertyName("device_id")]
        public string DeviceId { get; init; } = string.Empty;
    }
}
