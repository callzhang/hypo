using Hypo.Core.Crypto;

namespace Hypo.Core.Tests;

public class SigningServiceTests
{
    private static (byte[] Private, byte[] Public) Key()
    {
        var priv = SigningService.GeneratePrivateKey();
        return (priv, SigningService.DerivePublicKey(priv));
    }

    [Fact]
    public void GeneratesKeysOfTheRightLength()
    {
        var (priv, pub) = Key();

        Assert.Equal(SigningService.KeySizeBytes, priv.Length);
        Assert.Equal(SigningService.KeySizeBytes, pub.Length);
    }

    [Fact]
    public void VerifiesWhatItSigned()
    {
        var (priv, pub) = Key();
        var message = "the payload"u8.ToArray();

        var signature = SigningService.Sign(message, priv);

        Assert.Equal(SigningService.SignatureSizeBytes, signature.Length);
        Assert.True(SigningService.Verify(message, signature, pub));
    }

    [Fact]
    public void RejectsATamperedMessage()
    {
        var (priv, pub) = Key();
        var signature = SigningService.Sign("the payload"u8.ToArray(), priv);

        Assert.False(SigningService.Verify("the paylaod"u8.ToArray(), signature, pub));
    }

    [Fact]
    public void RejectsATamperedSignature()
    {
        var (priv, pub) = Key();
        var message = "the payload"u8.ToArray();
        var signature = SigningService.Sign(message, priv);
        signature[0] ^= 0xFF;

        Assert.False(SigningService.Verify(message, signature, pub));
    }

    [Fact]
    public void RejectsAnotherPartysKey()
    {
        var (priv, _) = Key();
        var (_, otherPub) = Key();
        var message = "the payload"u8.ToArray();

        Assert.False(SigningService.Verify(message, SigningService.Sign(message, priv), otherPub));
    }

    [Fact]
    public void VerifyReturnsFalseRatherThanThrowingOnAMalformedSignature()
    {
        // Signatures arrive from peers. A malformed one is untrusted input, not
        // a programming error, and callers should get a bool rather than an
        // exception they have to remember to catch.
        var (_, pub) = Key();

        Assert.False(SigningService.Verify("x"u8.ToArray(), [0x01, 0x02], pub));
    }

    [Theory]
    [InlineData(31)]
    [InlineData(33)]
    public void NamesTheOffendingArgumentOnAWrongLengthKey(int length)
    {
        var error = Assert.Throws<ArgumentException>(
            () => SigningService.Sign("x"u8.ToArray(), new byte[length]));

        Assert.Equal("privateKey", error.ParamName);
    }

    [Fact]
    public void VerifyRejectsAWrongLengthPublicKeyWithoutThrowing()
    {
        Assert.False(SigningService.Verify("x"u8.ToArray(), new byte[64], new byte[31]));
    }
}
