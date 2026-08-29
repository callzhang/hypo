using System.Security.Cryptography;
using Hypo.Core.Protocol;

namespace Hypo.Core.Sync;

/// <summary>
/// One clipboard item's identity: what it is and what it contains.
///
/// <para>The hash is what makes duplicate suppression possible at all. The
/// transports cannot do it -- they see ciphertext, and two encryptions of the
/// same plaintext under different nonces share no bytes -- so identity is
/// established here, after decryption.</para>
/// </summary>
public sealed record ClipboardContent
{
    public required ContentType ContentType { get; init; }

    public required byte[] Data { get; init; }

    /// <summary>
    /// SHA-256 over the content type and the bytes. The type is included
    /// because a text item and a file item that happen to share bytes are not
    /// the same clipboard entry, and treating them as one would silently drop
    /// the second.
    /// </summary>
    public byte[] Hash => field ??= ComputeHash(ContentType, Data);

    /// <summary>
    /// The first 16 hex characters of <c>SHA-256(data)</c> -- deliberately of
    /// the bytes alone, with no content type mixed in, because this is the
    /// value the Android client logs on every accepted item
    /// (IncomingClipboardHandler). Matching it turns two devices' logs from
    /// "both handled something" into "both handled the same thing".
    ///
    /// <para>For comparison only. <see cref="Hash"/> is what dedup uses.</para>
    /// </summary>
    public string LogHash => field ??= Convert.ToHexStringLower(SHA256.HashData(Data))[..16];

    private static byte[] ComputeHash(ContentType type, byte[] data)
    {
        // A stable, explicit encoding of the type -- not GetHashCode, whose
        // value is not guaranteed to be the same in the next process. Dedup
        // that forgets everything on restart is not dedup.
        var label = System.Text.Encoding.UTF8.GetBytes($"{type:G}\n".ToLowerInvariant());

        var buffer = new byte[label.Length + data.Length];
        label.CopyTo(buffer, 0);
        data.CopyTo(buffer, label.Length);

        return SHA256.HashData(buffer);
    }

    public bool HasSameContentAs(ClipboardContent other)
    {
        ArgumentNullException.ThrowIfNull(other);
        return CryptographicOperations.FixedTimeEquals(Hash, other.Hash);
    }
}
