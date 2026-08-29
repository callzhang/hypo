using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Parameters;

namespace Hypo.Core.Crypto;

/// <summary>
/// Protocol cryptography. Constants and algorithms must match CryptoConstants
/// in the macOS client and its Android counterpart byte for byte; see spec
/// section 4.1.
/// </summary>
public static class CryptoService
{
    public const int KeySizeBytes = 32;
    public const int NonceSizeBytes = 12;
    public const int TagSizeBytes = 16;

    /// <summary>X25519 keys are always 32 bytes (RFC 7748).</summary>
    public const int X25519KeySizeBytes = 32;

    /// <summary>UTF-8 bytes of "hypo-clipboard-ecdh".</summary>
    public static ReadOnlySpan<byte> HkdfSalt => "hypo-clipboard-ecdh"u8;

    /// <summary>UTF-8 bytes of "hypo-aes-256-gcm".</summary>
    public static ReadOnlySpan<byte> HkdfInfo => "hypo-aes-256-gcm"u8;

    private static void RequireAesKeySize(ReadOnlySpan<byte> key)
    {
        if (key.Length != KeySizeBytes)
        {
            throw new ArgumentException(
                $"The protocol requires a {KeySizeBytes}-byte AES-256 key; got {key.Length}. " +
                "AesGcm would otherwise silently accept a 16- or 24-byte key and use AES-128 or AES-192, " +
                "which fails authentication on the peer with no indication of the real cause.",
                nameof(key));
        }
    }

    /// <remarks>
    /// The nonce is supplied by the caller; this method does not generate one,
    /// so the uniqueness obligation is the caller's.
    ///
    /// <para>The caller must supply a fresh nonce from a cryptographically
    /// secure source -- <see cref="RandomNumberGenerator.Fill(Span{byte})"/>,
    /// never <see cref="Random"/>.</para>
    ///
    /// <para>A nonce must never be reused under the same key. AES-GCM nonce
    /// reuse is catastrophic rather than merely weakening: two messages
    /// encrypted with the same key and nonce leak the XOR of their plaintexts
    /// and expose the authentication subkey, which lets an attacker forge
    /// tags.</para>
    ///
    /// <para>The dual-transport send path must generate a separate nonce per
    /// transport rather than reusing one across both. The protocol
    /// deliberately sends the same message over two transports, so a single
    /// nonce shared between them would be exactly the reuse described above.
    /// The macOS client owns generation behind a <c>NonceGenerating</c>
    /// abstraction so its callers never supply one; this functional API pushes
    /// the obligation onto the caller instead.</para>
    /// </remarks>
    public static (byte[] Ciphertext, byte[] Tag) Encrypt(
        ReadOnlySpan<byte> plaintext,
        ReadOnlySpan<byte> key,
        ReadOnlySpan<byte> nonce,
        ReadOnlySpan<byte> associatedData)
    {
        RequireAesKeySize(key);

        using var aes = new AesGcm(key, TagSizeBytes);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[TagSizeBytes];
        aes.Encrypt(nonce, plaintext, ciphertext, tag, associatedData);
        return (ciphertext, tag);
    }

    public static byte[] Decrypt(
        ReadOnlySpan<byte> ciphertext,
        ReadOnlySpan<byte> key,
        ReadOnlySpan<byte> nonce,
        ReadOnlySpan<byte> tag,
        ReadOnlySpan<byte> associatedData)
    {
        RequireAesKeySize(key);

        using var aes = new AesGcm(key, TagSizeBytes);
        var plaintext = new byte[ciphertext.Length];
        aes.Decrypt(nonce, ciphertext, tag, plaintext, associatedData);
        return plaintext;
    }

    /// <summary>
    /// Builds the associated data for a clipboard payload: the UTF-8 bytes of
    /// the sender's device id, lowercased.
    /// </summary>
    /// <remarks>
    /// Protocol section 9.2 describes this as "device_id + timestamp", but
    /// neither shipping client does that. macOS uses
    /// <c>Data(entry.deviceId.utf8)</c> when encrypting and
    /// <c>Data(senderId.utf8)</c> when decrypting; Android uses
    /// <c>normalizedSenderDeviceId.encodeToByteArray()</c>. Including a
    /// timestamp here would make every message fail authentication against both
    /// peers. The wire format is defined by the implementations, not the prose.
    ///
    /// Lowercasing follows Android, which normalises defensively on both sides.
    /// macOS instead trusts the wire value, relying on device ids already being
    /// lowercase UUIDs as protocol v1.1 requires. For any peer that honours that
    /// requirement the two behaviours are identical, and the defensive form
    /// fails closed rather than silently mismatching.
    /// </remarks>
    public static byte[] BuildAssociatedData(string deviceId)
    {
        ArgumentNullException.ThrowIfNull(deviceId);
        return Encoding.UTF8.GetBytes(deviceId.ToLowerInvariant());
    }

    /// <summary>
    /// X25519 agreement followed by HKDF-SHA256, matching
    /// CryptoService.deriveKey in the macOS client.
    /// </summary>
    public static byte[] DeriveKey(
        byte[] privateKey,
        byte[] peerPublicKey,
        byte[]? salt = null,
        byte[]? info = null)
    {
        ArgumentNullException.ThrowIfNull(privateKey);
        ArgumentNullException.ThrowIfNull(peerPublicKey);

        if (privateKey.Length != X25519KeySizeBytes)
        {
            throw new ArgumentException(
                $"An X25519 private key is {X25519KeySizeBytes} bytes; got {privateKey.Length}.",
                nameof(privateKey));
        }

        if (peerPublicKey.Length != X25519KeySizeBytes)
        {
            throw new ArgumentException(
                $"An X25519 public key is {X25519KeySizeBytes} bytes; got {peerPublicKey.Length}.",
                nameof(peerPublicKey));
        }

        var agreement = new X25519Agreement();
        agreement.Init(new X25519PrivateKeyParameters(privateKey));

        var sharedSecret = new byte[agreement.AgreementSize];
        agreement.CalculateAgreement(new X25519PublicKeyParameters(peerPublicKey), sharedSecret, 0);

        try
        {
            return HKDF.DeriveKey(
                HashAlgorithmName.SHA256,
                sharedSecret,
                KeySizeBytes,
                salt ?? HkdfSalt.ToArray(),
                info ?? HkdfInfo.ToArray());
        }
        finally
        {
            CryptographicOperations.ZeroMemory(sharedSecret);
        }
    }

    /// <summary>Derives the X25519 public key advertised for a private key.</summary>
    public static byte[] DerivePublicKey(byte[] privateKey)
    {
        ArgumentNullException.ThrowIfNull(privateKey);

        if (privateKey.Length != X25519KeySizeBytes)
        {
            throw new ArgumentException(
                $"An X25519 private key is {X25519KeySizeBytes} bytes; got {privateKey.Length}.",
                nameof(privateKey));
        }

        return new X25519PrivateKeyParameters(privateKey).GeneratePublicKey().GetEncoded();
    }
}
