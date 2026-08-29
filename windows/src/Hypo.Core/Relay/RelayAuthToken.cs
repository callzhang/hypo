using System.Security.Cryptography;
using System.Text;

namespace Hypo.Core.Relay;

/// <summary>
/// The value of the <c>X-Auth-Token</c> header the relay expects on the
/// WebSocket upgrade, alongside <c>X-Device-Id</c> and
/// <c>X-Device-Platform</c>.
///
/// The relay computes HMAC-SHA256 over the device id it has already lowercased
/// (backend/src/handlers/websocket.rs, verify_ws_auth), so we sign the
/// lowercased form too. Signing the id as given would authenticate only when
/// the caller happened to hand us a lowercase id.
/// </summary>
public static class RelayAuthToken
{
    /// <param name="secret">The shared relay secret, RELAY_WS_AUTH_TOKEN.</param>
    /// <param name="deviceId">This device's id, in any case.</param>
    public static string Compute(string secret, string deviceId)
    {
        if (string.IsNullOrEmpty(secret))
        {
            throw new ArgumentException(
                "The relay secret is empty. The relay rejects an empty " +
                "RELAY_WS_AUTH_TOKEN outright, so an empty secret here would " +
                "only surface as an opaque 401 later.",
                nameof(secret));
        }

        if (string.IsNullOrEmpty(deviceId))
        {
            throw new ArgumentException("The device id is empty.", nameof(deviceId));
        }

        var digest = HMACSHA256.HashData(
            Encoding.UTF8.GetBytes(secret),
            Encoding.UTF8.GetBytes(deviceId.ToLowerInvariant()));

        return Convert.ToBase64String(digest);
    }
}
