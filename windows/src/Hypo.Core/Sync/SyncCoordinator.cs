using System.Security.Cryptography;
using System.Text.Json;
using Hypo.Core.Abstractions;
using Hypo.Core.Crypto;
using Hypo.Core.History;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;
using Hypo.Core.Utils;

namespace Hypo.Core.Sync;

/// <summary>
/// Joins the clipboard, the history and a transport.
///
/// <para>Outbound: a local copy is recorded, encrypted once per peer, and sent.
/// Inbound: a message is decrypted, deduplicated, recorded, and applied.</para>
///
/// <para>The coordinator never re-sends what it applied. <see cref="IClipboard"/>
/// promises not to raise a change for its own writes, and this class relies on
/// that promise rather than trying to recognise its own item after the fact --
/// which cannot be done reliably, because a peer may legitimately send back the
/// same content a moment later.</para>
/// </summary>
public sealed class SyncCoordinator
{
    private readonly IClipboard _clipboard;
    private readonly ISyncTransport _transport;
    private readonly ISecretStore _keys;
    private readonly ClipboardHistoryStore _history;
    private readonly ContentDeduplicator _dedup;
    private readonly TimeProvider _clock;
    private readonly string _deviceId;
    private readonly string _deviceName;

    public SyncCoordinator(
        IClipboard clipboard,
        ISyncTransport transport,
        ISecretStore keys,
        ClipboardHistoryStore history,
        string deviceId,
        string deviceName,
        ContentDeduplicator? dedup = null,
        TimeProvider? clock = null)
    {
        ArgumentNullException.ThrowIfNull(clipboard);
        ArgumentNullException.ThrowIfNull(transport);
        ArgumentNullException.ThrowIfNull(keys);
        ArgumentNullException.ThrowIfNull(history);
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceId);

        _clipboard = clipboard;
        _transport = transport;
        _keys = keys;
        _history = history;
        _deviceId = deviceId.ToLowerInvariant();
        _deviceName = deviceName;
        _clock = clock ?? TimeProvider.System;
        _dedup = dedup ?? new ContentDeduplicator(_clock);

        _clipboard.ContentChanged += OnLocalCopy;
        _transport.EnvelopeReceived += OnEnvelope;
    }

    /// <summary>Raised when a message is dropped, with a reason a human can act on.</summary>
    public event EventHandler<string>? Dropped;

    /// <summary>Raised after an inbound item has been applied.</summary>
    public event EventHandler<HistoryEntry>? Applied;

    /// <summary>Peers to address outbound copies to. Each gets its own encryption.</summary>
    public IList<string> Peers { get; } = [];

    public async Task SendAsync(ClipboardContent content, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(content);

        _history.Add(new HistoryEntry { Content = content, CopiedAt = _clock.GetUtcNow() });

        var body = GzipCompressor.Compress(JsonSerializer.SerializeToUtf8Bytes(
            new ClipboardPayload
            {
                ContentType = content.ContentType,
                Data = content.Data,
                Compressed = true,
            },
            ProtocolJson.Options));

        foreach (var peer in Peers.ToArray())
        {
            var key = _keys.Read(peer);
            if (key is null)
            {
                Dropped?.Invoke(this, $"No key for {peer}; pair with it first.");
                continue;
            }

            // A fresh nonce per message, per peer. Reuse under one key is
            // catastrophic -- see CryptoService.Encrypt's remarks -- and fanning
            // one item across several peers is exactly where a hoisted nonce
            // would look harmless.
            var nonce = new byte[CryptoService.NonceSizeBytes];
            RandomNumberGenerator.Fill(nonce);

            var (ciphertext, tag) = CryptoService.Encrypt(
                body, key, nonce, CryptoService.BuildAssociatedData(_deviceId));

            await _transport.SendAsync(
                new SyncEnvelope
                {
                    Id = Guid.NewGuid(),
                    Timestamp = _clock.GetUtcNow(),
                    Type = MessageType.Clipboard,
                    Payload = new EnvelopePayload
                    {
                        ContentType = content.ContentType,
                        Ciphertext = ciphertext,
                        DeviceId = _deviceId,
                        DevicePlatform = "windows",
                        DeviceName = _deviceName,
                        Target = peer,
                        Encryption = new EncryptionMetadata { Nonce = nonce, Tag = tag },
                    },
                },
                ct).ConfigureAwait(false);
        }
    }

    private void OnLocalCopy(object? sender, ClipboardContent content) =>
        _ = SendAsync(content);

    private void OnEnvelope(object? sender, EnvelopeReceivedEventArgs e) =>
        _ = ReceiveAsync(e);

    private async Task ReceiveAsync(EnvelopeReceivedEventArgs e)
    {
        var senderId = e.Envelope.Payload.DeviceId;
        var key = _keys.Read(senderId);

        if (key is null)
        {
            Dropped?.Invoke(this, $"No key for {senderId}; ignoring its message.");
            return;
        }

        ClipboardPayload payload;
        try
        {
            // The associated data is the sender's id. Decryption failing here
            // is the check that a peer claiming to be someone else in the body
            // does not get to speak for them.
            var plaintext = CryptoService.Decrypt(
                e.Envelope.Payload.Ciphertext,
                key,
                e.Envelope.Payload.Encryption.Nonce,
                e.Envelope.Payload.Encryption.Tag,
                CryptoService.BuildAssociatedData(senderId));

            payload = JsonSerializer.Deserialize<ClipboardPayload>(
                GzipCompressor.Decompress(plaintext), ProtocolJson.Options)!;
        }
        catch (Exception ex)
        {
            Dropped?.Invoke(this, $"Could not read a message from {senderId}: {ex.GetType().Name}.");
            return;
        }

        var content = new ClipboardContent { ContentType = payload.ContentType, Data = payload.Data };

        if (!_dedup.ShouldAccept(content))
        {
            Dropped?.Invoke(this, $"Duplicate of a recent item from {senderId} (hash={content.LogHash}).");
            return;
        }

        var entry = new HistoryEntry
        {
            Content = content,
            CopiedAt = _clock.GetUtcNow(),
            SourceDeviceId = senderId,
            SourceDeviceName = e.Envelope.Payload.DeviceName,
        };

        // Recorded before the clipboard write, deliberately. An item this machine
        // cannot put on its clipboard is still an item the peer sent, and losing
        // it from the history as well would make a partial capability look like a
        // dropped message.
        _history.Add(entry);

        try
        {
            await _clipboard.SetAsync(content).ConfigureAwait(false);
        }
        catch (NotSupportedException ex)
        {
            // A clipboard that cannot hold this content type -- images and files
            // on a build that only does text. It is in the history and the user
            // can still see it; what must not happen is this escaping into a
            // fire-and-forget task, where it becomes an unobserved exception and
            // the inbound path just stops working with nothing in the log.
            Dropped?.Invoke(
                this,
                $"Kept a {content.ContentType} item from {senderId} in history; " +
                $"this clipboard cannot hold it ({ex.Message}).");
            return;
        }
        catch (Exception ex)
        {
            Dropped?.Invoke(this, $"Could not write to the clipboard: {ex.GetType().Name}: {ex.Message}.");
            return;
        }

        Applied?.Invoke(this, entry);
    }
}
