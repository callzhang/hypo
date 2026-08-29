using Hypo.Core.Abstractions;

namespace Hypo.Core.Tests;

public class InMemorySecretStoreTests
{
    [Fact]
    public void ReturnsNullForAnAbsentKey()
    {
        Assert.Null(new InMemorySecretStore().Read("missing"));
    }

    [Fact]
    public void ReadsBackWhatItWrote()
    {
        var store = new InMemorySecretStore();

        store.Write("device-key", [0x01, 0x02, 0x03]);

        Assert.Equal(new byte[] { 0x01, 0x02, 0x03 }, store.Read("device-key"));
    }

    [Fact]
    public void OverwritesAnExistingKey()
    {
        var store = new InMemorySecretStore();

        store.Write("device-key", [0x01]);
        store.Write("device-key", [0x02]);

        Assert.Equal(new byte[] { 0x02 }, store.Read("device-key"));
    }

    [Fact]
    public void DeleteRemovesAKeyAndReportsWhetherItExisted()
    {
        var store = new InMemorySecretStore();
        store.Write("device-key", [0x01]);

        Assert.True(store.Delete("device-key"));
        Assert.False(store.Delete("device-key"));
        Assert.Null(store.Read("device-key"));
    }

    [Fact]
    public void NormalisesKeysToLowercase()
    {
        var store = new InMemorySecretStore();

        store.Write("Device-KEY", [0x01]);

        Assert.Equal(new byte[] { 0x01 }, store.Read("device-key"));
    }

    [Fact]
    public void DoesNotAliasTheCallersArray()
    {
        var store = new InMemorySecretStore();
        var written = new byte[] { 0x01 };

        store.Write("device-key", written);
        written[0] = 0xFF;

        Assert.Equal(new byte[] { 0x01 }, store.Read("device-key"));
    }
}
