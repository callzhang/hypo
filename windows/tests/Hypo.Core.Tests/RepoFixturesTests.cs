namespace Hypo.Core.Tests;

public class RepoFixturesTests
{
    [Fact]
    public void LocatesTheSharedCryptoVectorFile()
    {
        var path = RepoFixtures.CryptoVectorsPath;
        Assert.True(File.Exists(path), $"Expected the shared crypto vectors at '{path}'.");
    }

    [Fact]
    public void LocatesTheSharedFrameVectorFile()
    {
        var path = RepoFixtures.FrameVectorsPath;
        Assert.True(File.Exists(path), $"Expected the shared frame vectors at '{path}'.");
    }
}
