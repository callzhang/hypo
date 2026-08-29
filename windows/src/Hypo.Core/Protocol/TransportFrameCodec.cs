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

    /// <summary>
    /// Whether these leading bytes can begin a length prefix under the ceiling,
    /// which is what tells clipboard traffic from pairing traffic on the binary
    /// channel. The two share opcode 0x2: Android replies to a challenge with
    /// bare JSON via Java-WebSocket's send(byte[]), and has no text-send path.
    /// <para>
    /// The test is exact rather than a heuristic. A body may be at most
    /// <paramref name="maxPayloadBytes"/>, so a big-endian prefix cannot read
    /// higher than that, while JSON opens with '{' — 0x7B — putting any bare
    /// JSON body above 0x7B000000. The two ranges cannot overlap while the
    /// ceiling stays below that, which the 20 MB default does by two orders of
    /// magnitude. Keying on the ceiling rather than on the literal '{' is what
    /// stops the rule and the codec drifting apart.
    /// </para>
    /// </summary>
    /// <returns>
    /// True for anything that could still be a frame, including an empty span:
    /// nothing rules it out, and an empty frame is a harmless no-op to the
    /// reader where an empty pairing message is not.
    /// </returns>
    public static bool LooksLikeLengthPrefix(
        ReadOnlySpan<byte> bytes, int maxPayloadBytes = DefaultMaxPayloadBytes)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxPayloadBytes);

        if (bytes.Length >= LengthPrefixBytes)
        {
            return BinaryPrimitives.ReadUInt32BigEndian(bytes[..LengthPrefixBytes]) <= (uint)maxPayloadBytes;
        }

        // A partial prefix: the most significant byte is all there is, and all
        // the discriminator needs, since it alone separates 0x01 from 0x7B.
        return bytes.IsEmpty || bytes[0] <= (byte)((uint)maxPayloadBytes >> 24);
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
