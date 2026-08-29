using System.Buffers.Binary;

namespace Hypo.Core.Protocol;

/// <summary>
/// Accumulates bytes from a stream and yields complete frame bodies. A socket
/// read gives neither one frame nor a whole frame, so the buffering has to live
/// somewhere; TransportFrameCodec deliberately stays a pure function over one
/// complete frame.
/// </summary>
public sealed class FrameReader
{
    private const int LengthPrefixBytes = 4;

    private readonly int _maxFrameBytes;
    private readonly MemoryStream _buffer = new();

    public FrameReader(int maxFrameBytes = TransportFrameCodec.DefaultMaxPayloadBytes)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxFrameBytes);
        _maxFrameBytes = maxFrameBytes;
    }

    /// <summary>Bytes currently held back waiting for the rest of a frame.</summary>
    public int Buffered => (int)_buffer.Length;

    /// <summary>
    /// Adds bytes and returns every frame body completed by them, in order.
    /// </summary>
    /// <exception cref="TransportFrameException">
    /// A length prefix exceeds the ceiling. The connection is not recoverable
    /// after this: the stream position is no longer trustworthy.
    /// </exception>
    public IReadOnlyList<byte[]> Append(ReadOnlySpan<byte> bytes)
    {
        _buffer.Seek(0, SeekOrigin.End);
        _buffer.Write(bytes);

        var data = _buffer.GetBuffer().AsSpan(0, (int)_buffer.Length);
        var completed = new List<byte[]>();
        var offset = 0;

        while (data.Length - offset >= LengthPrefixBytes)
        {
            var declared = BinaryPrimitives.ReadUInt32BigEndian(data.Slice(offset, LengthPrefixBytes));
            if (declared > _maxFrameBytes)
            {
                throw new TransportFrameException(
                    TransportFrameError.PayloadTooLarge,
                    $"Peer declared a {declared} byte frame, exceeding the {_maxFrameBytes} byte ceiling.");
            }

            var total = LengthPrefixBytes + (int)declared;
            if (data.Length - offset < total)
            {
                break;
            }

            completed.Add(data.Slice(offset + LengthPrefixBytes, (int)declared).ToArray());
            offset += total;
        }

        Compact(offset);
        return completed;
    }

    /// <summary>Discards buffered bytes. Call on reconnect.</summary>
    public void Reset() => _buffer.SetLength(0);

    private void Compact(int consumed)
    {
        if (consumed == 0)
        {
            return;
        }

        var remaining = (int)_buffer.Length - consumed;
        if (remaining > 0)
        {
            var raw = _buffer.GetBuffer();
            Array.Copy(raw, consumed, raw, 0, remaining);
        }

        _buffer.SetLength(remaining);
    }
}
