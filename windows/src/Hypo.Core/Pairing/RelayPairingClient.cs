using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hypo.Core.Pairing;

/// <summary>A code the user reads out, and when it stops working.</summary>
public sealed record PairingCode(string Code, DateTimeOffset ExpiresAt);

/// <summary>Who is on the other end of a claimed code.</summary>
public sealed record ClaimedCode(
    string PeerDeviceId,
    string PeerDeviceName,
    byte[] PeerPublicKey,
    DateTimeOffset ExpiresAt);

/// <summary>
/// The relay's six-digit pairing code endpoints.
///
/// <para><b>The relay's role names are the reverse of ours, and this is worth
/// reading twice.</b> Its "initiator" is whoever asked for a code; its
/// "responder" is whoever typed it in. But the one who <em>types the code</em>
/// is the one who sends a challenge, which is
/// <see cref="PairingSession.StartInitiator"/> in this codebase, and the one who
/// <em>generated the code</em> answers it, which is
/// <see cref="PairingSession.StartResponder"/>. Wiring these the way the names
/// suggest produces a handshake that fails signature verification for reasons
/// that look cryptographic and are not.</para>
///
/// <para>The endpoints live under <c>/pairing</c>, not <c>/api/pairing</c>;
/// the latter returns 404 with no hint that a prefix is the problem.</para>
/// </summary>
public sealed class RelayPairingClient(HttpClient http, Uri? relayBase = null)
{
    private readonly HttpClient _http = http ?? throw new ArgumentNullException(nameof(http));

    private readonly Uri _base = relayBase ?? new Uri("https://hypo.fly.dev/");

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>Asks for a code to read out. This side answers the challenge.</summary>
    public async Task<PairingCode> CreateCodeAsync(
        string deviceId, string deviceName, byte[] publicKey, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceId);
        ArgumentNullException.ThrowIfNull(publicKey);

        var response = await PostAsync(
            "pairing/code",
            new
            {
                initiator_device_id = deviceId,
                initiator_device_name = deviceName,
                initiator_public_key = Convert.ToBase64String(publicKey),
            },
            ct).ConfigureAwait(false);

        var body = await Read<CreateCodeBody>(response, ct).ConfigureAwait(false);

        return new PairingCode(body.Code, body.ExpiresAt);
    }

    /// <summary>Claims a code someone read out. This side sends the challenge.</summary>
    public async Task<ClaimedCode> ClaimCodeAsync(
        string code, string deviceId, string deviceName, byte[] publicKey, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(code);

        var response = await PostAsync(
            "pairing/claim",
            new
            {
                code,
                responder_device_id = deviceId,
                responder_device_name = deviceName,
                responder_public_key = Convert.ToBase64String(publicKey),
            },
            ct).ConfigureAwait(false);

        var body = await Read<ClaimBody>(response, ct).ConfigureAwait(false);

        return new ClaimedCode(
            body.InitiatorDeviceId,
            body.InitiatorDeviceName,
            Convert.FromBase64String(body.InitiatorPublicKey),
            body.ExpiresAt);
    }

    public async Task SubmitChallengeAsync(
        string code, string deviceId, string challengeJson, CancellationToken ct = default) =>
        await PostAsync(
            $"pairing/code/{code}/challenge",
            new { responder_device_id = deviceId, challenge = challengeJson },
            ct).ConfigureAwait(false);

    public async Task SubmitAckAsync(
        string code, string deviceId, string ackJson, CancellationToken ct = default) =>
        await PostAsync(
            $"pairing/code/{code}/ack",
            new { initiator_device_id = deviceId, ack = ackJson },
            ct).ConfigureAwait(false);

    /// <summary>
    /// The challenge, once the other side has posted one. Null while it has not.
    /// </summary>
    /// <remarks>
    /// The device id goes in the query string, not the body: the polls take
    /// query parameters while the posts take JSON, which is not symmetrical and
    /// is not guessable from the post shapes.
    /// </remarks>
    public Task<string?> PollChallengeAsync(string code, string deviceId, CancellationToken ct = default) =>
        PollAsync<ChallengeBody>(
            $"pairing/code/{code}/challenge?initiator_device_id={Uri.EscapeDataString(deviceId)}",
            body => body.Challenge,
            ct);

    /// <summary>The acknowledgement, once the other side has posted one.</summary>
    public Task<string?> PollAckAsync(string code, string deviceId, CancellationToken ct = default) =>
        PollAsync<AckBody>(
            $"pairing/code/{code}/ack?responder_device_id={Uri.EscapeDataString(deviceId)}",
            body => body.Ack,
            ct);

    private async Task<string?> PollAsync<T>(string path, Func<T, string> select, CancellationToken ct)
    {
        using var response = await _http.GetAsync(new Uri(_base, path), ct).ConfigureAwait(false);

        // Not-yet-posted is the normal case while polling, not a failure.
        if (response.StatusCode is System.Net.HttpStatusCode.NotFound
            or System.Net.HttpStatusCode.NoContent)
        {
            return null;
        }

        await Ensure(response, ct).ConfigureAwait(false);

        var body = await response.Content.ReadFromJsonAsync<T>(Json, ct).ConfigureAwait(false);
        var value = body is null ? null : select(body);

        // An empty string is the relay's other way of saying "nothing yet",
        // which is not the same as a missing body.
        return string.IsNullOrEmpty(value) ? null : value;
    }

    private async Task<HttpResponseMessage> PostAsync(string path, object payload, CancellationToken ct)
    {
        var response = await _http
            .PostAsJsonAsync(new Uri(_base, path), payload, Json, ct)
            .ConfigureAwait(false);

        await Ensure(response, ct).ConfigureAwait(false);
        return response;
    }

    private static async Task Ensure(HttpResponseMessage response, CancellationToken ct)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        // The body carries the reason -- an expired code, an unknown one -- and
        // a bare status line would leave the user guessing which.
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);

        throw new PairingRelayException(
            $"The relay answered {(int)response.StatusCode} {response.StatusCode}"
            + (string.IsNullOrWhiteSpace(body) ? "." : $": {body.Trim()}"));
    }

    private static async Task<T> Read<T>(HttpResponseMessage response, CancellationToken ct) =>
        await response.Content.ReadFromJsonAsync<T>(Json, ct).ConfigureAwait(false)
        ?? throw new PairingRelayException("The relay returned an empty body.");

    private sealed record CreateCodeBody(
        [property: JsonPropertyName("code")] string Code,
        [property: JsonPropertyName("expires_at")] DateTimeOffset ExpiresAt);

    private sealed record ClaimBody(
        [property: JsonPropertyName("initiator_device_id")] string InitiatorDeviceId,
        [property: JsonPropertyName("initiator_device_name")] string InitiatorDeviceName,
        [property: JsonPropertyName("initiator_public_key")] string InitiatorPublicKey,
        [property: JsonPropertyName("expires_at")] DateTimeOffset ExpiresAt);

    private sealed record ChallengeBody([property: JsonPropertyName("challenge")] string Challenge);

    private sealed record AckBody([property: JsonPropertyName("ack")] string Ack);
}

/// <summary>The relay refused or could not answer a pairing request.</summary>
public sealed class PairingRelayException(string message) : Exception(message);
