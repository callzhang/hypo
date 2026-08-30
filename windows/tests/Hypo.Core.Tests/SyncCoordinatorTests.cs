using System.Text;
using System.Text.Json;
using Hypo.Core.Abstractions;
using Hypo.Core.Crypto;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Core.Transport;
using Hypo.Core.Utils;
using Microsoft.Extensions.Time.Testing;

namespace Hypo.Core.Tests;

public class SyncCoordinatorTests : IDisposable
{
    private const string Me = "11111111-2222-3333-4444-555555555555";
    private const string Peer = "bbe296d6-0785-43d2-91b6-b135b72f4c41";

    private readonly string _dir = Directory.CreateTempSubdirectory("hypo-coordinator").FullName;
    private readonly byte[] _key = new byte[32];
    private readonly List<ClipboardHistoryStore> _stores = [];

    public SyncCoordinatorTests() => Random.Shared.NextBytes(_key);

    public void Dispose()
    {
        // Windows will not delete a directory holding an open file, so every
        // store a test built has to be closed before the temp directory goes.
        foreach (var store in _stores)
        {
            store.Dispose();
        }

        Directory.Delete(_dir, recursive: true);
    }

    /// <summary>Records what was sent; never receives unless a test says so.</summary>
    private sealed class RecordingTransport : ISyncTransport
    {
        public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;
        public event EventHandler<TransportStateChangedEventArgs>? StateChanged;

        public TransportState State => TransportState.Connected;

        public List<SyncEnvelope> Sent { get; } = [];

        public void Deliver(SyncEnvelope envelope) => EnvelopeReceived?.Invoke(
            this, new EnvelopeReceivedEventArgs(envelope, envelope.Payload.DeviceId, TransportOrigin.Cloud));

        public Task ConnectAsync(CancellationToken ct = default) => Task.CompletedTask;

        public Task SendAsync(SyncEnvelope envelope, CancellationToken ct = default)
        {
            Sent.Add(envelope);
            _ = StateChanged;
            return Task.CompletedTask;
        }

        public Task DisconnectAsync(CancellationToken ct = default) => Task.CompletedTask;

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed record Fixture(
        SyncCoordinator Coordinator,
        FakeClipboard Clipboard,
        RecordingTransport Transport,
        ClipboardHistoryStore History,
        FakeTimeProvider Clock,
        List<string> Drops);

    private Fixture Build(bool withPeerKey = true)
    {
        var clipboard = new FakeClipboard();
        var transport = new RecordingTransport();
        var keys = new InMemorySecretStore();
        if (withPeerKey)
        {
            keys.Write(Peer, _key);
        }

        var history = new ClipboardHistoryStore(Path.Combine(_dir, $"{Guid.NewGuid():N}.db"));
        _stores.Add(history);
        var clock = new FakeTimeProvider(DateTimeOffset.UnixEpoch);

        var coordinator = new SyncCoordinator(
            clipboard, transport, keys, history, Me, "Windows", clock: clock);
        coordinator.Peers.Add(Peer);

        var drops = new List<string>();
        coordinator.Dropped += (_, reason) => drops.Add(reason);

        return new Fixture(coordinator, clipboard, transport, history, clock, drops);
    }

    private SyncEnvelope Inbound(string text, byte[]? key = null, string? from = null)
    {
        var body = GzipCompressor.Compress(JsonSerializer.SerializeToUtf8Bytes(
            new ClipboardPayload
            {
                ContentType = ContentType.Text,
                Data = Encoding.UTF8.GetBytes(text),
                Compressed = true,
            },
            ProtocolJson.Options));

        var senderId = from ?? Peer;
        var nonce = new byte[CryptoService.NonceSizeBytes];
        Random.Shared.NextBytes(nonce);

        var (ciphertext, tag) = CryptoService.Encrypt(
            body, key ?? _key, nonce, CryptoService.BuildAssociatedData(senderId));

        return new SyncEnvelope
        {
            Id = Guid.NewGuid(),
            Timestamp = DateTimeOffset.UnixEpoch,
            Type = MessageType.Clipboard,
            Payload = new EnvelopePayload
            {
                ContentType = ContentType.Text,
                Ciphertext = ciphertext,
                DeviceId = senderId,
                DeviceName = "OPPO PLP110",
                Encryption = new EncryptionMetadata { Nonce = nonce, Tag = tag },
            },
        };
    }

    private static async Task Settle() => await Task.Delay(100);

    [Fact]
    public async Task ApplyingAnInboundItemDoesNotSendItBack()
    {
        // Written first because it is the failure that is unbounded rather than
        // merely wrong: two devices echoing one item forever.
        var f = Build();

        f.Transport.Deliver(Inbound("from the phone"));
        await Settle();

        Assert.Equal("from the phone", Encoding.UTF8.GetString(f.Clipboard.Current!.Data));
        Assert.Empty(f.Transport.Sent);
    }

    [Fact]
    public async Task ALocalCopyIsSentToEachPeer()
    {
        var f = Build();

        f.Clipboard.SimulateExternalCopy(new ClipboardContent
        {
            ContentType = ContentType.Text,
            Data = Encoding.UTF8.GetBytes("copied here"),
        });
        await Settle();

        Assert.Single(f.Transport.Sent);
        Assert.Equal(Peer, f.Transport.Sent[0].Payload.Target);
        Assert.Equal(Me, f.Transport.Sent[0].Payload.DeviceId);
    }

    [Fact]
    public async Task EverySendGetsAFreshNonce()
    {
        // Nonce reuse under one key is catastrophic, and sending the same
        // content twice is exactly where a hoisted nonce would look harmless.
        var f = Build();
        var content = new ClipboardContent
        {
            ContentType = ContentType.Text,
            Data = Encoding.UTF8.GetBytes("the very same text"),
        };

        await f.Coordinator.SendAsync(content);
        await f.Coordinator.SendAsync(content);

        Assert.Equal(2, f.Transport.Sent.Count);
        Assert.NotEqual(
            Convert.ToHexString(f.Transport.Sent[0].Payload.Encryption.Nonce),
            Convert.ToHexString(f.Transport.Sent[1].Payload.Encryption.Nonce));
    }

    [Fact]
    public async Task RejectsAMessageWhoseSenderDoesNotMatchItsAssociatedData()
    {
        // A peer claiming to be someone else in the body is what the AAD exists
        // to catch: the ciphertext was sealed against a different id, so
        // decryption fails and the message never reaches the clipboard.
        var f = Build();

        var envelope = Inbound("forged", from: "99999999-0000-0000-0000-000000000000");
        var relabelled = envelope with
        {
            Payload = envelope.Payload with { DeviceId = Peer },
        };

        f.Transport.Deliver(relabelled);
        await Settle();

        Assert.Null(f.Clipboard.Current);
        Assert.Contains(f.Drops, d => d.Contains("Could not read", StringComparison.Ordinal));
    }

    [Fact]
    public async Task TheDoubleSendReachesTheClipboardOnce()
    {
        // Plan 4's measurement: two envelopes, same content, different ids,
        // inside one second. Envelope-id dedup cannot help; content dedup does.
        var f = Build();

        f.Transport.Deliver(Inbound("duplicate probe"));
        await Settle();
        f.Transport.Deliver(Inbound("duplicate probe"));
        await Settle();

        Assert.Single(f.Clipboard.Writes);
        Assert.Single(f.History.Recent());
        Assert.Contains(f.Drops, d => d.Contains("Duplicate", StringComparison.Ordinal));
    }

    [Fact]
    public async Task TheSameContentIsAcceptedAgainAfterTheDedupWindow()
    {
        var f = Build();

        f.Transport.Deliver(Inbound("sent twice deliberately"));
        await Settle();
        f.Clock.Advance(TimeSpan.FromMinutes(1));
        f.Transport.Deliver(Inbound("sent twice deliberately"));
        await Settle();

        Assert.Equal(2, f.Clipboard.Writes.Count);
    }

    [Fact]
    public async Task DropsAMessageFromAnUnpairedPeerWithAReason()
    {
        var f = Build(withPeerKey: false);

        f.Transport.Deliver(Inbound("from a stranger"));
        await Settle();

        Assert.Null(f.Clipboard.Current);
        Assert.Contains(f.Drops, d => d.Contains("No key", StringComparison.Ordinal));
    }

    [Fact]
    public async Task RecordsInboundItemsWithTheirSource()
    {
        var f = Build();

        f.Transport.Deliver(Inbound("from the phone"));
        await Settle();

        var entry = f.History.Recent()[0];
        Assert.Equal(Peer, entry.SourceDeviceId);
        Assert.Equal("OPPO PLP110", entry.SourceDeviceName);
    }

    [Fact]
    public async Task RecordsLocalCopiesWithNoSource()
    {
        var f = Build();

        await f.Coordinator.SendAsync(new ClipboardContent
        {
            ContentType = ContentType.Text,
            Data = Encoding.UTF8.GetBytes("mine"),
        });

        Assert.Null(f.History.Recent()[0].SourceDeviceId);
    }

    [Fact]
    public async Task KeepsAnItemTheClipboardCannotHoldAndKeepsWorking()
    {
        // The phone can send images; a text-only clipboard build would throw
        // from SetAsync inside a fire-and-forget task, where the exception is
        // never observed and the inbound path silently stops.
        var f = Build();
        f.Clipboard.RefuseWrites = true;

        f.Transport.Deliver(Inbound("something this clipboard refuses"));
        await Settle();

        Assert.Single(f.History.Recent());
        Assert.Contains(f.Drops, d => d.Contains("cannot hold", StringComparison.Ordinal));

        // Still alive: the next item, which it can hold, goes through.
        f.Clipboard.RefuseWrites = false;
        f.Transport.Deliver(Inbound("and this one it can"));
        await Settle();

        Assert.Equal("and this one it can", Encoding.UTF8.GetString(f.Clipboard.Current!.Data));
    }
}
