using System.Text.Json.Serialization;

namespace Hypo.Core.Relay;

/// <summary>
/// What the relay sends back when it cannot deliver a message — most often
/// because the target device is not connected.
///
/// <para>This is why inbound relay traffic cannot be decoded straight into a
/// <c>SyncEnvelope</c>: an error's payload carries no ciphertext and no
/// encryption block, both of which that type requires. The first offline peer
/// would throw.</para>
///
/// <para><b>The envelope reuses the id of the message you sent.</b> Its
/// top-level <c>id</c> equals <see cref="OriginalMessageId"/> rather than being
/// freshly generated. That makes correlation trivial and dedup treacherous: a
/// cache keyed on envelope id alone will either mistake this for a message it
/// has already handled, or record the id and then suppress a genuine inbound
/// message that happens to carry it.</para>
/// </summary>
public sealed record RelayError
{
    /// <summary>Machine-readable code; "device_not_connected" is the one seen in practice.</summary>
    public required string Code { get; init; }

    public string? Message { get; init; }

    public string? TargetDeviceId { get; init; }

    /// <summary>The id of the message that could not be delivered.</summary>
    public Guid? OriginalMessageId { get; init; }

    /// <summary>Every device the relay currently has a session for. Useful when diagnosing.</summary>
    public IReadOnlyList<string> ConnectedDevices { get; init; } = [];
}

public sealed class RelayErrorReceivedEventArgs(RelayError error) : EventArgs
{
    public RelayError Error { get; } = error;
}
