namespace Hypo.Core.Tests;

/// <summary>
/// Resolves the repository root so tests can read the fixtures shared with the
/// macOS and Android suites. See spec section 8.1.
/// </summary>
public static class RepoFixtures
{
    private const string CryptoVectorsRelative = "tests/crypto_test_vectors.json";
    private const string FrameVectorsRelative = "tests/transport/frame_vectors.json";

    public static string Root { get; } = FindRoot();

    public static string CryptoVectorsPath => Combine(CryptoVectorsRelative);

    public static string FrameVectorsPath => Combine(FrameVectorsRelative);

    private static string Combine(string relative) =>
        Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar));

    private static string FindRoot()
    {
        var marker = CryptoVectorsRelative.Replace('/', Path.DirectorySeparatorChar);
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, marker)))
            {
                return dir.FullName;
            }
        }

        throw new InvalidOperationException(
            $"Could not locate the repository root by walking up from '{AppContext.BaseDirectory}' " +
            $"looking for '{CryptoVectorsRelative}'.");
    }
}
