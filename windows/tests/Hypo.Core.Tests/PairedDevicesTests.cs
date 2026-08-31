using Hypo.Core.Abstractions;
using Hypo.Core.Client;
using Hypo.Core.Pairing;

namespace Hypo.Core.Tests;

public class PairedDevicesTests
{
    private const string PhoneId = "bbe296d6-0785-43d2-91b6-b135b72f4c41";
    private const string LaptopId = "007e4a95-0e1a-4b10-91fa-87942efaa68e";

    private static InMemorySecretStore Paired()
    {
        var store = new InMemorySecretStore();

        store.Write(PhoneId, new byte[32]);
        PairedDevices.Remember(store, PhoneId, "OPPO PLP110");
        store.Write(LaptopId, new byte[32]);

        return store;
    }

    [Fact]
    public void ListsWhatIsPairedWithTheNamesItKnows()
    {
        var devices = PairedDevices.All(Paired());

        Assert.Equal(2, devices.Count);
        Assert.Equal("OPPO PLP110", devices.Single(d => d.DeviceId == PhoneId).Name);
    }

    [Fact]
    public void ADeviceWithNoRememberedNameIsStillIdentifiable()
    {
        // Anything paired before the name was recorded, and anything paired by a
        // path that does not know one. A GUID is not an answer to "which of my
        // devices is this?", but the first eight characters at least match what
        // the pairing window showed.
        var device = PairedDevices.All(Paired()).Single(d => d.DeviceId == LaptopId);

        Assert.Null(device.Name);
        Assert.Equal("Unnamed device (007e4a95)", device.DisplayName);
    }

    [Fact]
    public void TheNamesDoNotLookLikePairedDevices()
    {
        // They share a store with the keys. If the prefix ever collided with a
        // device id, every client would try to sync with a name.
        Assert.Equal(2, HypoClient.PairedPeers(Paired()).Count);
    }

    [Fact]
    public void ForgettingTakesTheKeyAndTheName()
    {
        var store = Paired();

        Assert.True(PairedDevices.Forget(store, PhoneId));

        // The key is what matters -- without it nothing from that device
        // decrypts. The name has to go too, or the device stays in every list.
        Assert.Null(store.Read(PhoneId));
        Assert.Null(PairedDevices.NameOf(store, PhoneId));
        Assert.DoesNotContain(PairedDevices.All(store), d => d.DeviceId == PhoneId);
    }

    [Fact]
    public void ForgettingSomethingThatWasNeverPairedSaysSo()
    {
        Assert.False(PairedDevices.Forget(Paired(), "11111111-2222-3333-4444-555555555555"));
    }

    [Fact]
    public void ANamelessPairingRecordsNothingRatherThanAnEmptyName()
    {
        var store = new InMemorySecretStore();

        PairedDevices.Remember(store, PhoneId, null);
        PairedDevices.Remember(store, PhoneId, "   ");

        Assert.Null(PairedDevices.NameOf(store, PhoneId));
    }
}
