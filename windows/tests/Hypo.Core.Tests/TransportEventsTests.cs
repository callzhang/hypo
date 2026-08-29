using Hypo.Core.Protocol;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class TransportEventsTests
{
    private static SyncEnvelope Envelope() => new()
    {
        Id = Guid.NewGuid(),
        Timestamp = DateTimeOffset.UtcNow,
        Type = MessageType.Clipboard,
        Payload = new EnvelopePayload
        {
            ContentType = ContentType.Text,
            Ciphertext = [0x01],
            DeviceId = "550e8400-e29b-41d4-a716-446655440000",
            Encryption = new EncryptionMetadata { Nonce = [0xAA], Tag = [0xBB] },
        },
    };

    [Fact]
    public void EnvelopeReceivedCarriesTheSenderAndTheOrigin()
    {
        var args = new EnvelopeReceivedEventArgs(Envelope(), "peer-id", TransportOrigin.Lan);

        Assert.Equal("peer-id", args.PeerDeviceId);
        Assert.Equal(TransportOrigin.Lan, args.Origin);
        Assert.Equal(MessageType.Clipboard, args.Envelope.Type);
    }

    [Theory]
    [InlineData(TransportState.Disconnected)]
    [InlineData(TransportState.Connecting)]
    [InlineData(TransportState.Connected)]
    [InlineData(TransportState.Faulted)]
    public void StateChangedCarriesTheNewState(TransportState state)
    {
        Assert.Equal(state, new TransportStateChangedEventArgs(state, null).State);
    }

    [Fact]
    public void AFaultedStateCanCarryTheReason()
    {
        var error = new IOException("connection reset");

        var args = new TransportStateChangedEventArgs(TransportState.Faulted, error);

        Assert.Same(error, args.Error);
    }
}
