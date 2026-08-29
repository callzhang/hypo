using Hypo.Core.Abstractions;

namespace Hypo.Core.Tests;

public class FileSecretStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "hypo-secret-store-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_dir))
        {
            Directory.Delete(_dir, recursive: true);
        }
    }

    [Fact]
    public void ReturnsNullForAnAbsentKey()
    {
        Assert.Null(new FileSecretStore(_dir).Read("missing"));
    }

    [Fact]
    public void ReadsBackWhatItWrote()
    {
        var store = new FileSecretStore(_dir);

        store.Write("device-key", [0x01, 0x02, 0x03]);

        Assert.Equal(new byte[] { 0x01, 0x02, 0x03 }, store.Read("device-key"));
    }

    [Fact]
    public void SurvivesANewInstance()
    {
        // The whole point: pair in one process, receive in the next.
        new FileSecretStore(_dir).Write("device-key", [0xAB, 0xCD]);

        Assert.Equal(new byte[] { 0xAB, 0xCD }, new FileSecretStore(_dir).Read("device-key"));
    }

    [Fact]
    public void OverwritesAnExistingKey()
    {
        var store = new FileSecretStore(_dir);

        store.Write("device-key", [0x01]);
        store.Write("device-key", [0x02]);

        Assert.Equal(new byte[] { 0x02 }, store.Read("device-key"));
    }

    [Fact]
    public void DeleteRemovesAKeyAndReportsWhetherItExisted()
    {
        var store = new FileSecretStore(_dir);
        store.Write("device-key", [0x01]);

        Assert.True(store.Delete("device-key"));
        Assert.False(store.Delete("device-key"));
        Assert.Null(store.Read("device-key"));
    }

    [Fact]
    public void NormalisesKeysToLowercase()
    {
        var store = new FileSecretStore(_dir);

        store.Write("Device-KEY", [0x01]);

        Assert.Equal(new byte[] { 0x01 }, store.Read("device-key"));
    }

    [Fact]
    public void RejectsAKeyThatWouldEscapeTheDirectory()
    {
        // Device ids come off the network. A store that pastes one into a path
        // is a directory traversal waiting to happen.
        var store = new FileSecretStore(_dir);

        Assert.Throws<ArgumentException>(() => store.Write("../escape", [0x01]));
        Assert.Throws<ArgumentException>(() => store.Read("../../etc/passwd"));
    }

    [Fact]
    public void AcceptsARealDeviceId()
    {
        var store = new FileSecretStore(_dir);

        store.Write("bbe296d6-0785-43d2-91b6-b135b72f4c41", [0x01]);

        Assert.NotNull(store.Read("bbe296d6-0785-43d2-91b6-b135b72f4c41"));
    }
}
