using System.Buffers.Binary;
using System.Text;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class FrameReaderTests
{
    private static byte[] Frame(string body)
    {
        var payload = Encoding.UTF8.GetBytes(body);
        var frame = new byte[4 + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(0, 4), (uint)payload.Length);
        payload.CopyTo(frame.AsSpan(4));
        return frame;
    }

    [Fact]
    public void YieldsNothingUntilAWholeFrameHasArrived()
    {
        var reader = new FrameReader();
        var frame = Frame("hello");

        Assert.Empty(reader.Append(frame.AsSpan(0, 3).ToArray()));
        Assert.Empty(reader.Append(frame.AsSpan(3, 4).ToArray()));

        var completed = reader.Append(frame.AsSpan(7).ToArray());

        Assert.Single(completed);
        Assert.Equal("hello", Encoding.UTF8.GetString(completed[0]));
    }

    [Fact]
    public void YieldsEveryFrameFromACoalescedRead()
    {
        var reader = new FrameReader();
        var buffer = Frame("one").Concat(Frame("two")).Concat(Frame("three")).ToArray();

        var completed = reader.Append(buffer);

        Assert.Equal(["one", "two", "three"], completed.Select(f => Encoding.UTF8.GetString(f)));
    }

    [Fact]
    public void KeepsAPartialTrailingFrameForTheNextRead()
    {
        var reader = new FrameReader();
        var whole = Frame("one");
        var partial = Frame("two");

        var first = reader.Append(whole.Concat(partial.Take(5)).ToArray());
        Assert.Single(first);

        var second = reader.Append(partial.Skip(5).ToArray());
        Assert.Single(second);
        Assert.Equal("two", Encoding.UTF8.GetString(second[0]));
    }

    [Fact]
    public void RejectsALengthPrefixAboveTheCeiling()
    {
        var reader = new FrameReader(maxFrameBytes: 16);
        var prefix = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(prefix, 17);

        var error = Assert.Throws<TransportFrameException>(() => reader.Append(prefix));

        Assert.Equal(TransportFrameError.PayloadTooLarge, error.Error);
    }

    [Fact]
    public void RejectsAUIntMaxValueLengthPrefix()
    {
        var reader = new FrameReader();

        var error = Assert.Throws<TransportFrameException>(
            () => reader.Append([0xFF, 0xFF, 0xFF, 0xFF]));

        Assert.Equal(TransportFrameError.PayloadTooLarge, error.Error);
    }

    [Fact]
    public void HandlesAZeroLengthFrame()
    {
        var reader = new FrameReader();

        var completed = reader.Append([0x00, 0x00, 0x00, 0x00]);

        Assert.Single(completed);
        Assert.Empty(completed[0]);
    }

    [Fact]
    public void ResetDiscardsBufferedBytesAndLeavesTheReaderUsable()
    {
        var reader = new FrameReader();
        reader.Append(Frame("hello").AsSpan(0, 5).ToArray());
        Assert.Equal(5, reader.Buffered);

        reader.Reset();

        Assert.Equal(0, reader.Buffered);

        // The discarded prefix must not corrupt what follows: a whole frame
        // appended after a Reset has to parse cleanly.
        var completed = reader.Append(Frame("x"));
        Assert.Single(completed);
        Assert.Equal("x", Encoding.UTF8.GetString(completed[0]));
    }
}
