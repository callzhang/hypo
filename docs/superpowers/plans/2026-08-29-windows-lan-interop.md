# Windows Client — Plan 2: LAN Interoperability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover a real macOS or Android Hypo peer on the local network, pair with it, and exchange a clipboard payload — proving the Windows client interoperates end to end.

**Architecture:** Plan 1 built `Hypo.Core`, which can encode, encrypt and frame protocol messages but cannot send them. This plan adds the pieces between that library and a socket: a streaming frame reader, an `ISyncTransport` abstraction, mDNS discovery, a LAN WebSocket client and server, Ed25519 pairing, and a console harness that ties them together. Still no Windows-specific API, no UI: everything here stays in `net10.0` so it can be developed and tested on any platform, and the harness runs anywhere.

**Tech Stack:** .NET 10, `Makaretu.Dns.Multicast`, `System.Net.WebSockets`, Kestrel, BouncyCastle (Ed25519), xUnit.

**Spec:** `docs/superpowers/specs/2026-08-28-windows-client-design.md` §3 (data flow), §4 (pairing), §7 (error handling).

**Prerequisite:** Plan 1, merged. `Hypo.Core` at 78 passing tests.

> **STATUS: INCOMPLETE — DO NOT EXECUTE PAST TASK 4.**
> Tasks 1 to 4 are written to this plan's own standard: failing test, complete
> implementation, exact commands, expected counts. Tasks 3–16 are currently only
> scoped, not written. A summarised task is a plan failure, not a shortcut — the
> whole reason Plan 1's subagents caught a JSON writer that escaped `+`, a
> converter override that was never invoked, and an associated-data formula that
> would have broken interoperability with both peer clients is that they were
> handed exact code to run and could watch it fail. Finish writing them before
> dispatching anyone past Task 4.

---

## What this plan is NOT

Deliberately deferred so this plan stays one coherent, testable milestone:

- **Cloud relay and `DualSyncTransport`.** LAN first: it is the path with a live peer to test against on the developer's own network. Cloud is Plan 3.
- **`TransportManager`.** Channel selection only matters once there are two channels.
- **SQLite `HistoryStore`.** The harness prints what it receives; persistence is Plan 3.
- **Everything Windows-specific.** Clipboard access, DPAPI, tray, UI, packaging remain Plans 4–6.

## Why LAN before cloud

Spec §11 named mDNS interoperability the project's highest risk. That risk is now retired — it was spiked against live macOS and Android peers before this plan was written (spec §4.2). Building LAN next capitalises on that: the developer's network already carries real peers to test against, so every task in this plan can be validated against a shipping client rather than a mock.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `windows/src/Hypo.Core/Protocol/FrameReader.cs` | Accumulates socket bytes, yields complete frames, reports bytes consumed |
| `windows/src/Hypo.Core/Transport/ISyncTransport.cs` | Connect / send / receive / disconnect contract |
| `windows/src/Hypo.Core/Transport/TransportEvents.cs` | Envelope-received and state-changed event payloads |
| `windows/src/Hypo.Core/Discovery/DnsSdName.cs` | DNS-SD instance-name escaping and unescaping |
| `windows/src/Hypo.Core/Discovery/DiscoveredPeer.cs` | Peer record: instance name, host, port, TXT properties |
| `windows/src/Hypo.Core/Discovery/IPeerDiscovery.cs` | Publish and browse contract |
| `windows/src/Hypo.Core/Discovery/MdnsPeerDiscovery.cs` | `Makaretu.Dns.Multicast` implementation |
| `windows/src/Hypo.Core/Transport/LanWebSocketClient.cs` | Dials `ws://host:port`, framed send and receive |
| `windows/src/Hypo.Core/Transport/LanWebSocketServer.cs` | Kestrel listener accepting peer connections |
| `windows/src/Hypo.Core/Pairing/PairingMessages.cs` | Challenge and Ack wire models |
| `windows/src/Hypo.Core/Pairing/PairingSession.cs` | Challenge and Ack exchange, key derivation |
| `windows/src/Hypo.Core/Crypto/SigningService.cs` | Ed25519 sign and verify |
| `windows/tests/Hypo.Core.Tests/*` | One test file per unit |
| `windows/tools/Hypo.Harness/` | Console harness — discover, pair, send, receive |

`Discovery/` and `Pairing/` are new folders alongside the existing `Protocol/`, `Crypto/`, `Transport/` and `Abstractions/`. `Transport/` gains the socket types that Plan 1 deliberately left out.

---

## Interoperability facts this plan depends on

Every one of these was measured against the shipping clients rather than taken from documentation. They are repeated here because getting any of them wrong produces a client that fails silently.

| Fact | Source |
|------|--------|
| LAN transport is plain `ws://`. `protocols=ws+tls` in the TXT record is false advertising — no client implements TLS on LAN | `LanSyncTransport.swift:137`, `LanWebSocketServer.swift:151` |
| Frames are a 4-byte big-endian length prefix plus JSON | Plan 1, `TransportFrameCodec` |
| The device id travels on the `X-Device-Id` header **or** a `?device_id=` query parameter; the macOS server accepts either | `LanWebSocketServer.swift:465-470` |
| The TXT record carries `device_id`, `pub_key`, `signing_pub_key`, `version`, `fingerprint_sha256`, `protocols` | Spec §4.2, measured |
| `device_name` is never published, so display names come from the DNS-SD instance name | `BonjourPublisher.swift` |
| Instance names arrive DNS-escaped (`\032` is a space) | Spec §4.2, measured |
| `ServiceInstanceDiscovered` fires for every service type, not only the queried one | Spec §4.2, measured |
| Associated data for AES-GCM is the lowercased sender device id alone | Plan 1, `CryptoService.BuildAssociatedData` |
| `challenge_id` is lowercase; device ids are bare lowercase UUIDs | `docs/protocol.md`, Plan 1 §4.4 |
| Keys rotate on every pairing, including re-pairing | `docs/protocol.md` §9.2 |

---

## Task 1: Streaming frame reader

Plan 1's `TransportFrameCodec.Decode` takes one complete frame and ignores trailing bytes. A socket delivers partial and coalesced frames, so the codec needs a companion that owns the buffering. This is carry-forward item 1 from Plan 1.

**Files:**
- Create: `windows/src/Hypo.Core/Protocol/FrameReader.cs`
- Test: `windows/tests/Hypo.Core.Tests/FrameReaderTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/FrameReaderTests.cs`:

```csharp
using System.Buffers.Binary;
using System.Text;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class FrameReaderTests
{
    private static byte[] Frame(string body)
    {
        var payload = Encoding.UTF8.GetBytes(body);
        var frame = new byte[4 + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(0, 4), (uint)payload.Length);
        payload.CopyTo(frame.AsSpan(4));
        return frame;
    }

    [Fact]
    public void YieldsNothingUntilAWholeFrameHasArrived()
    {
        var reader = new FrameReader();
        var frame = Frame("hello");

        Assert.Empty(reader.Append(frame.AsSpan(0, 3).ToArray()));
        Assert.Empty(reader.Append(frame.AsSpan(3, 4).ToArray()));

        var completed = reader.Append(frame.AsSpan(7).ToArray());

        Assert.Single(completed);
        Assert.Equal("hello", Encoding.UTF8.GetString(completed[0]));
    }

    [Fact]
    public void YieldsEveryFrameFromACoalescedRead()
    {
        var reader = new FrameReader();
        var buffer = Frame("one").Concat(Frame("two")).Concat(Frame("three")).ToArray();

        var completed = reader.Append(buffer);

        Assert.Equal(["one", "two", "three"], completed.Select(f => Encoding.UTF8.GetString(f)));
    }

    [Fact]
    public void KeepsAPartialTrailingFrameForTheNextRead()
    {
        var reader = new FrameReader();
        var whole = Frame("one");
        var partial = Frame("two");

        var first = reader.Append(whole.Concat(partial.Take(5)).ToArray());
        Assert.Single(first);

        var second = reader.Append(partial.Skip(5).ToArray());
        Assert.Single(second);
        Assert.Equal("two", Encoding.UTF8.GetString(second[0]));
    }

    [Fact]
    public void RejectsALengthPrefixAboveTheCeiling()
    {
        var reader = new FrameReader(maxFrameBytes: 16);
        var prefix = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(prefix, 17);

        var error = Assert.Throws<TransportFrameException>(() => reader.Append(prefix));

        Assert.Equal(TransportFrameError.PayloadTooLarge, error.Error);
    }

    [Fact]
    public void RejectsAUIntMaxValueLengthPrefix()
    {
        var reader = new FrameReader();

        var error = Assert.Throws<TransportFrameException>(
            () => reader.Append([0xFF, 0xFF, 0xFF, 0xFF]));

        Assert.Equal(TransportFrameError.PayloadTooLarge, error.Error);
    }

    [Fact]
    public void HandlesAZeroLengthFrame()
    {
        var reader = new FrameReader();

        var completed = reader.Append([0x00, 0x00, 0x00, 0x00]);

        Assert.Single(completed);
        Assert.Empty(completed[0]);
    }

    [Fact]
    public void ResetDiscardsBufferedBytes()
    {
        var reader = new FrameReader();
        reader.Append(Frame("hello").AsSpan(0, 5).ToArray());

        reader.Reset();

        Assert.Empty(reader.Append(Frame("x")).Where(f => Encoding.UTF8.GetString(f) != "x"));
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~FrameReaderTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'FrameReader' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Protocol/FrameReader.cs`:

```csharp
using System.Buffers.Binary;

namespace Hypo.Core.Protocol;

/// <summary>
/// Accumulates bytes from a stream and yields complete frame bodies. A socket
/// read gives neither one frame nor a whole frame, so the buffering has to live
/// somewhere; TransportFrameCodec deliberately stays a pure function over one
/// complete frame.
/// </summary>
public sealed class FrameReader
{
    private const int LengthPrefixBytes = 4;

    private readonly int _maxFrameBytes;
    private readonly MemoryStream _buffer = new();

    public FrameReader(int maxFrameBytes = TransportFrameCodec.DefaultMaxPayloadBytes)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxFrameBytes);
        _maxFrameBytes = maxFrameBytes;
    }

    /// <summary>Bytes currently held back waiting for the rest of a frame.</summary>
    public int Buffered => (int)_buffer.Length;

    /// <summary>
    /// Adds bytes and returns every frame body completed by them, in order.
    /// </summary>
    /// <exception cref="TransportFrameException">
    /// A length prefix exceeds the ceiling. The connection is not recoverable
    /// after this: the stream position is no longer trustworthy.
    /// </exception>
    public IReadOnlyList<byte[]> Append(ReadOnlySpan<byte> bytes)
    {
        _buffer.Seek(0, SeekOrigin.End);
        _buffer.Write(bytes);

        var data = _buffer.GetBuffer().AsSpan(0, (int)_buffer.Length);
        var completed = new List<byte[]>();
        var offset = 0;

        while (data.Length - offset >= LengthPrefixBytes)
        {
            var declared = BinaryPrimitives.ReadUInt32BigEndian(data.Slice(offset, LengthPrefixBytes));
            if (declared > _maxFrameBytes)
            {
                throw new TransportFrameException(
                    TransportFrameError.PayloadTooLarge,
                    $"Peer declared a {declared} byte frame, exceeding the {_maxFrameBytes} byte ceiling.");
            }

            var total = LengthPrefixBytes + (int)declared;
            if (data.Length - offset < total)
            {
                break;
            }

            completed.Add(data.Slice(offset + LengthPrefixBytes, (int)declared).ToArray());
            offset += total;
        }

        Compact(offset);
        return completed;
    }

    /// <summary>Discards buffered bytes. Call on reconnect.</summary>
    public void Reset() => _buffer.SetLength(0);

    private void Compact(int consumed)
    {
        if (consumed == 0)
        {
            return;
        }

        var remaining = (int)_buffer.Length - consumed;
        if (remaining > 0)
        {
            var raw = _buffer.GetBuffer();
            Array.Copy(raw, consumed, raw, 0, remaining);
        }

        _buffer.SetLength(remaining);
    }
}
```

The ceiling check happens before the completeness check so a hostile prefix is rejected without waiting for bytes that will never come.

- [ ] **Step 4: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~FrameReaderTests`

Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Protocol/FrameReader.cs windows/tests/Hypo.Core.Tests/FrameReaderTests.cs
git commit -m "feat(windows): add a streaming frame reader"
```

---

## Task 2: DNS-SD name escaping

The spike measured that a real peer's instance name arrives as `derek\8217s\032MacBook\032Air\032(2)`. Showing that to a user is unacceptable, and the escaping is the only source of a peer's display name because `device_name` is never published.

**Files:**
- Create: `windows/src/Hypo.Core/Discovery/DnsSdName.cs`
- Test: `windows/tests/Hypo.Core.Tests/DnsSdNameTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/DnsSdNameTests.cs`:

```csharp
using Hypo.Core.Discovery;

namespace Hypo.Core.Tests;

public class DnsSdNameTests
{
    [Theory]
    // Measured from live peers on a real network.
    [InlineData(@"derek\8217s\032MacBook\032Air\032(2)", "derek’s MacBook Air (2)")]
    [InlineData(@"OPPO\032PLP110", "OPPO PLP110")]
    [InlineData("HypoWindowsProbe", "HypoWindowsProbe")]
    [InlineData(@"a\.b", "a.b")]
    [InlineData(@"back\\slash", @"back\slash")]
    public void UnescapesInstanceNames(string wire, string expected)
    {
        Assert.Equal(expected, DnsSdName.Unescape(wire));
    }

    [Fact]
    public void StripsTheServiceTypeSuffix()
    {
        Assert.Equal(
            "OPPO PLP110",
            DnsSdName.InstanceLabel(@"OPPO\032PLP110._hypo._tcp.local", "_hypo._tcp.local"));
    }

    [Fact]
    public void LeavesANameWithoutTheSuffixAlone()
    {
        Assert.Equal("Something", DnsSdName.InstanceLabel("Something", "_hypo._tcp.local"));
    }

    [Fact]
    public void ToleratesATrailingBackslash()
    {
        Assert.Equal(@"odd\", DnsSdName.Unescape(@"odd\"));
    }

    [Fact]
    public void ToleratesAnIncompleteDecimalEscape()
    {
        // Not three digits, so it is a literal escape of '0'.
        Assert.Equal("0", DnsSdName.Unescape(@"\0"));
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~DnsSdNameTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'Hypo.Core.Discovery' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Discovery/DnsSdName.cs`:

```csharp
using System.Text;

namespace Hypo.Core.Discovery;

/// <summary>
/// DNS-SD instance names arrive escaped per RFC 1035: a backslash followed by
/// three decimal digits is a byte value, and a backslash before any other
/// character escapes it literally. Measured examples from live peers include
/// "derek\8217s\032MacBook\032Air\032(2)".
/// </summary>
public static class DnsSdName
{
    public static string Unescape(string value)
    {
        ArgumentNullException.ThrowIfNull(value);

        var sb = new StringBuilder(value.Length);
        for (var i = 0; i < value.Length; i++)
        {
            if (value[i] != '\\')
            {
                sb.Append(value[i]);
                continue;
            }

            if (i + 1 >= value.Length)
            {
                sb.Append('\\');
                break;
            }

            var digits = 0;
            while (digits < 4 && i + 1 + digits < value.Length && char.IsAsciiDigit(value[i + 1 + digits]))
            {
                digits++;
            }

            if (digits >= 3)
            {
                sb.Append((char)int.Parse(value.AsSpan(i + 1, digits)));
                i += digits;
            }
            else
            {
                sb.Append(value[i + 1]);
                i++;
            }
        }

        return sb.ToString();
    }

    /// <summary>Unescaped instance label with the service type suffix removed.</summary>
    public static string InstanceLabel(string fullName, string serviceType)
    {
        ArgumentNullException.ThrowIfNull(fullName);
        ArgumentNullException.ThrowIfNull(serviceType);

        var suffix = "." + serviceType.TrimStart('.');
        var label = fullName.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)
            ? fullName[..^suffix.Length]
            : fullName;

        return Unescape(label);
    }
}
```

Names longer than three digits appear because Bonjour emits the code point rather than a byte for non-ASCII, as in `\8217` for a right single quote — hence accepting up to four digits.

- [ ] **Step 4: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~DnsSdNameTests`

Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Discovery/DnsSdName.cs windows/tests/Hypo.Core.Tests/DnsSdNameTests.cs
git commit -m "feat(windows): unescape DNS-SD instance names"
```

---

## Task 3: The peer record and the discovery contract

**Files:**
- Create: `windows/src/Hypo.Core/Discovery/DiscoveredPeer.cs`
- Create: `windows/src/Hypo.Core/Discovery/IPeerDiscovery.cs`
- Test: `windows/tests/Hypo.Core.Tests/DiscoveredPeerTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/DiscoveredPeerTests.cs`:

```csharp
using Hypo.Core.Discovery;

namespace Hypo.Core.Tests;

public class DiscoveredPeerTests
{
    // Exactly what a live macOS peer advertised, measured on a real network.
    private static readonly Dictionary<string, string> MacOsTxt = new()
    {
        ["signing_pub_key"] = "S4ItgzBJTsac1lN8T05Zpk7ZvudGjYKycnOTEheTzsg=",
        ["device_id"] = "007e4a95-0e1a-4b10-91fa-87942efaa68e",
        ["pub_key"] = "0KWinOak3zMKXjQg4K1f7TWdypF0oDb32e5fOnzjuX4=",
        ["version"] = "1.1.6",
        ["fingerprint_sha256"] = "259a3c4c3f4d1288fb15def2db2655aeac4bbe0575d8b756c053d4d369a76b34",
        ["protocols"] = "ws+tls",
    };

    private static DiscoveredPeer MacOsPeer() => DiscoveredPeer.FromTxt(
        instanceName: @"derek\8217s\032MacBook\032Air\032(2)._hypo._tcp.local",
        host: "4efa9cc4-2ea7-468c-9b64-7087849da0b4.local",
        address: "10.0.0.252",
        port: 7010,
        txt: MacOsTxt);

    [Fact]
    public void ExposesTheUnescapedDisplayName()
    {
        Assert.Equal("derek’s MacBook Air (2)", MacOsPeer().DisplayName);
    }

    [Fact]
    public void ParsesTheTypedTxtProperties()
    {
        var peer = MacOsPeer();

        Assert.Equal("007e4a95-0e1a-4b10-91fa-87942efaa68e", peer.DeviceId);
        Assert.Equal(32, peer.PublicKey!.Length);
        Assert.Equal(32, peer.SigningPublicKey!.Length);
        Assert.Equal("1.1.6", peer.Version);
    }

    [Fact]
    public void LowercasesTheDeviceId()
    {
        var txt = new Dictionary<string, string>(MacOsTxt)
        {
            ["device_id"] = "007E4A95-0E1A-4B10-91FA-87942EFAA68E",
        };

        var peer = DiscoveredPeer.FromTxt("x._hypo._tcp.local", "h", "1.2.3.4", 7010, txt);

        Assert.Equal("007e4a95-0e1a-4b10-91fa-87942efaa68e", peer.DeviceId);
    }

    [Fact]
    public void IgnoresTheAdvertisedProtocolsField()
    {
        // Both shipping clients announce ws+tls and neither implements TLS.
        // Honouring it would make every connection fail, so it is not surfaced
        // as anything a caller can act on.
        Assert.Null(typeof(DiscoveredPeer).GetProperty("Protocols"));
        Assert.Equal("ws+tls", MacOsPeer().Txt["protocols"]);
    }

    [Fact]
    public void ToleratesAPeerAdvertisingNoPairingKeys()
    {
        var peer = DiscoveredPeer.FromTxt(
            "x._hypo._tcp.local", "h", "1.2.3.4", 7010, new Dictionary<string, string>());

        Assert.Null(peer.DeviceId);
        Assert.Null(peer.PublicKey);
        Assert.Null(peer.SigningPublicKey);
        Assert.Equal("x", peer.DisplayName);
    }

    [Fact]
    public void ToleratesAMalformedKey()
    {
        var txt = new Dictionary<string, string> { ["pub_key"] = "not base64!" };

        var peer = DiscoveredPeer.FromTxt("x._hypo._tcp.local", "h", "1.2.3.4", 7010, txt);

        Assert.Null(peer.PublicKey);
    }

    [Fact]
    public void BuildsTheWebSocketUriFromTheAddressNotTheHostname()
    {
        // The macOS peer advertises its device UUID as a .local hostname, which
        // needs mDNS resolution to reach. The A record is already in hand.
        Assert.Equal("ws://10.0.0.252:7010/", MacOsPeer().WebSocketUri.ToString());
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~DiscoveredPeerTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'DiscoveredPeer' could not be found`.

- [ ] **Step 3: Write `DiscoveredPeer`**

Create `windows/src/Hypo.Core/Discovery/DiscoveredPeer.cs`:

```csharp
using Hypo.Core.Protocol;

namespace Hypo.Core.Discovery;

/// <summary>
/// A peer found over mDNS. The TXT schema was measured against live macOS and
/// Android clients; see the design spec section 4.2.
/// </summary>
public sealed record DiscoveredPeer
{
    public const string ServiceType = "_hypo._tcp.local";

    public required string InstanceName { get; init; }
    public required string DisplayName { get; init; }
    public required string Host { get; init; }
    public required string Address { get; init; }
    public required int Port { get; init; }
    public required IReadOnlyDictionary<string, string> Txt { get; init; }

    public string? DeviceId { get; init; }
    public byte[]? PublicKey { get; init; }
    public byte[]? SigningPublicKey { get; init; }
    public string? Version { get; init; }

    /// <summary>
    /// Built from the A record rather than the advertised hostname, which on
    /// macOS is a .local name that would need resolving again. Always ws://:
    /// the advertised "protocols=ws+tls" is not implemented by any client.
    /// </summary>
    public Uri WebSocketUri => new($"ws://{Address}:{Port}/");

    public static DiscoveredPeer FromTxt(
        string instanceName,
        string host,
        string address,
        int port,
        IReadOnlyDictionary<string, string> txt)
    {
        ArgumentNullException.ThrowIfNull(txt);

        return new DiscoveredPeer
        {
            InstanceName = instanceName,
            DisplayName = DnsSdName.InstanceLabel(instanceName, ServiceType),
            Host = host,
            Address = address,
            Port = port,
            Txt = txt,
            DeviceId = txt.TryGetValue("device_id", out var id) ? id.ToLowerInvariant() : null,
            PublicKey = TryKey(txt, "pub_key"),
            SigningPublicKey = TryKey(txt, "signing_pub_key"),
            Version = txt.GetValueOrDefault("version"),
        };
    }

    private static byte[]? TryKey(IReadOnlyDictionary<string, string> txt, string key)
    {
        if (!txt.TryGetValue(key, out var value))
        {
            return null;
        }

        try
        {
            return Base64Compat.Decode(value);
        }
        catch (FormatException)
        {
            // A peer advertising a malformed key is not a reason to hide it from
            // the device list; pairing will fail later with a clearer message.
            return null;
        }
    }
}
```

- [ ] **Step 4: Write `IPeerDiscovery`**

Create `windows/src/Hypo.Core/Discovery/IPeerDiscovery.cs`:

```csharp
namespace Hypo.Core.Discovery;

/// <summary>Publishes this device and watches for peers on the local network.</summary>
public interface IPeerDiscovery : IAsyncDisposable
{
    /// <summary>Raised when a peer is first seen or its record changes.</summary>
    event EventHandler<DiscoveredPeer>? PeerDiscovered;

    /// <summary>Raised when a peer withdraws its advertisement.</summary>
    event EventHandler<string>? PeerLost;

    /// <summary>
    /// Advertises this device. The port must be the port actually bound, not the
    /// configured one — the server falls back to an ephemeral port when 7010 is
    /// taken, and a peer that dials the wrong port simply never connects.
    /// </summary>
    Task AdvertiseAsync(string deviceName, int port, IReadOnlyDictionary<string, string> txt, CancellationToken ct = default);

    Task StartBrowsingAsync(CancellationToken ct = default);

    IReadOnlyCollection<DiscoveredPeer> KnownPeers { get; }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~DiscoveredPeerTests`

Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add windows/src/Hypo.Core/Discovery/DiscoveredPeer.cs windows/src/Hypo.Core/Discovery/IPeerDiscovery.cs windows/tests/Hypo.Core.Tests/DiscoveredPeerTests.cs
git commit -m "feat(windows): model a discovered LAN peer"
```

---

## Task 4: mDNS discovery

The one dependency spec section 11 called the project's highest risk. It is
already spiked against live peers, so this task is transcribing verified code
rather than exploring.

**Files:**
- Create: `windows/src/Hypo.Core/Discovery/MdnsPeerDiscovery.cs`
- Test: `windows/tests/Hypo.Core.Tests/MdnsPeerDiscoveryTests.cs`

- [ ] **Step 1: Write the failing test**

These tests exercise the record-correlation logic without touching a network.
Live-network behaviour is Task 5, which is opt-in.

Create `windows/tests/Hypo.Core.Tests/MdnsPeerDiscoveryTests.cs`:

```csharp
using Hypo.Core.Discovery;

namespace Hypo.Core.Tests;

public class MdnsPeerDiscoveryTests
{
    [Fact]
    public void IgnoresInstancesOfOtherServiceTypes()
    {
        // ServiceInstanceDiscovered fires for every service on the network; the
        // spike saw AirPlay, Spotify Connect and Roku. Without this filter the
        // device list fills with televisions.
        Assert.False(MdnsPeerDiscovery.IsHypoInstance("65in TCL Roku TV._airplay._tcp.local"));
        Assert.False(MdnsPeerDiscovery.IsHypoInstance("x._spotify-connect._tcp.local"));
        Assert.True(MdnsPeerDiscovery.IsHypoInstance("OPPO PLP110._hypo._tcp.local"));
    }

    [Fact]
    public void MatchesTheServiceTypeCaseInsensitively()
    {
        Assert.True(MdnsPeerDiscovery.IsHypoInstance("X._HYPO._TCP.LOCAL"));
    }

    [Fact]
    public void BuildsAPeerOnlyWhenSrvAndAddressAreBothKnown()
    {
        var records = new MdnsRecordSet();
        var instance = "OPPO PLP110._hypo._tcp.local";

        Assert.Null(records.TryBuildPeer(instance));

        records.NoteSrv(instance, "Android_TCDVBQQI.local", 7010);
        Assert.Null(records.TryBuildPeer(instance));

        records.NoteAddress("Android_TCDVBQQI.local", "10.0.0.17");
        var peer = records.TryBuildPeer(instance);

        Assert.NotNull(peer);
        Assert.Equal("10.0.0.17", peer.Address);
        Assert.Equal(7010, peer.Port);
    }

    [Fact]
    public void CarriesTxtPropertiesOntoThePeer()
    {
        var records = new MdnsRecordSet();
        var instance = "OPPO PLP110._hypo._tcp.local";
        records.NoteSrv(instance, "h.local", 7010);
        records.NoteAddress("h.local", "10.0.0.17");
        records.NoteTxt(instance, new Dictionary<string, string>
        {
            ["device_id"] = "BBE296D6-0785-43D2-91B6-B135B72F4C41",
            ["pub_key"] = "ZuPQTwT2QainOfqI5TikmthXtYGM6ENfrtH3szCnfEo=",
        });

        var peer = records.TryBuildPeer(instance)!;

        Assert.Equal("bbe296d6-0785-43d2-91b6-b135b72f4c41", peer.DeviceId);
        Assert.Equal(32, peer.PublicKey!.Length);
    }

    [Fact]
    public void ALaterSrvRecordReplacesAnEarlierOne()
    {
        // A peer that changes IP re-announces; the newest record wins.
        var records = new MdnsRecordSet();
        var instance = "x._hypo._tcp.local";
        records.NoteSrv(instance, "old.local", 7010);
        records.NoteAddress("old.local", "10.0.0.5");
        records.NoteSrv(instance, "new.local", 7011);
        records.NoteAddress("new.local", "10.0.0.6");

        var peer = records.TryBuildPeer(instance)!;

        Assert.Equal("10.0.0.6", peer.Address);
        Assert.Equal(7011, peer.Port);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~MdnsPeerDiscoveryTests`

Expected: FAIL to compile with `CS0246` for `MdnsPeerDiscovery` and `MdnsRecordSet`.

- [ ] **Step 3: Add the package**

```bash
cd windows
dotnet add src/Hypo.Core/Hypo.Core.csproj package Makaretu.Dns.Multicast
```

Version 0.27.0 is what the spike validated against macOS and Android peers.

- [ ] **Step 4: Write the implementation**

Create `windows/src/Hypo.Core/Discovery/MdnsPeerDiscovery.cs`:

```csharp
using Makaretu.Dns;

namespace Hypo.Core.Discovery;

/// <summary>
/// Correlates the SRV, A and TXT records that arrive separately for one peer.
/// Split out from the network plumbing so it can be tested without multicast.
/// </summary>
public sealed class MdnsRecordSet
{
    private readonly Dictionary<string, (string Host, int Port)> _srv = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _address = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, IReadOnlyDictionary<string, string>> _txt = new(StringComparer.OrdinalIgnoreCase);

    public void NoteSrv(string instance, string host, int port) => _srv[instance] = (host, port);

    public void NoteAddress(string host, string address) => _address[host] = address;

    public void NoteTxt(string instance, IReadOnlyDictionary<string, string> txt) => _txt[instance] = txt;

    /// <summary>
    /// Returns a peer once both its SRV record and the A record for that SRV
    /// target have arrived. TXT is optional: a peer with no pairing keys is
    /// still worth showing, it just cannot be paired with yet.
    /// </summary>
    public DiscoveredPeer? TryBuildPeer(string instance)
    {
        if (!_srv.TryGetValue(instance, out var srv) ||
            !_address.TryGetValue(srv.Host, out var address))
        {
            return null;
        }

        var txt = _txt.TryGetValue(instance, out var t)
            ? t
            : new Dictionary<string, string>();

        return DiscoveredPeer.FromTxt(instance, srv.Host, address, srv.Port, txt);
    }
}

/// <summary>
/// Publishes this device and browses for peers over mDNS. Validated against
/// live macOS and Android clients; see the design spec section 4.2.
/// </summary>
public sealed class MdnsPeerDiscovery : IPeerDiscovery
{
    private const string QueryName = "_hypo._tcp";

    private readonly MulticastService _mdns = new();
    private readonly ServiceDiscovery _sd;
    private readonly MdnsRecordSet _records = new();
    private readonly Dictionary<string, DiscoveredPeer> _peers = new(StringComparer.OrdinalIgnoreCase);
    private readonly Lock _gate = new();

    private ServiceProfile? _advertised;
    private bool _started;

    public MdnsPeerDiscovery()
    {
        // AnswerReceived lives on MulticastService, not ServiceDiscovery, so the
        // two have to be constructed separately and the service passed in.
        _sd = new ServiceDiscovery(_mdns);
        _mdns.AnswerReceived += OnAnswer;
    }

    public event EventHandler<DiscoveredPeer>? PeerDiscovered;
    public event EventHandler<string>? PeerLost;

    public IReadOnlyCollection<DiscoveredPeer> KnownPeers
    {
        get { lock (_gate) { return _peers.Values.ToArray(); } }
    }

    public static bool IsHypoInstance(string instanceName) =>
        instanceName.EndsWith(DiscoveredPeer.ServiceType, StringComparison.OrdinalIgnoreCase);

    public Task AdvertiseAsync(
        string deviceName,
        int port,
        IReadOnlyDictionary<string, string> txt,
        CancellationToken ct = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(port);

        var profile = new ServiceProfile(deviceName, QueryName, (ushort)port);
        foreach (var (key, value) in txt)
        {
            profile.AddProperty(key, value);
        }

        _advertised = profile;
        EnsureStarted();
        _sd.Advertise(profile);
        _sd.Announce(profile);
        return Task.CompletedTask;
    }

    public Task StartBrowsingAsync(CancellationToken ct = default)
    {
        EnsureStarted();
        _sd.QueryServiceInstances(QueryName);
        return Task.CompletedTask;
    }

    /// <summary>Re-sends the query. Peers that started late answer this one.</summary>
    public void Refresh() => _sd.QueryServiceInstances(QueryName);

    private void EnsureStarted()
    {
        if (_started)
        {
            return;
        }

        _mdns.Start();
        _started = true;
    }

    private void OnAnswer(object? sender, MessageEventArgs e)
    {
        var changed = new List<DiscoveredPeer>();

        lock (_gate)
        {
            foreach (var record in e.Message.Answers.Concat(e.Message.AdditionalRecords))
            {
                var name = record.Name.ToString();
                switch (record)
                {
                    case SRVRecord srv when IsHypoInstance(name):
                        _records.NoteSrv(name, srv.Target.ToString(), srv.Port);
                        break;
                    case TXTRecord txt when IsHypoInstance(name):
                        _records.NoteTxt(name, ParseTxt(txt));
                        break;
                    case ARecord a:
                        _records.NoteAddress(name, a.Address.ToString());
                        break;
                }
            }

            foreach (var instance in e.Message.Answers
                         .Concat(e.Message.AdditionalRecords)
                         .Select(r => r.Name.ToString())
                         .Where(IsHypoInstance)
                         .Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var peer = _records.TryBuildPeer(instance);
                if (peer is null)
                {
                    continue;
                }

                if (!_peers.TryGetValue(instance, out var existing) || existing != peer)
                {
                    _peers[instance] = peer;
                    changed.Add(peer);
                }
            }
        }

        foreach (var peer in changed)
        {
            PeerDiscovered?.Invoke(this, peer);
        }
    }

    private static Dictionary<string, string> ParseTxt(TXTRecord record)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in record.Strings)
        {
            var split = entry.IndexOf('=');
            if (split > 0)
            {
                result[entry[..split]] = entry[(split + 1)..];
            }
        }

        return result;
    }

    public ValueTask DisposeAsync()
    {
        _mdns.AnswerReceived -= OnAnswer;
        if (_advertised is not null)
        {
            _sd.Unadvertise(_advertised);
        }

        _sd.Dispose();
        _mdns.Dispose();
        return ValueTask.CompletedTask;
    }
}
```

`PeerLost` is declared but never raised here. Makaretu surfaces goodbye packets
inconsistently across platforms, and a peer that stops answering is
indistinguishable from one on a flaky network. Plan 3 adds staleness eviction
driven by a last-seen timestamp, which is what the macOS client does.

- [ ] **Step 5: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~MdnsPeerDiscoveryTests`

Expected: PASS, 5 tests.

- [ ] **Step 6: Confirm the core layer is still platform-neutral**

Run: `cd windows && dotnet build`

Expected: `Build succeeded` with 0 warnings. A warning here would most likely be
`CA1416`, meaning the new package pulled in a Windows-only API and the
dependency rule has been broken.

- [ ] **Step 7: Commit**

```bash
git add windows/src/Hypo.Core/Discovery/MdnsPeerDiscovery.cs windows/tests/Hypo.Core.Tests/MdnsPeerDiscoveryTests.cs windows/src/Hypo.Core/Hypo.Core.csproj
git commit -m "feat(windows): discover Hypo peers over mDNS"
```

---

## Tasks 5 to 16 — still to be written

These remain scoped but not written. The transport group is de-risked by working spike code that should be lifted into the plan rather than reinvented:

**Tasks 6 to 9, the transport.** A second spike verified the whole shape:
- Kestrel with `builder.WebHost.ConfigureKestrel(o => o.Listen(IPAddress.Any, port))`, `app.UseWebSockets()`, and `ctx.WebSockets.AcceptWebSocketAsync()`.
- **Dynamic port binding requires `Listen(IPAddress.Loopback, 0)` or `Listen(IPAddress.Any, 0)`; `ListenLocalhost(0)` throws** `InvalidOperationException: Dynamic port binding is not supported when binding to localhost`. This is exactly the ephemeral-port fallback path spec section 7 requires, so the plan must use the working form.
- The bound port is read back from `IServerAddressesFeature`, which is what discovery must advertise.
- `ClientWebSocket.Options.SetRequestHeader("X-Device-Id", ...)` works, and a `?device_id=` query string arrives in `Request.Query` while `Request.Path` stays `/`. Sending both costs nothing and matches what the macOS server accepts from either kind of client.
- A length-prefixed binary frame round-trips with `WebSocketMessageType.Binary` and `endOfMessage: true`.

Remaining scope:

5. **`SigningService`** — Ed25519 sign and verify via BouncyCastle, closing the one unimplemented row of spec §4.1.
11. **`PairingMessages`** — `PairingChallengeMessage` and `PairingAckMessage`, matching `macos/Sources/HypoApp/Pairing/PairingModels.swift` field for field, with `challenge_id` lowercase.
12. **`PairingSession`** — generates a fresh ephemeral X25519 pair per attempt, sends the challenge, verifies and consumes the ack, derives the shared key. Rejects a replayed `challenge_id` and an expired payload.
13. **Pairing round-trip test** — two sessions in one process complete a pairing and derive the same key, and a tampered ack is rejected.
14. **`Hypo.Harness` console tool** — `discover`, `pair <device-id>`, `send <text>`, `listen`. Persists pairings through `InMemorySecretStore` for now; Plan 4 swaps in DPAPI.
15. **Live interop run** — pair the harness with a real macOS or Android device and exchange a clipboard item in both directions. Record the outcome in the plan.
16. **CI** — extend the `windows-tests` job to run the new suites, keeping the live-peer tests opt-in so CI stays hermetic.

## Done criteria

1. `cd windows && dotnet test` passes with zero failures and zero warnings.
2. The harness discovers a real macOS or Android peer and prints its unescaped name, host, port and device id.
3. The harness completes a pairing with that peer and both sides derive the same key.
4. A clipboard payload sent from the harness appears on the peer, and one sent from the peer is decrypted and printed by the harness.
5. The live-peer tests are skipped by default so CI does not depend on a network.

## Carried forward beyond Plan 2

Plan 1's handoff list items 3, 5, 6, 8, 9 and 10 remain open — control and error message payloads, the X25519 low-order point exception type, unknown message types, `ISecretStore` enumeration and zeroing, unbounded gzip output, and the scope of the null-rejection guarantee. Plan 3 (cloud relay, dual transport, history) is where most of them land.
