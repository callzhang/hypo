using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Hypo.Core.Abstractions;
using Hypo.Core.Crypto;
using Hypo.Core.Discovery;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;

// A development harness for exercising Hypo.Core against a real peer. Not a
// product: keys are written unencrypted under HYPO_STORE_DIR.
//
//   discover              list peers on this network
//   pair <device-id>      pair with one, then advertise and hold to receive.
//                         Set HYPO_SEND_TEXT to also push one text item.
//   listen                accept inbound connections and print what arrives

var command = args.Length > 0 ? args[0] : "discover";
var deviceId = Environment.GetEnvironmentVariable("HYPO_DEVICE_ID")
               ?? "11111111-2222-3333-4444-555555555555";
var deviceName = Environment.GetEnvironmentVariable("HYPO_DEVICE_NAME") ?? "Hypo Harness";

// Keys must outlive the process: we pair in one run and may receive in the next.
var storeDir = Environment.GetEnvironmentVariable("HYPO_STORE_DIR")
               ?? Path.Combine(Path.GetTempPath(), "hypo-harness-keys");
var store = new FileSecretStore(storeDir);

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
    case "cloud":
        await CloudAsync(args.ElementAtOrDefault(1), args.ElementAtOrDefault(2));
        break;
    case "sync":
        await SyncAsync(args.ElementAtOrDefault(1));
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

    // Through the shared coordinator rather than a second copy of the
    // handshake. Two implementations drift, and the one that drifts is the one
    // without the tests.
    var result = await new Hypo.Core.Pairing.LanPairingCoordinator(store)
        .PairAsync(peer, deviceId, deviceName);

    if (!result.Succeeded)
    {
        Console.WriteLine(result.Outcome switch
        {
            Hypo.Core.Pairing.PairingOutcome.PeerAdvertisesNoKey =>
                $"{peer.DisplayName} advertises no pub_key, so it cannot be paired with over the LAN.",
            Hypo.Core.Pairing.PairingOutcome.NoReply =>
                "No pairing reply arrived. That is all this says: the connection was accepted and "
                + "no parseable ack came back. Whether the peer never answered or answered in a "
                + "shape we dropped needs a probe that logs raw inbound frames.",
            _ => "Pairing failed: the ack did not verify.",
        });
        return;
    }

    Console.WriteLine($"Paired with {result.PeerDeviceName} ({result.PeerDeviceId}).");

    // Stay discoverable. The peer dials devices it has paired with and can see;
    // being paired is not enough on its own.
    await using var server = new LanWebSocketServer();
    server.EnvelopeReceived += (_, e) => PrintClipboard(e);
    await server.StartAsync();

    // A signing key we actually keep. Advertising the public half of a key
    // whose private half was discarded would leave us unable to sign anything
    // we claim to be able to sign.
    const string SigningKeyId = "local-signing-key";
    var signingPrivate = store.Read(SigningKeyId);
    if (signingPrivate is null)
    {
        signingPrivate = SigningService.GeneratePrivateKey();
        store.Write(SigningKeyId, signingPrivate);
    }

    var signingPublic = SigningService.DerivePublicKey(signingPrivate);

    // A persisted agreement key rather than the pairing session's ephemeral
    // one, which the coordinator owns and discards. Advertising a key that
    // changes every run makes this device look like a different peer each time.
    const string AgreementKeyId = "local-agreement-key";
    var agreementPrivate = store.Read(AgreementKeyId);
    if (agreementPrivate is null)
    {
        agreementPrivate = new byte[CryptoService.X25519KeySizeBytes];
        System.Security.Cryptography.RandomNumberGenerator.Fill(agreementPrivate);
        store.Write(AgreementKeyId, agreementPrivate);
    }

    var agreementPublic = CryptoService.DerivePublicKey(agreementPrivate);

    await using var advert = new MdnsPeerDiscovery();
    await advert.AdvertiseAsync(deviceName, server.BoundPort, new Dictionary<string, string>
    {
        ["device_id"] = deviceId,
        ["pub_key"] = Convert.ToBase64String(agreementPublic),
        ["signing_pub_key"] = Convert.ToBase64String(signingPublic),
        ["version"] = "3.0.0-harness",
        // SHA-256 of the agreement public key, matching what macOS publishes.
        ["fingerprint_sha256"] = Convert.ToHexString(
            System.Security.Cryptography.SHA256.HashData(agreementPublic)).ToLowerInvariant(),
    });

    Console.WriteLine($"Listening on {server.BoundPort} and advertising as \"{deviceName}\".");
    Console.WriteLine("Copy something on the peer; Ctrl+C to exit.");

    // Sending is folded into "pair" because the outbound direction needs a live
    // connection to the peer, which this command already holds.
    var outbound = Environment.GetEnvironmentVariable("HYPO_SEND_TEXT");
    if (!string.IsNullOrEmpty(outbound))
    {
        // A fresh connection: the pairing coordinator owns and closes the one it
        // used, which is the right boundary even though it costs a dial here.
        await using var sender = new LanWebSocketClient(peer, deviceId);
        await sender.ConnectAsync();
        await SendClipboardAsync(sender, store.Read(result.PeerDeviceId!)!, outbound);
        Console.WriteLine($"Sent {Encoding.UTF8.GetByteCount(outbound)} bytes of text to {result.PeerDeviceName}.");
    }

    await WaitForShutdownAsync();
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

    // The same persisted key `pair` uses. Generating a throwaway one here
    // advertises a signing public key whose private half is discarded when the
    // process exits -- we would be claiming an identity we cannot sign for, and
    // it would differ on every run.
    var signing = store.Read("local-signing-key");
    if (signing is null)
    {
        signing = SigningService.GeneratePrivateKey();
        store.Write("local-signing-key", signing);
    }

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
    await WaitForShutdownAsync();
}

/// <summary>
/// Connects to the relay and prints what arrives, the way `listen` does for
/// the LAN. No mDNS is started at all -- which is the point: if this receives
/// a message, it did not come over the LAN.
///
/// Usage: cloud [peer-device-id] [text-to-send]
/// </summary>
async Task CloudAsync(string? peerDeviceId, string? textToSend)
{
    var options = Hypo.Core.Relay.RelayOptions.FromEnvironment(
        deviceId, "windows", searchFrom: AppContext.BaseDirectory);

    await using var client = new CloudWebSocketClient(options);

    // Through the coordinator rather than decrypting inline, so what is being
    // tested is what will ship -- dedup included.
    using var history = new Hypo.Core.History.ClipboardHistoryStore(
        Path.Combine(storeDir, "history.db"));
    var clipboard = new Hypo.Harness.ConsoleClipboard();
    var coordinator = new Hypo.Core.Sync.SyncCoordinator(
        clipboard, client, store, history, deviceId, deviceName);
    coordinator.Applied += (_, entry) => Console.WriteLine(
        $"[applied] {entry.Content.ContentType} hash={entry.Content.LogHash} " +
        $"from={entry.SourceDeviceName ?? entry.SourceDeviceId}: " +
        $"{PreviewContent(entry.Content)}");
    coordinator.Dropped += (_, reason) => Console.WriteLine($"[dropped] {reason}");
    if (peerDeviceId is not null)
    {
        coordinator.Peers.Add(peerDeviceId);
    }

    client.RelayErrorReceived += (_, e) =>
        Console.WriteLine(
            $"[relay] {e.Error.Code}: {e.Error.Message} " +
            $"(connected: {string.Join(", ", e.Error.ConnectedDevices)})");
    client.StateChanged += (_, e) => Console.WriteLine($"[relay] {e.State}{(e.Error is null ? "" : $": {e.Error.Message}")}");

    await client.ConnectAsync();
    Console.WriteLine($"Connected to {options.Endpoint} as {deviceId}. No mDNS started.");

    if (peerDeviceId is not null && textToSend is not null)
    {
        var key = store.Read(peerDeviceId)
                  ?? throw new InvalidOperationException(
                      $"No key for {peerDeviceId}. Pair over the LAN first; the session key works on both transports.");

        var payload = new ClipboardPayload
        {
            ContentType = ContentType.Text,
            Data = Encoding.UTF8.GetBytes(textToSend),
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
                // Addressed rather than broadcast, so an offline peer produces
                // a visible error instead of silence.
                Target = peerDeviceId,
                Encryption = new EncryptionMetadata { Nonce = nonce, Tag = tag },
            },
        });

        Console.WriteLine($"Sent {Encoding.UTF8.GetByteCount(textToSend)} bytes to {peerDeviceId}.");
    }

    Console.WriteLine("Ctrl+C to exit.");
    await WaitForShutdownAsync();
}

/// <summary>
/// Runs the shipping client's composition -- LAN and relay together, through
/// HypoClient -- with a console clipboard standing in for the Windows one.
///
/// This is the only way the Windows client's wiring gets exercised anywhere: it
/// is the same object graph the application builds, and it can run here.
///
/// Usage: sync [text-to-send]
/// </summary>
async Task SyncAsync(string? textToSend)
{
    using var history = new Hypo.Core.History.ClipboardHistoryStore(
        Path.Combine(storeDir, "harness-history.db"));

    var clipboard = new Hypo.Harness.ConsoleClipboard();

    await using var client = Hypo.Core.Client.HypoClient.Create(
        clipboard,
        store,
        history,
        deviceId,
        deviceName,
        Hypo.Core.Relay.RelayOptions.FromEnvironment(
            deviceId, "windows", searchFrom: AppContext.BaseDirectory),
        lanPort: 0);

    client.Coordinator.Applied += (_, entry) => Console.WriteLine(
        $"[applied] {entry.Content.ContentType} hash={entry.Content.LogHash} " +
        $"from={entry.SourceDeviceName ?? entry.SourceDeviceId}: {PreviewContent(entry.Content)}");
    client.Coordinator.Dropped += (_, reason) => Console.WriteLine($"[dropped] {reason}");
    client.LanPeerConnected += (_, peer) => Console.WriteLine(
        $"[lan] {peer.DisplayName} id={peer.DeviceId} instance={peer.InstanceName} at {peer.Address}:{peer.Port}");
    client.RelayError += (_, e) => Console.WriteLine($"[relay] {e.Error.Code}: {e.Error.Message}");

    await client.StartAsync();

    var peers = Hypo.Core.Client.HypoClient.PairedPeers(store);
    Console.WriteLine($"Syncing as {deviceName} ({deviceId}) with {peers.Count} paired device(s).");

    if (!string.IsNullOrEmpty(textToSend))
    {
        // Through the clipboard, so the outbound path under test is the real one.
        await Task.Delay(TimeSpan.FromSeconds(6));
        Console.WriteLine($"[lan peers] {string.Join(", ", client.LanPeers)}");
        // A path means send that file; anything else is text. The harness exists
        // to exercise the real paths, and files had never been tried against a
        // real peer.
        var content = File.Exists(textToSend)
            ? new Hypo.Core.Sync.ClipboardContent
            {
                ContentType = ContentType.File,
                Data = File.ReadAllBytes(textToSend),
                Metadata = new Dictionary<string, string>
                {
                    ["file_name"] = Path.GetFileName(textToSend),
                    ["filename"] = Path.GetFileName(textToSend),
                },
            }
            : new Hypo.Core.Sync.ClipboardContent
            {
                ContentType = ContentType.Text,
                Data = Encoding.UTF8.GetBytes(textToSend),
            };

        clipboard.Copy(content);
        Console.WriteLine($"Copied {content.ContentType} ({content.Data.Length} bytes) locally.");
    }

    Console.WriteLine("Ctrl+C to exit.");
    await WaitForShutdownAsync();
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

        // The id and sender are printed because a duplicate is only diagnosable
        // with them: same id means one message on two paths, different ids mean
        // two messages, and dedup can only help with the first.
        Console.WriteLine(
            $"[{e.Origin}] {payload.ContentType} id={e.Envelope.Id} " +
            $"from={e.Envelope.Payload.DeviceName ?? e.Envelope.Payload.DeviceId}: {Preview(payload)}");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[{e.Origin}] could not decrypt from {e.PeerDeviceId}: {ex.GetType().Name}");
    }
}

/// <summary>
/// Blocks until the process is asked to stop, then returns so the caller's
/// `await using` scopes unwind and the mDNS advertiser is disposed.
///
/// Task.Delay(Timeout.Infinite) never returns, so nothing was ever disposed and
/// every run left a stale record behind — a peer that resolves one gets a dead
/// port and an obsolete key, and the symptom is silence, which is
/// indistinguishable from the bug you would then go hunting for.
///
/// PosixSignalRegistration rather than Console.CancelKeyPress alone:
/// CancelKeyPress does not fire for a process with no controlling terminal,
/// which is exactly how this gets run from a script.
/// </summary>
static Task WaitForShutdownAsync()
{
    var stopping = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

    void Stop(PosixSignalContext context)
    {
        context.Cancel = true;   // shut down cleanly instead of dying here
        stopping.TrySetResult();
    }

    var sigint = PosixSignalRegistration.Create(PosixSignal.SIGINT, Stop);
    var sigterm = PosixSignalRegistration.Create(PosixSignal.SIGTERM, Stop);

    return stopping.Task.ContinueWith(_ =>
    {
        sigint.Dispose();
        sigterm.Dispose();
    }, TaskScheduler.Default);
}

static string PreviewContent(Hypo.Core.Sync.ClipboardContent content) =>
    content.ContentType is ContentType.Text or ContentType.Link
        ? Encoding.UTF8.GetString(content.Data)
        : $"{content.Data.Length} bytes";

static string Preview(ClipboardPayload payload) =>
    payload.ContentType is ContentType.Text or ContentType.Link
        ? Encoding.UTF8.GetString(payload.Data)
        : $"{payload.Data.Length} bytes";
