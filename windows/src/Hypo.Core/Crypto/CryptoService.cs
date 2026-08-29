using System.Security.Cryptography;
using System.Text;

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

    /// <summary>UTF-8 bytes of "hypo-clipboard-ecdh".</summary>
    public static ReadOnlySpan<byte> HkdfSalt => "hypo-clipboard-ecdh"u8;

    /// <summary>UTF-8 bytes of "hypo-aes-256-gcm".</summary>
    public static ReadOnlySpan<byte> HkdfInfo => "hypo-aes-256-gcm"u8;

    public static (byte[] Ciphertext, byte[] Tag) Encrypt(
        ReadOnlySpan<byte> plaintext,
        ReadOnlySpan<byte> key,
        ReadOnlySpan<byte> nonce,
        ReadOnlySpan<byte> associatedData)
    {
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
}
