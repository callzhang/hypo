using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

namespace Hypo.Core.Tests;

/// <summary>
/// The relay's pairing endpoints, in process.
///
/// <para>A stand-in rather than the deployed relay: these tests run two sides of
/// a handshake against each other, and doing that against shared infrastructure
/// would leave codes behind and fail whenever someone else was pairing. The
/// shapes are taken from the real handlers, including the role names, which are
/// the reverse of this codebase's.</para>
/// </summary>
internal sealed class StubRelayPairingServer : HttpMessageHandler
{
    private sealed record Entry
    {
        public required string InitiatorDeviceId { get; init; }
        public required string InitiatorDeviceName { get; init; }
        public required string InitiatorPublicKey { get; init; }
        public required DateTimeOffset ExpiresAt { get; init; }

        public string? Challenge { get; set; }
        public string? Ack { get; set; }
    }

    private readonly ConcurrentDictionary<string, Entry> _codes = new();
    private int _next = 100_000;

    public TimeSpan CodeLifetime { get; set; } = TimeSpan.FromSeconds(60);

    /// <summary>Mangles the challenge, as an impostor answering a code would.</summary>
    public bool CorruptChallenge { get; set; }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken ct)
    {
        var path = request.RequestUri!.AbsolutePath.Trim('/');
        var segments = path.Split('/');

        if (request.Method == HttpMethod.Post && path == "pairing/code")
        {
            var body = await Read(request, ct);
            var code = Interlocked.Increment(ref _next).ToString()[^6..];

            _codes[code] = new Entry
            {
                InitiatorDeviceId = body.GetProperty("initiator_device_id").GetString()!,
                InitiatorDeviceName = body.GetProperty("initiator_device_name").GetString()!,
                InitiatorPublicKey = body.GetProperty("initiator_public_key").GetString()!,
                ExpiresAt = DateTimeOffset.UtcNow + CodeLifetime,
            };

            return Json(new { code, expires_at = _codes[code].ExpiresAt });
        }

        if (request.Method == HttpMethod.Post && path == "pairing/claim")
        {
            var body = await Read(request, ct);
            var code = body.GetProperty("code").GetString()!;

            if (!_codes.TryGetValue(code, out var entry) || entry.ExpiresAt < DateTimeOffset.UtcNow)
            {
                // What a wrong or expired code gets, which is the failure a user
                // is most likely to cause.
                return new HttpResponseMessage(HttpStatusCode.NotFound)
                {
                    Content = new StringContent("no such pairing code"),
                };
            }

            return Json(new
            {
                initiator_device_id = entry.InitiatorDeviceId,
                initiator_device_name = entry.InitiatorDeviceName,
                initiator_public_key = entry.InitiatorPublicKey,
                expires_at = entry.ExpiresAt,
            });
        }

        if (segments is ["pairing", "code", var codeSegment, var kind])
        {
            // The real relay takes the device id as a query parameter on the
            // polls while the posts take JSON. Requiring it here too is what
            // stops this stub from agreeing with a client the relay rejects.
            if (request.Method == HttpMethod.Get)
            {
                var query = System.Web.HttpUtility.ParseQueryString(request.RequestUri!.Query);
                var expected = kind == "challenge" ? "initiator_device_id" : "responder_device_id";

                if (string.IsNullOrEmpty(query[expected]))
                {
                    return new HttpResponseMessage(HttpStatusCode.BadRequest)
                    {
                        Content = new StringContent($"Query deserialize error: missing field `{expected}`"),
                    };
                }
            }
        }

        if (segments is ["pairing", "code", var code2, var kind2])
        {
            if (!_codes.TryGetValue(code2, out var entry))
            {
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            }

            if (request.Method == HttpMethod.Post)
            {
                var body = await Read(request, ct);

                if (kind2 == "challenge")
                {
                    var challenge = body.GetProperty("challenge").GetString()!;
                    entry.Challenge = CorruptChallenge ? Corrupt(challenge) : challenge;
                }
                else
                {
                    entry.Ack = body.GetProperty("ack").GetString();
                }

                return Json(new { ok = true });
            }

            var value = kind2 == "challenge" ? entry.Challenge : entry.Ack;

            // Not-yet-posted is a 404 while polling, which the client has to
            // tell apart from a wrong URL.
            return value is null
                ? new HttpResponseMessage(HttpStatusCode.NotFound)
                : Json(kind2 == "challenge" ? new { challenge = value } : (object)new { ack = value });
        }

        return new HttpResponseMessage(HttpStatusCode.NotFound);
    }

    /// <summary>
    /// Changes one byte of the ciphertext, leaving the shape intact -- an
    /// impostor's answer, not a malformed one.
    /// </summary>
    private static string Corrupt(string challengeJson)
    {
        var node = System.Text.Json.Nodes.JsonNode.Parse(challengeJson)!;
        var ciphertext = Convert.FromBase64String(node["ciphertext"]!.GetValue<string>());
        ciphertext[0] ^= 0xFF;
        node["ciphertext"] = Convert.ToBase64String(ciphertext);

        return node.ToJsonString();
    }

    private static async Task<JsonElement> Read(HttpRequestMessage request, CancellationToken ct) =>
        await request.Content!.ReadFromJsonAsync<JsonElement>(ct);

    private static HttpResponseMessage Json(object body) => new(HttpStatusCode.OK)
    {
        Content = JsonContent.Create(body),
    };
}
