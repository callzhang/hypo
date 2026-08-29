namespace Hypo.Core.Protocol;

/// <summary>The top-level protocol message. Protocol section 2.1.</summary>
public sealed record SyncEnvelope
{
    public const string CurrentVersion = "1.0";

    public required Guid Id { get; init; }

    public required DateTimeOffset Timestamp { get; init; }

    public string Version { get; init; } = CurrentVersion;

    public required MessageType Type { get; init; }

    public required EnvelopePayload Payload { get; init; }
}
