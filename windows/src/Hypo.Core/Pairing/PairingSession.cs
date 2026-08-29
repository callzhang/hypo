using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Hypo.Core.Crypto;
using Hypo.Core.Protocol;

namespace Hypo.Core.Pairing;

/// <summary>A pairing that completed successfully.</summary>
public sealed record CompletedPairing
{
    public required string PeerDeviceId { get; init; }
    public required string PeerDeviceName { get; init; }
    public required byte[] SharedKey { get; init; }
}

/// <summary>The responder's result: the derived key plus the ack to send back.</summary>
public sealed record AcceptedChallenge
{
    public required string PeerDeviceId { get; init; }
    public required string PeerDeviceName { get; init; }
    public required byte[] SharedKey { get; init; }
    public required PairingAckMessage Ack { get; init; }
}

/// <summary>
/// One pairing attempt. The responder publishes its agreement public key first;
/// the initiator derives from it, sends a challenge, and the responder replies
/// with a hash of that challenge proving it decrypted it. The ack carries no
/// key — see the design spec section 4.2.
/// </summary>
public sealed class PairingSession
{
    /// <summary>Matches the replay window in protocol section 9.1.</summary>
    public static readonly TimeSpan MaxChallengeAge = TimeSpan.FromMinutes(5);

    private const int ChallengeSizeBytes = 32;

    private readonly string _deviceId;
    private readonly string _deviceName;
    private readonly byte[] _agreementPrivateKey;
    private readonly Func<DateTimeOffset> _clock;
    private readonly HashSet<Guid> _seenChallenges = [];

    private Guid _pendingChallengeId;
    private byte[]? _pendingChallenge;

    private PairingSession(string deviceId, string deviceName, Func<DateTimeOffset>? clock)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceName);

        _deviceId = deviceId.ToLowerInvariant();
        _deviceName = deviceName;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);

        // A fresh key per attempt. Re-pairing an already-known device does not
        // reuse the previous key; this is where forward secrecy comes from.
        _agreementPrivateKey = new byte[CryptoService.X25519KeySizeBytes];
        RandomNumberGenerator.Fill(_agreementPrivateKey);
    }

    /// <summary>Published to the peer before any challenge arrives.</summary>
    public byte[] AgreementPublicKey => CryptoService.DerivePublicKey(_agreementPrivateKey);

    public static PairingSession StartResponder(Guid deviceId, string deviceName, Func<DateTimeOffset>? clock = null) =>
        new(deviceId.ToString("D"), deviceName, clock);

    public static PairingSession StartInitiator(string deviceId, string deviceName, Func<DateTimeOffset>? clock = null) =>
        new(deviceId, deviceName, clock);

    public PairingChallengeMessage CreateChallenge(byte[] responderPublicKey)
    {
        ArgumentNullException.ThrowIfNull(responderPublicKey);

        var sharedKey = CryptoService.DeriveKey(_agreementPrivateKey, responderPublicKey);
        var challenge = new byte[ChallengeSizeBytes];
        RandomNumberGenerator.Fill(challenge);

        _pendingChallengeId = Guid.NewGuid();
        _pendingChallenge = challenge;

        var plaintext = JsonSerializer.SerializeToUtf8Bytes(
            new PairingChallengePayload { Challenge = challenge, Timestamp = _clock() },
            ProtocolJson.Options);

        var (ciphertext, tag) = Seal(plaintext, sharedKey, _deviceId, out var nonce);

        return new PairingChallengeMessage
        {
            ChallengeId = _pendingChallengeId,
            InitiatorDeviceId = _deviceId,
            InitiatorDeviceName = _deviceName,
            InitiatorPublicKey = AgreementPublicKey,
            Nonce = nonce,
            Ciphertext = ciphertext,
            Tag = tag,
        };
    }

    /// <summary>Returns null for anything that does not verify. A failed pairing is not an exception.</summary>
    public AcceptedChallenge? AcceptChallenge(PairingChallengeMessage message)
    {
        ArgumentNullException.ThrowIfNull(message);

        if (!_seenChallenges.Add(message.ChallengeId))
        {
            return null;
        }

        byte[] sharedKey;
        PairingChallengePayload payload;
        try
        {
            sharedKey = CryptoService.DeriveKey(_agreementPrivateKey, message.InitiatorPublicKey);
            var plaintext = CryptoService.Decrypt(
                message.Ciphertext, sharedKey, message.Nonce, message.Tag,
                Encoding.UTF8.GetBytes(message.InitiatorDeviceId.ToLowerInvariant()));
            payload = JsonSerializer.Deserialize<PairingChallengePayload>(plaintext, ProtocolJson.Options)!;
        }
        catch (Exception ex) when (ex is CryptographicException or JsonException or ArgumentException)
        {
            return null;
        }

        if (_clock() - payload.Timestamp > MaxChallengeAge)
        {
            return null;
        }

        var ackPlaintext = JsonSerializer.SerializeToUtf8Bytes(
            new PairingAckPayload { ResponseHash = SHA256.HashData(payload.Challenge), IssuedAt = _clock() },
            ProtocolJson.Options);

        var (ciphertext, tag) = Seal(ackPlaintext, sharedKey, _deviceId, out var nonce);

        return new AcceptedChallenge
        {
            PeerDeviceId = message.InitiatorDeviceId.ToLowerInvariant(),
            PeerDeviceName = message.InitiatorDeviceName,
            SharedKey = sharedKey,
            Ack = new PairingAckMessage
            {
                ChallengeId = message.ChallengeId,
                ResponderDeviceId = Guid.Parse(_deviceId),
                ResponderDeviceName = _deviceName,
                Nonce = nonce,
                Ciphertext = ciphertext,
                Tag = tag,
            },
        };
    }

    /// <summary>Returns null for anything that does not verify.</summary>
    public CompletedPairing? CompleteWithAck(PairingAckMessage ack, byte[] responderPublicKey)
    {
        ArgumentNullException.ThrowIfNull(ack);
        ArgumentNullException.ThrowIfNull(responderPublicKey);

        if (_pendingChallenge is null || ack.ChallengeId != _pendingChallengeId)
        {
            return null;
        }

        try
        {
            var sharedKey = CryptoService.DeriveKey(_agreementPrivateKey, responderPublicKey);
            var plaintext = CryptoService.Decrypt(
                ack.Ciphertext, sharedKey, ack.Nonce, ack.Tag,
                Encoding.UTF8.GetBytes(ack.ResponderDeviceId.ToString("D")));
            var payload = JsonSerializer.Deserialize<PairingAckPayload>(plaintext, ProtocolJson.Options)!;

            // Proves the responder decrypted our challenge rather than replaying
            // a well-formed message from some other exchange.
            if (!CryptographicOperations.FixedTimeEquals(
                    payload.ResponseHash, SHA256.HashData(_pendingChallenge)))
            {
                return null;
            }

            return new CompletedPairing
            {
                PeerDeviceId = ack.ResponderDeviceId.ToString("D"),
                PeerDeviceName = ack.ResponderDeviceName,
                SharedKey = sharedKey,
            };
        }
        catch (Exception ex) when (ex is CryptographicException or JsonException or ArgumentException)
        {
            return null;
        }
    }

    private static (byte[] Ciphertext, byte[] Tag) Seal(
        byte[] plaintext, byte[] key, string aadDeviceId, out byte[] nonce)
    {
        nonce = new byte[CryptoService.NonceSizeBytes];
        RandomNumberGenerator.Fill(nonce);
        return CryptoService.Encrypt(plaintext, key, nonce, Encoding.UTF8.GetBytes(aadDeviceId));
    }
}
