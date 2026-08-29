using System.Buffers.Binary;
using System.Text.Json;

namespace Hypo.Core.Protocol;

public enum TransportFrameError
{
    PayloadTooLarge,
    Truncated,
}

public sealed class TransportFrameException(TransportFrameError error, string message)
    : Exception(message)
{
    public TransportFrameError Error { get; } = error;
}

/// <summary>
/// Length-prefixed framing for the LAN transport: a 4-byte big-endian body
/// length followed by the JSON-encoded envelope.
/// </summary>
public sealed class TransportFrameCodec
{
    /// <summary>Matches SizeConstants.maxTransportPayloadBytes on macOS.</summary>
    public const int DefaultMaxPayloadBytes = 20 * 1024 * 1024;

    private const int LengthPrefixBytes = 4;

    private readonly int _maxPayloadBytes;

    public TransportFrameCodec(int maxPayloadBytes = DefaultMaxPayloadBytes)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxPayloadBytes);
        _maxPayloadBytes = maxPayloadBytes;
    }

    public byte[] Encode(SyncEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);

        var body = JsonSerializer.SerializeToUtf8Bytes(envelope, ProtocolJson.Options);
        if (body.Length > _maxPayloadBytes)
        {
            throw new TransportFrameException(
                TransportFrameError.PayloadTooLarge,
                $"Encoded envelope is {body.Length} bytes, exceeding the {_maxPayloadBytes} byte ceiling.");
        }

        var frame = new byte[LengthPrefixBytes + body.Length];
        BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(0, LengthPrefixBytes), (uint)body.Length);
        body.CopyTo(frame.AsSpan(LengthPrefixBytes));
        return frame;
    }

    public SyncEnvelope Decode(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < LengthPrefixBytes)
        {
            throw new TransportFrameException(
                TransportFrameError.Truncated,
                $"Frame is {frame.Length} bytes, shorter than the {LengthPrefixBytes} byte length prefix.");
        }

        var declaredLength = BinaryPrimitives.ReadUInt32BigEndian(frame[..LengthPrefixBytes]);
        if (declaredLength > _maxPayloadBytes)
        {
            throw new TransportFrameException(
                TransportFrameError.PayloadTooLarge,
                $"Frame declares {declaredLength} bytes, exceeding the {_maxPayloadBytes} byte ceiling.");
        }

        var body = frame[LengthPrefixBytes..];
        if (body.Length < declaredLength)
        {
            throw new TransportFrameException(
                TransportFrameError.Truncated,
                $"Frame declares {declaredLength} body bytes but carries {body.Length}.");
        }

        return JsonSerializer.Deserialize<SyncEnvelope>(body[..(int)declaredLength], ProtocolJson.Options)
               ?? throw new TransportFrameException(
                   TransportFrameError.Truncated,
                   "Frame body deserialised to null.");
    }
}
