namespace Hypo.Core.Abstractions;

/// <summary>
/// Persists secret material. Keys are normalised to lowercase, matching the
/// device-id normalisation the macOS key store performs.
/// The Windows DPAPI implementation arrives in Plan 3.
/// </summary>
public interface ISecretStore
{
    byte[]? Read(string key);

    void Write(string key, ReadOnlySpan<byte> value);

    bool Delete(string key);
}
