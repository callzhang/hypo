using System.Text;
using System.Text.Json;
using Hypo.Core.Abstractions;
using Hypo.Core.Crypto;
using Hypo.Core.Discovery;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;

// A development harness for exercising Hypo.Core against a real peer. Not a
// product: keys live in memory and vanish on exit, which is why "pair" and
// "send" are one command rather than two.
//
//   discover              list peers on this network
//   pair <device-id>      pair with one, then hold to receive. Set
//                         HYPO_SEND_TEXT to also push one text item.
//   listen                accept inbound connections and print what arrives

var command = args.Length > 0 ? args[0] : "discover";
var deviceId = Environment.GetEnvironmentVariable("HYPO_DEVICE_ID")
               ?? "11111111-2222-3333-4444-555555555555";
var deviceName = Environment.GetEnvironmentVariable("HYPO_DEVICE_NAME") ?? "Hypo Harness";
var store = new InMemorySecretStore();

switch (command)
{
    case "discover":
        await DiscoverAsync();
        break;
    case "pair":
        await PairAsync(args.ElementAtOrDefault(1));
        break;
    case "listen":
        await ListenAsync();
        break;
    default:
        Console.WriteLine("usage: discover | pair <device-id> | listen");
        break;
}

async Task<IReadOnlyCollection<DiscoveredPeer>> BrowseAsync(TimeSpan window)
{
    await using var discovery = new MdnsPeerDiscovery();
    await discovery.StartBrowsingAsync();

    var deadline = DateTimeOffset.UtcNow + window;
    while (DateTimeOffset.UtcNow < deadline)
    {
        await Task.Delay(TimeSpan.FromSeconds(3));
        discovery.Refresh();
    }

    return discovery.KnownPeers;
}

async Task DiscoverAsync()
{
    Console.WriteLine("Browsing for _hypo._tcp peers for 12s...");
    foreach (var peer in await BrowseAsync(TimeSpan.FromSeconds(12)))
    {
        Console.WriteLine($"  {peer.DisplayName}");
        Console.WriteLine($"    address    {peer.Address}:{peer.Port}");
        Console.WriteLine($"    device_id  {peer.DeviceId ?? "(not advertised)"}");
        Console.WriteLine($"    version    {peer.Version ?? "(not advertised)"}");
        Console.WriteLine($"    pub_key    {(peer.PublicKey is null ? "(none)" : Convert.ToBase64String(peer.PublicKey))}");
    }
}

async Task PairAsync(string? target)
{
    if (string.IsNullOrWhiteSpace(target))
    {
        Console.WriteLine("usage: pair <device-id>");
        return;
    }

    var peer = (await BrowseAsync(TimeSpan.FromSeconds(12)))
        .FirstOrDefault(p => string.Equals(p.DeviceId, target, StringComparison.OrdinalIgnoreCase));

    if (peer is null)
    {
        Console.WriteLine($"No peer advertising device_id {target}. Run 'discover' first.");
        return;
    }

    if (peer.PublicKey is null)
    {
        Console.WriteLine($"{peer.DisplayName} advertises no pub_key, so it cannot be paired with over the LAN.");
        return;
    }

    Console.WriteLine($"Pairing with {peer.DisplayName} at {peer.Address}:{peer.Port}...");

    var session = PairingSession.StartInitiator(deviceId, deviceName);
    var challenge = session.CreateChallenge(peer.PublicKey);

    await using var client = new LanWebSocketClient(peer, deviceId);
    var ackReceived = new TaskCompletionSource<PairingAckMessage>();

    client.PairingMessageReceived += (_, e) =>
    {
        try
        {
            var ack = JsonSerializer.Deserialize<PairingAckMessage>(e.Json, ProtocolJson.Options);
            if (ack is not null)
            {
                ackReceived.TrySetResult(ack);
            }
        }
        catch (JsonException)
        {
            Console.WriteLine($"Ignoring unparseable pairing message: {e.Json}");
        }
    };
    client.EnvelopeReceived += (_, e) => PrintClipboard(e);

    await client.ConnectAsync();
    await client.SendPairingAsync(challenge);

    PairingAckMessage ack;
    try
    {
        ack = await ackReceived.Task.WaitAsync(TimeSpan.FromSeconds(30));
    }
    catch (TimeoutException)
    {
        Console.WriteLine("No pairing reply within 30s.");
        Console.WriteLine(
            "That is all this says: the connection was accepted and no parseable ack arrived. "
            + "Whether the peer never answered or answered in a shape we dropped needs a probe "
            + "that logs raw inbound frames.");
        return;
    }

    var completed = session.CompleteWithAck(ack, peer.PublicKey);

    if (completed is null)
    {
        Console.WriteLine("Pairing failed: the ack did not verify.");
        return;
    }

    store.Write(completed.PeerDeviceId, completed.SharedKey);
    Console.WriteLine($"Paired with {completed.PeerDeviceName} ({completed.PeerDeviceId}).");

    // Sending is folded into "pair" for the same reason pairing is: the shared
    // key lives in memory and dies with the process, so a separate command
    // would have nothing to encrypt with.
    var outbound = Environment.GetEnvironmentVariable("HYPO_SEND_TEXT");
    if (!string.IsNullOrEmpty(outbound))
    {
        await SendClipboardAsync(client, completed.SharedKey, outbound);
        Console.WriteLine($"Sent {Encoding.UTF8.GetByteCount(outbound)} bytes of text to {completed.PeerDeviceName}.");
    }

    Console.WriteLine("Holding open. Copy something on the peer; Ctrl+C to exit.");
    await Task.Delay(Timeout.Infinite);
}

async Task SendClipboardAsync(LanWebSocketClient client, byte[] key, string text)
{
    var payload = new ClipboardPayload
    {
        ContentType = ContentType.Text,
        Data = Encoding.UTF8.GetBytes(text),
        Compressed = true,
    };

    var compressed = Hypo.Core.Utils.GzipCompressor.Compress(
        JsonSerializer.SerializeToUtf8Bytes(payload, ProtocolJson.Options));

    var nonce = new byte[CryptoService.NonceSizeBytes];
    System.Security.Cryptography.RandomNumberGenerator.Fill(nonce);
    var (ciphertext, tag) = CryptoService.Encrypt(
        compressed, key, nonce, CryptoService.BuildAssociatedData(deviceId));

    await client.SendAsync(new SyncEnvelope
    {
        Id = Guid.NewGuid(),
        Timestamp = DateTimeOffset.UtcNow,
        Type = MessageType.Clipboard,
        Payload = new EnvelopePayload
        {
            ContentType = ContentType.Text,
            Ciphertext = ciphertext,
            DeviceId = deviceId,
            DevicePlatform = "windows",
            DeviceName = deviceName,
            Encryption = new EncryptionMetadata { Nonce = nonce, Tag = tag },
        },
    });
}

async Task ListenAsync()
{
    await using var server = new LanWebSocketServer();
    server.EnvelopeReceived += (_, e) => PrintClipboard(e);
    await server.StartAsync();

    await using var discovery = new MdnsPeerDiscovery();
    var signing = SigningService.GeneratePrivateKey();
    var agreement = new byte[CryptoService.X25519KeySizeBytes];
    System.Security.Cryptography.RandomNumberGenerator.Fill(agreement);
    var agreementPublic = CryptoService.DerivePublicKey(agreement);

    await discovery.AdvertiseAsync(deviceName, server.BoundPort, new Dictionary<string, string>
    {
        ["device_id"] = deviceId,
        ["pub_key"] = Convert.ToBase64String(agreementPublic),
        ["signing_pub_key"] = Convert.ToBase64String(SigningService.DerivePublicKey(signing)),
        ["version"] = "2.0.0-harness",
        // The fingerprint is the SHA-256 of the agreement key, matching macOS.
        ["fingerprint_sha256"] = Convert.ToHexString(
            System.Security.Cryptography.SHA256.HashData(agreementPublic)).ToLowerInvariant(),
    });

    Console.WriteLine($"Listening on port {server.BoundPort}, advertising as \"{deviceName}\".");
    Console.WriteLine("Ctrl+C to exit.");
    await Task.Delay(Timeout.Infinite);
}

void PrintClipboard(EnvelopeReceivedEventArgs e)
{
    var key = store.Read(e.PeerDeviceId);
    if (key is null)
    {
        Console.WriteLine($"[{e.Origin}] {e.PeerDeviceId}: no key for this peer; pair first.");
        return;
    }

    try
    {
        var plaintext = CryptoService.Decrypt(
            e.Envelope.Payload.Ciphertext,
            key,
            e.Envelope.Payload.Encryption.Nonce,
            e.Envelope.Payload.Encryption.Tag,
            CryptoService.BuildAssociatedData(e.Envelope.Payload.DeviceId));

        var payload = JsonSerializer.Deserialize<ClipboardPayload>(
            Hypo.Core.Utils.GzipCompressor.Decompress(plaintext), ProtocolJson.Options)!;

        Console.WriteLine($"[{e.Origin}] {payload.ContentType}: {Preview(payload)}");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[{e.Origin}] could not decrypt from {e.PeerDeviceId}: {ex.GetType().Name}");
    }
}

static string Preview(ClipboardPayload payload) =>
    payload.ContentType is ContentType.Text or ContentType.Link
        ? Encoding.UTF8.GetString(payload.Data)
        : $"{payload.Data.Length} bytes";
