using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Hypo.Core.Crypto;

/// <summary>
/// Ed25519 signing for pairing payloads. Peers advertise the public half as
/// signing_pub_key; see the design spec section 4.2. Matches
/// Curve25519.Signing on macOS.
/// </summary>
public static class SigningService
{
    public const int KeySizeBytes = 32;
    public const int SignatureSizeBytes = 64;

    public static byte[] GeneratePrivateKey()
    {
        var seed = new byte[KeySizeBytes];
        System.Security.Cryptography.RandomNumberGenerator.Fill(seed);
        return seed;
    }

    public static byte[] DerivePublicKey(byte[] privateKey)
    {
        RequireKeySize(privateKey, nameof(privateKey));
        return new Ed25519PrivateKeyParameters(privateKey).GeneratePublicKey().GetEncoded();
    }

    public static byte[] Sign(byte[] message, byte[] privateKey)
    {
        ArgumentNullException.ThrowIfNull(message);
        RequireKeySize(privateKey, nameof(privateKey));

        var signer = new Ed25519Signer();
        signer.Init(true, new Ed25519PrivateKeyParameters(privateKey));
        signer.BlockUpdate(message, 0, message.Length);
        return signer.GenerateSignature();
    }

    /// <summary>
    /// Returns false rather than throwing for anything malformed. Signatures and
    /// keys here arrive from peers, so a bad one is untrusted input rather than
    /// a bug, and a bool is harder for a caller to ignore than an exception.
    /// </summary>
    public static bool Verify(byte[] message, byte[] signature, byte[] publicKey)
    {
        if (message is null || signature is null || publicKey is null ||
            publicKey.Length != KeySizeBytes ||
            signature.Length != SignatureSizeBytes)
        {
            return false;
        }

        try
        {
            var verifier = new Ed25519Signer();
            verifier.Init(false, new Ed25519PublicKeyParameters(publicKey));
            verifier.BlockUpdate(message, 0, message.Length);
            return verifier.VerifySignature(signature);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static void RequireKeySize(byte[] key, string paramName)
    {
        ArgumentNullException.ThrowIfNull(key, paramName);

        if (key.Length != KeySizeBytes)
        {
            throw new ArgumentException(
                $"An Ed25519 key is {KeySizeBytes} bytes; got {key.Length}.", paramName);
        }
    }
}
