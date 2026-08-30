namespace Hypo.Core.Abstractions;

/// <summary>
/// Persists secret material. Keys are normalised to lowercase, matching the
/// device-id normalisation the macOS key store performs.
///
/// <para>The comment here used to promise a DPAPI implementation "in Plan 3".
/// Plan 3 shipped <c>FileSecretStore</c> instead, with owner-only file
/// permissions; DPAPI remains a reasonable upgrade and is nobody's commitment.</para>
/// </summary>
public interface ISecretStore
{
    byte[]? Read(string key);

    void Write(string key, ReadOnlySpan<byte> value);

    bool Delete(string key);

    /// <summary>
    /// Every key held, in no particular order.
    ///
    /// <para>A client has to be able to answer "who am I paired with?" without
    /// being told, or every restart needs the peer list handed to it again.</para>
    /// </summary>
    IEnumerable<string> Keys();
}
