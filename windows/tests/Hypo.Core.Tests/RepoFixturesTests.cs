namespace Hypo.Core.Tests;

public class RepoFixturesTests
{
    [Fact]
    public void LocatesTheSharedCryptoVectorFile()
    {
        Assert.True(File.Exists(RepoFixtures.CryptoVectorsPath));
    }

    [Fact]
    public void LocatesTheSharedFrameVectorFile()
    {
        Assert.True(File.Exists(RepoFixtures.FrameVectorsPath));
    }
}
