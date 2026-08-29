using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class Base64CompatTests
{
    [Theory]
    [InlineData("3q2+7w==", new byte[] { 0xDE, 0xAD, 0xBE, 0xEF })]
    [InlineData("3q2+7w", new byte[] { 0xDE, 0xAD, 0xBE, 0xEF })]
    [InlineData("qrvM", new byte[] { 0xAA, 0xBB, 0xCC })]
    [InlineData("", new byte[0])]
    public void DecodesPaddedAndUnpaddedInput(string input, byte[] expected)
    {
        Assert.Equal(expected, Base64Compat.Decode(input));
    }

    [Fact]
    public void DecodesUnpaddedInputRequiringTwoPadCharacters()
    {
        // "AA" decodes to a single 0x00 byte and needs "==" appended.
        Assert.Equal(new byte[] { 0x00 }, Base64Compat.Decode("AA"));
    }

    [Fact]
    public void ThrowsOnInputThatIsNotValidBase64()
    {
        Assert.Throws<FormatException>(() => Base64Compat.Decode("not base64!"));
    }
}
