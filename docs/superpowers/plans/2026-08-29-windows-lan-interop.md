# Windows Client — Plan 2: LAN Interoperability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover a real macOS or Android Hypo peer on the local network, pair with it, and exchange a clipboard payload — proving the Windows client interoperates end to end.

**Architecture:** Plan 1 built `Hypo.Core`, which can encode, encrypt and frame protocol messages but cannot send them. This plan adds the pieces between that library and a socket: a streaming frame reader, an `ISyncTransport` abstraction, mDNS discovery, a LAN WebSocket client and server, Ed25519 pairing, and a console harness that ties them together. Still no Windows-specific API, no UI: everything here stays in `net10.0` so it can be developed and tested on any platform, and the harness runs anywhere.

**Tech Stack:** .NET 10, `Makaretu.Dns.Multicast`, `System.Net.WebSockets`, Kestrel, BouncyCastle (Ed25519), xUnit.

**Spec:** `docs/superpowers/specs/2026-08-28-windows-client-design.md` §3 (data flow), §4 (pairing), §7 (error handling).

**Prerequisite:** Plan 1, merged. `Hypo.Core` at 78 passing tests.

> **STATUS: INCOMPLETE — DO NOT EXECUTE PAST TASK 13.**
> Tasks 1 to 13 are written to this plan's own standard: failing test, complete
> implementation, exact commands, expected counts. Tasks 3–16 are currently only
> scoped, not written. A summarised task is a plan failure, not a shortcut — the
> whole reason Plan 1's subagents caught a JSON writer that escaped `+`, a
> converter override that was never invoked, and an associated-data formula that
> would have broken interoperability with both peer clients is that they were
> handed exact code to run and could watch it fail. Finish writing them before
> dispatching anyone past Task 13.

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

## Task 5: Live-network discovery test

An opt-in test that browses the real network. It is the regression guard for the
interoperability the spike proved, and it is skipped by default so CI never
depends on a network or on a peer being switched on.

**Files:**
- Test: `windows/tests/Hypo.Core.Tests/LivePeerDiscoveryTests.cs`

- [ ] **Step 1: Write the test**

Create `windows/tests/Hypo.Core.Tests/LivePeerDiscoveryTests.cs`:

```csharp
using Hypo.Core.Discovery;

namespace Hypo.Core.Tests;

/// <summary>
/// Requires a real Hypo peer on the same network. Enable with HYPO_LIVE_PEER=1.
/// </summary>
public class LivePeerDiscoveryTests
{
    private static bool Enabled =>
        Environment.GetEnvironmentVariable("HYPO_LIVE_PEER") == "1";

    [SkippableFact]
    public async Task DiscoversAtLeastOneRealPeer()
    {
        Skip.IfNot(Enabled, "Set HYPO_LIVE_PEER=1 with a macOS or Android peer on the network.");

        await using var discovery = new MdnsPeerDiscovery();
        var found = new List<DiscoveredPeer>();
        discovery.PeerDiscovered += (_, peer) => { lock (found) { found.Add(peer); } };

        await discovery.StartBrowsingAsync();
        for (var i = 0; i < 3; i++)
        {
            await Task.Delay(TimeSpan.FromSeconds(5));
            discovery.Refresh();
        }

        DiscoveredPeer[] peers;
        lock (found) { peers = found.ToArray(); }

        Assert.NotEmpty(peers);

        foreach (var peer in peers)
        {
            Assert.EndsWith("._hypo._tcp.local", peer.InstanceName, StringComparison.OrdinalIgnoreCase);
            Assert.False(string.IsNullOrWhiteSpace(peer.Address));
            Assert.InRange(peer.Port, 1, 65535);
            Assert.DoesNotContain("\\0", peer.DisplayName, StringComparison.Ordinal);
        }
    }

    [SkippableFact]
    public async Task RealPeersAdvertisePairingMaterial()
    {
        Skip.IfNot(Enabled, "Set HYPO_LIVE_PEER=1 with a macOS or Android peer on the network.");

        await using var discovery = new MdnsPeerDiscovery();
        await discovery.StartBrowsingAsync();
        await Task.Delay(TimeSpan.FromSeconds(12));

        var pairable = discovery.KnownPeers
            .Where(p => p.DeviceId is not null && p.PublicKey is not null)
            .ToArray();

        Assert.NotEmpty(pairable);

        foreach (var peer in pairable)
        {
            Assert.True(Guid.TryParse(peer.DeviceId, out _), $"device_id was '{peer.DeviceId}'");
            Assert.Equal(peer.DeviceId, peer.DeviceId!.ToLowerInvariant());
            Assert.Equal(32, peer.PublicKey!.Length);
            Assert.Equal(32, peer.SigningPublicKey!.Length);
        }
    }
}
```

- [ ] **Step 2: Add the skippable-test package**

```bash
cd windows
dotnet add tests/Hypo.Core.Tests/Hypo.Core.Tests.csproj package Xunit.SkippableFact
```

- [ ] **Step 3: Confirm it skips by default**

Run: `cd windows && dotnet test --filter FullyQualifiedName~LivePeerDiscoveryTests`

Expected: 2 skipped, 0 failed. A pass here means the guard is broken and CI has
been made to depend on a live network.

- [ ] **Step 4: Run it for real**

Run: `cd windows && HYPO_LIVE_PEER=1 dotnet test --filter FullyQualifiedName~LivePeerDiscoveryTests`

Expected: PASS, 2 tests, with at least one macOS or Android peer switched on and
on the same network. If it fails, that is a genuine interoperability regression
against the behaviour recorded in spec section 4.2 — report it rather than
weakening the assertions.

- [ ] **Step 5: Commit**

```bash
git add windows/tests/Hypo.Core.Tests/LivePeerDiscoveryTests.cs windows/tests/Hypo.Core.Tests/Hypo.Core.Tests.csproj
git commit -m "test(windows): guard live peer discovery behind an opt-in flag"
```

---

## Task 6: The transport contract

**Files:**
- Create: `windows/src/Hypo.Core/Transport/ISyncTransport.cs`
- Create: `windows/src/Hypo.Core/Transport/TransportEvents.cs`
- Test: `windows/tests/Hypo.Core.Tests/TransportEventsTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/TransportEventsTests.cs`:

```csharp
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~TransportEventsTests`

Expected: FAIL to compile with `CS0246` for `Hypo.Core.Transport`.

- [ ] **Step 3: Write `TransportEvents`**

Create `windows/src/Hypo.Core/Transport/TransportEvents.cs`:

```csharp
using Hypo.Core.Protocol;

namespace Hypo.Core.Transport;

/// <summary>Which channel a message arrived on. Matches TransportOrigin on macOS.</summary>
public enum TransportOrigin
{
    Lan,
    Cloud,
}

public enum TransportState
{
    Disconnected,
    Connecting,
    Connected,
    Faulted,
}

public sealed class EnvelopeReceivedEventArgs(
    SyncEnvelope envelope,
    string peerDeviceId,
    TransportOrigin origin) : EventArgs
{
    public SyncEnvelope Envelope { get; } = envelope;

    /// <summary>
    /// The peer this arrived from, as the transport understands it — from the
    /// handshake, not from the envelope body. The two can disagree, and a peer
    /// claiming to be someone else in the body is exactly what the envelope's
    /// authenticated associated data exists to catch.
    /// </summary>
    public string PeerDeviceId { get; } = peerDeviceId;

    public TransportOrigin Origin { get; } = origin;
}

public sealed class TransportStateChangedEventArgs(TransportState state, Exception? error) : EventArgs
{
    public TransportState State { get; } = state;

    public Exception? Error { get; } = error;
}
```

- [ ] **Step 4: Write `ISyncTransport`**

Create `windows/src/Hypo.Core/Transport/ISyncTransport.cs`:

```csharp
using Hypo.Core.Protocol;

namespace Hypo.Core.Transport;

/// <summary>
/// One channel over which envelopes travel. Plan 2 implements the LAN client and
/// server; Plan 3 adds the cloud relay and the dual-send transport that fans one
/// message across both.
/// </summary>
public interface ISyncTransport : IAsyncDisposable
{
    event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;

    event EventHandler<TransportStateChangedEventArgs>? StateChanged;

    TransportState State { get; }

    Task ConnectAsync(CancellationToken ct = default);

    /// <summary>
    /// Sends one envelope. Callers fanning a message across several transports
    /// must give each a separately generated nonce: reusing one under a single
    /// key is catastrophic. See CryptoService.Encrypt's remarks.
    /// </summary>
    Task SendAsync(SyncEnvelope envelope, CancellationToken ct = default);

    Task DisconnectAsync(CancellationToken ct = default);
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~TransportEventsTests`

Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add windows/src/Hypo.Core/Transport/ windows/tests/Hypo.Core.Tests/TransportEventsTests.cs
git commit -m "feat(windows): define the sync transport contract"
```

---
## Task 7: LAN WebSocket client

Dials a discovered peer. Everything about the wire shape here was verified by a
spike before this plan was written: a `ws://` scheme because the advertised
`ws+tls` is not implemented by any client, the device id on both an
`X-Device-Id` header and a `device_id` query parameter because the macOS server
accepts either, and length-prefixed binary frames.

**Files:**
- Create: `windows/src/Hypo.Core/Transport/LanWebSocketClient.cs`
- Test: `windows/tests/Hypo.Core.Tests/LanWebSocketClientTests.cs`

- [ ] **Step 1: Write the failing test**

These cover URI construction and framing. The socket itself is exercised in
Task 9, against the real server.

Create `windows/tests/Hypo.Core.Tests/LanWebSocketClientTests.cs`:

```csharp
using Hypo.Core.Discovery;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class LanWebSocketClientTests
{
    private const string LocalDeviceId = "550e8400-e29b-41d4-a716-446655440000";

    private static DiscoveredPeer Peer() => DiscoveredPeer.FromTxt(
        instanceName: "peer._hypo._tcp.local",
        host: "peer.local",
        address: "10.0.0.17",
        port: 7010,
        txt: new Dictionary<string, string> { ["device_id"] = "bbe296d6-0785-43d2-91b6-b135b72f4c41" });

    [Fact]
    public void DialsTheAddressWithTheDeviceIdOnTheQueryString()
    {
        var uri = LanWebSocketClient.BuildUri(Peer(), LocalDeviceId);

        Assert.Equal("ws", uri.Scheme);
        Assert.Equal("10.0.0.17", uri.Host);
        Assert.Equal(7010, uri.Port);
        Assert.Contains($"device_id={LocalDeviceId}", uri.Query, StringComparison.Ordinal);
    }

    [Fact]
    public void NeverDialsWss()
    {
        // Peers advertise protocols=ws+tls and none of them implement it.
        // Honouring that field would make every connection fail.
        var txt = new Dictionary<string, string> { ["protocols"] = "ws+tls" };
        var peer = DiscoveredPeer.FromTxt("p._hypo._tcp.local", "h", "10.0.0.1", 7010, txt);

        Assert.Equal("ws", LanWebSocketClient.BuildUri(peer, LocalDeviceId).Scheme);
    }

    [Fact]
    public void LowercasesTheLocalDeviceIdOnTheWire()
    {
        var uri = LanWebSocketClient.BuildUri(Peer(), LocalDeviceId.ToUpperInvariant());

        Assert.Contains($"device_id={LocalDeviceId}", uri.Query, StringComparison.Ordinal);
    }

    [Fact]
    public void StartsDisconnected()
    {
        using var client = new LanWebSocketClient(Peer(), LocalDeviceId);

        Assert.Equal(TransportState.Disconnected, client.State);
    }

    [Fact]
    public async Task SendingBeforeConnectingThrows()
    {
        using var client = new LanWebSocketClient(Peer(), LocalDeviceId);

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => client.SendAsync(TestEnvelopes.Clipboard(LocalDeviceId)));
    }
}
```

Create `windows/tests/Hypo.Core.Tests/TestEnvelopes.cs`, a shared helper the
transport tests reuse:

```csharp
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

internal static class TestEnvelopes
{
    public static SyncEnvelope Clipboard(string deviceId, byte[]? ciphertext = null) => new()
    {
        Id = Guid.NewGuid(),
        Timestamp = DateTimeOffset.Parse("2026-08-29T12:00:00Z"),
        Type = MessageType.Clipboard,
        Payload = new EnvelopePayload
        {
            ContentType = ContentType.Text,
            Ciphertext = ciphertext ?? [0x01, 0x02, 0x03],
            DeviceId = deviceId,
            DevicePlatform = "windows",
            Encryption = new EncryptionMetadata { Nonce = new byte[12], Tag = new byte[16] },
        },
    };
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~LanWebSocketClientTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'LanWebSocketClient' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Transport/LanWebSocketClient.cs`:

```csharp
using System.Net.WebSockets;
using Hypo.Core.Discovery;
using Hypo.Core.Protocol;

namespace Hypo.Core.Transport;

/// <summary>
/// Outbound LAN connection to a discovered peer. Plain ws:// by design: the
/// TXT record's "protocols=ws+tls" is advertised by both shipping clients and
/// implemented by neither, and payload encryption is the security boundary.
/// </summary>
public sealed class LanWebSocketClient : ISyncTransport, IDisposable
{
    private readonly DiscoveredPeer _peer;
    private readonly string _localDeviceId;
    private readonly TransportFrameCodec _codec = new();
    private readonly FrameReader _reader = new();

    private ClientWebSocket? _socket;
    private CancellationTokenSource? _pump;
    private TransportState _state = TransportState.Disconnected;

    public LanWebSocketClient(DiscoveredPeer peer, string localDeviceId)
    {
        ArgumentNullException.ThrowIfNull(peer);
        ArgumentException.ThrowIfNullOrWhiteSpace(localDeviceId);

        _peer = peer;
        _localDeviceId = localDeviceId.ToLowerInvariant();
    }

    public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;
    public event EventHandler<TransportStateChangedEventArgs>? StateChanged;

    public TransportState State => _state;

    public string PeerDeviceId => _peer.DeviceId ?? _peer.InstanceName;

    /// <summary>
    /// The macOS server reads the device id from an X-Device-Id header or a
    /// device_id query parameter and accepts either, so both are sent.
    /// </summary>
    public static Uri BuildUri(DiscoveredPeer peer, string localDeviceId)
    {
        ArgumentNullException.ThrowIfNull(peer);
        ArgumentException.ThrowIfNullOrWhiteSpace(localDeviceId);

        return new Uri($"ws://{peer.Address}:{peer.Port}/?device_id={localDeviceId.ToLowerInvariant()}");
    }

    public async Task ConnectAsync(CancellationToken ct = default)
    {
        if (_state is TransportState.Connected or TransportState.Connecting)
        {
            return;
        }

        SetState(TransportState.Connecting, null);
        _reader.Reset();

        var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("X-Device-Id", _localDeviceId);

        try
        {
            await socket.ConnectAsync(BuildUri(_peer, _localDeviceId), ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            socket.Dispose();
            SetState(TransportState.Faulted, ex);
            throw;
        }

        _socket = socket;
        _pump = CancellationTokenSource.CreateLinkedTokenSource(ct);
        SetState(TransportState.Connected, null);
        _ = Task.Run(() => PumpAsync(_pump.Token), CancellationToken.None);
    }

    public async Task SendAsync(SyncEnvelope envelope, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(envelope);

        var socket = _socket;
        if (socket is null || socket.State != WebSocketState.Open)
        {
            throw new InvalidOperationException("The transport is not connected.");
        }

        var frame = _codec.Encode(envelope);
        await socket.SendAsync(frame, WebSocketMessageType.Binary, true, ct).ConfigureAwait(false);
    }

    public async Task DisconnectAsync(CancellationToken ct = default)
    {
        if (_pump is not null)
        {
            await _pump.CancelAsync().ConfigureAwait(false);
        }

        var socket = _socket;
        if (socket is { State: WebSocketState.Open })
        {
            try
            {
                await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", ct).ConfigureAwait(false);
            }
            catch (WebSocketException)
            {
                // The peer may have gone already. Closing is best effort.
            }
        }

        SetState(TransportState.Disconnected, null);
    }

    private async Task PumpAsync(CancellationToken ct)
    {
        var buffer = new byte[16 * 1024];
        var socket = _socket!;

        try
        {
            while (!ct.IsCancellationRequested && socket.State == WebSocketState.Open)
            {
                var result = await socket.ReceiveAsync(buffer, ct).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    break;
                }

                // A WebSocket message boundary is not a frame boundary: FrameReader
                // owns reassembly across both partial and coalesced reads.
                foreach (var body in _reader.Append(buffer.AsSpan(0, result.Count)))
                {
                    Dispatch(body);
                }
            }

            SetState(TransportState.Disconnected, null);
        }
        catch (OperationCanceledException)
        {
            SetState(TransportState.Disconnected, null);
        }
        catch (Exception ex)
        {
            SetState(TransportState.Faulted, ex);
        }
    }

    private void Dispatch(byte[] body)
    {
        SyncEnvelope envelope;
        try
        {
            // Decode expects the length prefix, which FrameReader has stripped.
            var framed = new byte[4 + body.Length];
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(framed, (uint)body.Length);
            body.CopyTo(framed.AsSpan(4));
            envelope = _codec.Decode(framed);
        }
        catch (Exception ex) when (ex is TransportFrameException or System.Text.Json.JsonException)
        {
            // A peer sending malformed protocol data is not a reason to tear the
            // connection down; drop the message and keep reading.
            return;
        }

        EnvelopeReceived?.Invoke(this, new EnvelopeReceivedEventArgs(envelope, PeerDeviceId, TransportOrigin.Lan));
    }

    private void SetState(TransportState state, Exception? error)
    {
        if (_state == state)
        {
            return;
        }

        _state = state;
        StateChanged?.Invoke(this, new TransportStateChangedEventArgs(state, error));
    }

    public void Dispose()
    {
        _pump?.Dispose();
        _socket?.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        await DisconnectAsync().ConfigureAwait(false);
        Dispose();
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~LanWebSocketClientTests`

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Transport/LanWebSocketClient.cs windows/tests/Hypo.Core.Tests/LanWebSocketClientTests.cs windows/tests/Hypo.Core.Tests/TestEnvelopes.cs
git commit -m "feat(windows): add the LAN WebSocket client"
```

---

## Task 8: LAN WebSocket server

Accepts inbound connections from peers. Two details here were established by a
spike and must not be re-derived: dynamic port binding needs
`Listen(IPAddress.Any, 0)` because `ListenLocalhost(0)` throws, and the bound
port has to be read back so discovery advertises the port actually in use.

**Files:**
- Create: `windows/src/Hypo.Core/Transport/LanWebSocketServer.cs`
- Test: `windows/tests/Hypo.Core.Tests/LanWebSocketServerTests.cs`

- [ ] **Step 1: Add the hosting package**

```bash
cd windows
dotnet add src/Hypo.Core/Hypo.Core.csproj package Microsoft.AspNetCore.App.Ref
```

If that package is unavailable, add the framework reference to
`windows/src/Hypo.Core/Hypo.Core.csproj` instead, which is the supported route
for a library that hosts Kestrel:

```xml
  <ItemGroup>
    <FrameworkReference Include="Microsoft.AspNetCore.App" />
  </ItemGroup>
```

Run `cd windows && dotnet build` and confirm 0 warnings. In particular confirm
no `CA1416` appears: a framework reference that dragged in a Windows-only API
would break the dependency rule that keeps `Hypo.Core` at `net10.0`.

- [ ] **Step 2: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/LanWebSocketServerTests.cs`:

```csharp
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class LanWebSocketServerTests
{
    private const string LocalDeviceId = "550e8400-e29b-41d4-a716-446655440000";

    [Fact]
    public async Task ReportsThePortItActuallyBound()
    {
        // Port 0 asks the OS for a free one. Discovery must advertise what was
        // bound, not what was requested, or peers dial a port nobody is on.
        await using var server = new LanWebSocketServer(LocalDeviceId, port: 0);

        await server.StartAsync();

        Assert.InRange(server.BoundPort, 1, 65535);
    }

    [Fact]
    public async Task FallsBackToAnEphemeralPortWhenThePreferredOneIsTaken()
    {
        await using var first = new LanWebSocketServer(LocalDeviceId, port: 0);
        await first.StartAsync();

        await using var second = new LanWebSocketServer(LocalDeviceId, port: first.BoundPort);
        await second.StartAsync();

        Assert.NotEqual(first.BoundPort, second.BoundPort);
        Assert.InRange(second.BoundPort, 1, 65535);
    }

    [Fact]
    public async Task StartingTwiceIsHarmless()
    {
        await using var server = new LanWebSocketServer(LocalDeviceId, port: 0);

        await server.StartAsync();
        var port = server.BoundPort;
        await server.StartAsync();

        Assert.Equal(port, server.BoundPort);
    }

    [Fact]
    public void BoundPortBeforeStartingIsZero()
    {
        var server = new LanWebSocketServer(LocalDeviceId, port: 7010);

        Assert.Equal(0, server.BoundPort);
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~LanWebSocketServerTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'LanWebSocketServer' could not be found`.

- [ ] **Step 4: Write the implementation**

Create `windows/src/Hypo.Core/Transport/LanWebSocketServer.cs`:

```csharp
using System.Net;
using System.Net.WebSockets;
using Hypo.Core.Protocol;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Hypo.Core.Transport;

/// <summary>
/// Accepts inbound LAN connections from peers. Plain ws://, matching the
/// shipping clients; payload encryption is the security boundary.
/// </summary>
public sealed class LanWebSocketServer : IAsyncDisposable
{
    /// <summary>The port both shipping clients advertise and dial.</summary>
    public const int DefaultPort = 7010;

    private readonly string _localDeviceId;
    private readonly int _preferredPort;
    private readonly TransportFrameCodec _codec = new();

    private WebApplication? _app;

    public LanWebSocketServer(string localDeviceId, int port = DefaultPort)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(localDeviceId);
        ArgumentOutOfRangeException.ThrowIfNegative(port);

        _localDeviceId = localDeviceId.ToLowerInvariant();
        _preferredPort = port;
    }

    public event EventHandler<EnvelopeReceivedEventArgs>? EnvelopeReceived;

    /// <summary>
    /// The port in use, or 0 before starting. Discovery must advertise this
    /// rather than the preferred port: when 7010 is taken the server falls back
    /// to an ephemeral one, and a peer dialling the wrong port never connects.
    /// </summary>
    public int BoundPort { get; private set; }

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_app is not null)
        {
            return;
        }

        _app = await BuildAsync(_preferredPort, ct).ConfigureAwait(false)
               ?? await BuildAsync(0, ct).ConfigureAwait(false)
               ?? throw new IOException("Could not bind a LAN listener on any port.");

        BoundPort = ReadBoundPort(_app);
    }

    private async Task<WebApplication?> BuildAsync(int port, CancellationToken ct)
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();

        // Any IP, not localhost: peers connect from across the network. And
        // dynamic binding is only supported on an explicit address —
        // ListenLocalhost(0) throws "Dynamic port binding is not supported".
        builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Any, port));

        var app = builder.Build();
        app.UseWebSockets();
        app.Use(HandleAsync);

        try
        {
            await app.StartAsync(ct).ConfigureAwait(false);
            return app;
        }
        catch (IOException)
        {
            // Port in use. The caller retries on 0.
            await app.DisposeAsync().ConfigureAwait(false);
            return null;
        }
    }

    private async Task HandleAsync(HttpContext context, RequestDelegate next)
    {
        if (!context.WebSockets.IsWebSocketRequest)
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }

        // Both shipping clients are accommodated: macOS sends a header, Android
        // is documented in the macOS server as often using the query string.
        var peerDeviceId = context.Request.Headers["X-Device-Id"].ToString();
        if (string.IsNullOrWhiteSpace(peerDeviceId))
        {
            peerDeviceId = context.Request.Query["device_id"].ToString();
        }

        using var socket = await context.WebSockets.AcceptWebSocketAsync().ConfigureAwait(false);
        await PumpAsync(socket, peerDeviceId.ToLowerInvariant(), context.RequestAborted).ConfigureAwait(false);
    }

    private async Task PumpAsync(WebSocket socket, string peerDeviceId, CancellationToken ct)
    {
        var reader = new FrameReader();
        var buffer = new byte[16 * 1024];

        try
        {
            while (socket.State == WebSocketState.Open && !ct.IsCancellationRequested)
            {
                var result = await socket.ReceiveAsync(buffer, ct).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    break;
                }

                foreach (var body in reader.Append(buffer.AsSpan(0, result.Count)))
                {
                    Dispatch(body, peerDeviceId);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Shutting down.
        }
        catch (WebSocketException)
        {
            // The peer vanished. Nothing to recover.
        }
        catch (TransportFrameException)
        {
            // An oversized length prefix means the stream position is no longer
            // trustworthy, so this connection cannot continue.
        }
    }

    private void Dispatch(byte[] body, string peerDeviceId)
    {
        SyncEnvelope envelope;
        try
        {
            var framed = new byte[4 + body.Length];
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(framed, (uint)body.Length);
            body.CopyTo(framed.AsSpan(4));
            envelope = _codec.Decode(framed);
        }
        catch (Exception ex) when (ex is TransportFrameException or System.Text.Json.JsonException)
        {
            return;
        }

        EnvelopeReceived?.Invoke(this, new EnvelopeReceivedEventArgs(envelope, peerDeviceId, TransportOrigin.Lan));
    }

    private static int ReadBoundPort(WebApplication app)
    {
        var addresses = app.Services.GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()?.Addresses;

        var address = addresses?.FirstOrDefault()
                      ?? throw new IOException("Kestrel reported no bound address.");

        return new Uri(address).Port;
    }

    public async ValueTask DisposeAsync()
    {
        if (_app is not null)
        {
            await _app.DisposeAsync().ConfigureAwait(false);
            _app = null;
        }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~LanWebSocketServerTests`

Expected: PASS, 4 tests.

If `FallsBackToAnEphemeralPortWhenThePreferredOneIsTaken` fails because the
second bind succeeded on the same port, the platform is allowing address reuse.
Report it rather than deleting the test: on Windows the behaviour differs from
macOS and Linux, and this fallback is what spec section 7 requires.

- [ ] **Step 6: Commit**

```bash
git add windows/src/Hypo.Core/Transport/LanWebSocketServer.cs windows/tests/Hypo.Core.Tests/LanWebSocketServerTests.cs windows/src/Hypo.Core/Hypo.Core.csproj
git commit -m "feat(windows): add the LAN WebSocket server"
```

---

## Task 9: Loopback round trip

The first test that puts the client and the server together. It is the guard
that catches a framing or dispatch mistake before anyone tries to debug it
against a real device over a network.

**Files:**
- Test: `windows/tests/Hypo.Core.Tests/LanLoopbackTests.cs`

- [ ] **Step 1: Write the test**

Create `windows/tests/Hypo.Core.Tests/LanLoopbackTests.cs`:

```csharp
using Hypo.Core.Discovery;
using Hypo.Core.Protocol;
using Hypo.Core.Transport;

namespace Hypo.Core.Tests;

public class LanLoopbackTests
{
    private const string ClientId = "550e8400-e29b-41d4-a716-446655440000";
    private const string ServerId = "bbe296d6-0785-43d2-91b6-b135b72f4c41";

    private static DiscoveredPeer PeerOn(int port) => DiscoveredPeer.FromTxt(
        "server._hypo._tcp.local",
        "localhost",
        "127.0.0.1",
        port,
        new Dictionary<string, string> { ["device_id"] = ServerId });

    [Fact]
    public async Task TheServerReceivesWhatTheClientSends()
    {
        await using var server = new LanWebSocketServer(ServerId, port: 0);
        var received = new TaskCompletionSource<EnvelopeReceivedEventArgs>();
        server.EnvelopeReceived += (_, e) => received.TrySetResult(e);
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        await client.ConnectAsync();

        var sent = TestEnvelopes.Clipboard(ClientId, [0xDE, 0xAD, 0xBE, 0xEF]);
        await client.SendAsync(sent);

        var got = await received.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(sent.Id, got.Envelope.Id);
        Assert.Equal([0xDE, 0xAD, 0xBE, 0xEF], got.Envelope.Payload.Ciphertext);
        Assert.Equal(TransportOrigin.Lan, got.Origin);
    }

    [Fact]
    public async Task TheServerLearnsTheClientDeviceIdFromTheHandshake()
    {
        await using var server = new LanWebSocketServer(ServerId, port: 0);
        var received = new TaskCompletionSource<EnvelopeReceivedEventArgs>();
        server.EnvelopeReceived += (_, e) => received.TrySetResult(e);
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        await client.ConnectAsync();
        await client.SendAsync(TestEnvelopes.Clipboard(ClientId));

        var got = await received.Task.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(ClientId, got.PeerDeviceId);
    }

    [Fact]
    public async Task SeveralEnvelopesInOneReadAreAllDelivered()
    {
        await using var server = new LanWebSocketServer(ServerId, port: 0);
        var received = new List<SyncEnvelope>();
        var done = new TaskCompletionSource();
        server.EnvelopeReceived += (_, e) =>
        {
            lock (received)
            {
                received.Add(e.Envelope);
                if (received.Count == 3) done.TrySetResult();
            }
        };
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        await client.ConnectAsync();

        for (var i = 0; i < 3; i++)
        {
            await client.SendAsync(TestEnvelopes.Clipboard(ClientId, [(byte)i]));
        }

        await done.Task.WaitAsync(TimeSpan.FromSeconds(10));

        lock (received)
        {
            Assert.Equal(3, received.Count);
            Assert.Equal([0, 1, 2], received.Select(e => e.Payload.Ciphertext[0]));
        }
    }

    [Fact]
    public async Task ConnectingReportsTheStateTransitions()
    {
        await using var server = new LanWebSocketServer(ServerId, port: 0);
        await server.StartAsync();

        await using var client = new LanWebSocketClient(PeerOn(server.BoundPort), ClientId);
        var states = new List<TransportState>();
        client.StateChanged += (_, e) => { lock (states) { states.Add(e.State); } };

        await client.ConnectAsync();

        lock (states)
        {
            Assert.Equal([TransportState.Connecting, TransportState.Connected], states);
        }
    }

    [Fact]
    public async Task ConnectingToANonListeningPortFaults()
    {
        // Port 1 is privileged and nothing listens there in a test run.
        await using var client = new LanWebSocketClient(PeerOn(1), ClientId);
        var faulted = new TaskCompletionSource<TransportStateChangedEventArgs>();
        client.StateChanged += (_, e) => { if (e.State == TransportState.Faulted) faulted.TrySetResult(e); };

        await Assert.ThrowsAnyAsync<Exception>(() => client.ConnectAsync());

        var args = await faulted.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.NotNull(args.Error);
    }
}
```

- [ ] **Step 2: Run it**

Run: `cd windows && dotnet test --filter FullyQualifiedName~LanLoopbackTests`

Expected: PASS, 5 tests.

These bind real sockets on the loopback interface. If a sandbox denies that, the
tests fail rather than skip on purpose: a transport that cannot be exercised is
not verified, and pretending otherwise is worse than a red test.

- [ ] **Step 3: Run the whole suite**

Run: `cd windows && dotnet test`

Expected: 0 failures.

- [ ] **Step 4: Commit**

```bash
git add windows/tests/Hypo.Core.Tests/LanLoopbackTests.cs
git commit -m "test(windows): round-trip an envelope over a loopback LAN socket"
```

---
## Task 10: Ed25519 signing

The one unimplemented row of spec section 4.1. `PairingPayload` is Ed25519
signed, and the signing public key is what peers advertise as `signing_pub_key`.

**Files:**
- Create: `windows/src/Hypo.Core/Crypto/SigningService.cs`
- Test: `windows/tests/Hypo.Core.Tests/SigningServiceTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/SigningServiceTests.cs`:

```csharp
using Hypo.Core.Crypto;

namespace Hypo.Core.Tests;

public class SigningServiceTests
{
    private static (byte[] Private, byte[] Public) Key()
    {
        var priv = SigningService.GeneratePrivateKey();
        return (priv, SigningService.DerivePublicKey(priv));
    }

    [Fact]
    public void GeneratesKeysOfTheRightLength()
    {
        var (priv, pub) = Key();

        Assert.Equal(SigningService.KeySizeBytes, priv.Length);
        Assert.Equal(SigningService.KeySizeBytes, pub.Length);
    }

    [Fact]
    public void VerifiesWhatItSigned()
    {
        var (priv, pub) = Key();
        var message = "the payload"u8.ToArray();

        var signature = SigningService.Sign(message, priv);

        Assert.Equal(SigningService.SignatureSizeBytes, signature.Length);
        Assert.True(SigningService.Verify(message, signature, pub));
    }

    [Fact]
    public void RejectsATamperedMessage()
    {
        var (priv, pub) = Key();
        var signature = SigningService.Sign("the payload"u8.ToArray(), priv);

        Assert.False(SigningService.Verify("the paylaod"u8.ToArray(), signature, pub));
    }

    [Fact]
    public void RejectsATamperedSignature()
    {
        var (priv, pub) = Key();
        var message = "the payload"u8.ToArray();
        var signature = SigningService.Sign(message, priv);
        signature[0] ^= 0xFF;

        Assert.False(SigningService.Verify(message, signature, pub));
    }

    [Fact]
    public void RejectsAnotherPartysKey()
    {
        var (priv, _) = Key();
        var (_, otherPub) = Key();
        var message = "the payload"u8.ToArray();

        Assert.False(SigningService.Verify(message, SigningService.Sign(message, priv), otherPub));
    }

    [Fact]
    public void VerifyReturnsFalseRatherThanThrowingOnAMalformedSignature()
    {
        // Signatures arrive from peers. A malformed one is untrusted input, not
        // a programming error, and callers should get a bool rather than an
        // exception they have to remember to catch.
        var (_, pub) = Key();

        Assert.False(SigningService.Verify("x"u8.ToArray(), [0x01, 0x02], pub));
    }

    [Theory]
    [InlineData(31)]
    [InlineData(33)]
    public void NamesTheOffendingArgumentOnAWrongLengthKey(int length)
    {
        var error = Assert.Throws<ArgumentException>(
            () => SigningService.Sign("x"u8.ToArray(), new byte[length]));

        Assert.Equal("privateKey", error.ParamName);
    }

    [Fact]
    public void VerifyRejectsAWrongLengthPublicKeyWithoutThrowing()
    {
        Assert.False(SigningService.Verify("x"u8.ToArray(), new byte[64], new byte[31]));
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~SigningServiceTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'SigningService' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Crypto/SigningService.cs`:

```csharp
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Hypo.Core.Crypto;

/// <summary>
/// Ed25519 signing for pairing payloads. Peers advertise the public half as
/// signing_pub_key; see the design spec section 4.2. Matches
/// Curve25519.Signing on macOS.
/// </summary>
public static class SigningService
{
    public const int KeySizeBytes = 32;
    public const int SignatureSizeBytes = 64;

    public static byte[] GeneratePrivateKey()
    {
        var seed = new byte[KeySizeBytes];
        System.Security.Cryptography.RandomNumberGenerator.Fill(seed);
        return seed;
    }

    public static byte[] DerivePublicKey(byte[] privateKey)
    {
        RequireKeySize(privateKey, nameof(privateKey));
        return new Ed25519PrivateKeyParameters(privateKey).GeneratePublicKey().GetEncoded();
    }

    public static byte[] Sign(byte[] message, byte[] privateKey)
    {
        ArgumentNullException.ThrowIfNull(message);
        RequireKeySize(privateKey, nameof(privateKey));

        var signer = new Ed25519Signer();
        signer.Init(true, new Ed25519PrivateKeyParameters(privateKey));
        signer.BlockUpdate(message, 0, message.Length);
        return signer.GenerateSignature();
    }

    /// <summary>
    /// Returns false rather than throwing for anything malformed. Signatures and
    /// keys here arrive from peers, so a bad one is untrusted input rather than
    /// a bug, and a bool is harder for a caller to ignore than an exception.
    /// </summary>
    public static bool Verify(byte[] message, byte[] signature, byte[] publicKey)
    {
        if (message is null || signature is null || publicKey is null ||
            publicKey.Length != KeySizeBytes ||
            signature.Length != SignatureSizeBytes)
        {
            return false;
        }

        try
        {
            var verifier = new Ed25519Signer();
            verifier.Init(false, new Ed25519PublicKeyParameters(publicKey));
            verifier.BlockUpdate(message, 0, message.Length);
            return verifier.VerifySignature(signature);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static void RequireKeySize(byte[] key, string paramName)
    {
        ArgumentNullException.ThrowIfNull(key, paramName);

        if (key.Length != KeySizeBytes)
        {
            throw new ArgumentException(
                $"An Ed25519 key is {KeySizeBytes} bytes; got {key.Length}.", paramName);
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~SigningServiceTests`

Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Crypto/SigningService.cs windows/tests/Hypo.Core.Tests/SigningServiceTests.cs
git commit -m "feat(windows): add Ed25519 signing for pairing payloads"
```

---

## Task 11: Pairing message models

Field names mirror `macos/Sources/HypoApp/Pairing/PairingModels.swift`. Note
what is **not** here: the ACK carries no responder public key. Protocol section
9.2 says it does; the shipping implementation disagrees, and the design spec
section 4.2 records why.

**Files:**
- Create: `windows/src/Hypo.Core/Pairing/PairingMessages.cs`
- Test: `windows/tests/Hypo.Core.Tests/PairingMessagesTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/PairingMessagesTests.cs`:

```csharp
using System.Text.Json;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class PairingMessagesTests
{
    private const string ChallengeJson = """
    {
      "challenge_id": "11111111-1111-1111-1111-111111111111",
      "initiator_device_id": "550e8400-e29b-41d4-a716-446655440000",
      "initiator_device_name": "Test PC",
      "initiator_pub_key": "0KWinOak3zMKXjQg4K1f7TWdypF0oDb32e5fOnzjuX4=",
      "nonce": "qrvM",
      "ciphertext": "3q2+7w",
      "tag": "EBES"
    }
    """;

    [Fact]
    public void DeserialisesAChallenge()
    {
        var message = JsonSerializer.Deserialize<PairingChallengeMessage>(ChallengeJson, ProtocolJson.Options)!;

        Assert.Equal(Guid.Parse("11111111-1111-1111-1111-111111111111"), message.ChallengeId);
        Assert.Equal("550e8400-e29b-41d4-a716-446655440000", message.InitiatorDeviceId);
        Assert.Equal("Test PC", message.InitiatorDeviceName);
        Assert.Equal(32, message.InitiatorPublicKey.Length);
        Assert.Equal(new byte[] { 0xDE, 0xAD, 0xBE, 0xEF }, message.Ciphertext);
    }

    [Fact]
    public void WritesTheChallengeIdInLowercase()
    {
        // Android generates lowercase challenge ids and compares them as
        // strings; the macOS models carry explicit comments about this.
        var message = new PairingChallengeMessage
        {
            ChallengeId = Guid.Parse("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            InitiatorDeviceId = "550e8400-e29b-41d4-a716-446655440000",
            InitiatorDeviceName = "Test PC",
            InitiatorPublicKey = new byte[32],
            Nonce = new byte[12],
            Ciphertext = [0x01],
            Tag = new byte[16],
        };

        var json = JsonSerializer.Serialize(message, ProtocolJson.Options);

        Assert.Contains("\"challenge_id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void TheAckCarriesNoResponderPublicKey()
    {
        // Protocol section 9.2 claims otherwise. The shipping ACK has six
        // fields and none of them is a key; the responder publishes its key
        // before the challenge instead. A client waiting for one here waits
        // forever.
        Assert.Null(typeof(PairingAckMessage).GetProperty("ResponderPublicKey"));

        var json = JsonSerializer.Serialize(
            new PairingAckMessage
            {
                ChallengeId = Guid.NewGuid(),
                ResponderDeviceId = Guid.NewGuid(),
                ResponderDeviceName = "Peer",
                Nonce = new byte[12],
                Ciphertext = [0x01],
                Tag = new byte[16],
            },
            ProtocolJson.Options);

        Assert.DoesNotContain("pub_key", json, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void RoundTripsTheChallengePayload()
    {
        var payload = new PairingChallengePayload
        {
            Challenge = [0x01, 0x02, 0x03],
            Timestamp = DateTimeOffset.Parse("2026-08-29T12:00:00Z"),
        };

        var json = JsonSerializer.Serialize(payload, ProtocolJson.Options);
        var back = JsonSerializer.Deserialize<PairingChallengePayload>(json, ProtocolJson.Options)!;

        Assert.Equal(payload.Challenge, back.Challenge);
        Assert.Equal(payload.Timestamp, back.Timestamp);
        Assert.Contains("\"timestamp\":\"2026-08-29T12:00:00Z\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void TheAckPayloadUsesSnakeCaseFieldNames()
    {
        var payload = new PairingAckPayload
        {
            ResponseHash = new byte[32],
            IssuedAt = DateTimeOffset.Parse("2026-08-29T12:00:00Z"),
        };

        var json = JsonSerializer.Serialize(payload, ProtocolJson.Options);

        Assert.Contains("response_hash", json, StringComparison.Ordinal);
        Assert.Contains("issued_at", json, StringComparison.Ordinal);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~PairingMessagesTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'Hypo.Core.Pairing' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Pairing/PairingMessages.cs`:

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;
using Hypo.Core.Protocol;

namespace Hypo.Core.Pairing;

/// <summary>
/// Serialises a Guid in lowercase. Android generates lowercase challenge ids and
/// compares them as strings, so a client that wrote them uppercase would fail
/// every match.
/// </summary>
public sealed class LowercaseGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Guid.Parse(reader.GetString()!);

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToLowerInvariant());
}

/// <summary>Initiator to responder. Mirrors PairingChallengeMessage on macOS.</summary>
public sealed record PairingChallengeMessage
{
    [JsonConverter(typeof(LowercaseGuidConverter))]
    public required Guid ChallengeId { get; init; }

    public required string InitiatorDeviceId { get; init; }

    public required string InitiatorDeviceName { get; init; }

    [JsonPropertyName("initiator_pub_key")]
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] InitiatorPublicKey { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Nonce { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Ciphertext { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Tag { get; init; }
}

/// <summary>
/// Responder to initiator. Deliberately carries no key: the responder published
/// its agreement public key before the challenge arrived. See the design spec
/// section 4.2.
/// </summary>
public sealed record PairingAckMessage
{
    [JsonConverter(typeof(LowercaseGuidConverter))]
    public required Guid ChallengeId { get; init; }

    [JsonConverter(typeof(LowercaseGuidConverter))]
    public required Guid ResponderDeviceId { get; init; }

    public required string ResponderDeviceName { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Nonce { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Ciphertext { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Tag { get; init; }
}

/// <summary>The plaintext inside a challenge's ciphertext.</summary>
public sealed record PairingChallengePayload
{
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Challenge { get; init; }

    public required DateTimeOffset Timestamp { get; init; }
}

/// <summary>The plaintext inside an ack's ciphertext.</summary>
public sealed record PairingAckPayload
{
    [JsonPropertyName("response_hash")]
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] ResponseHash { get; init; }

    [JsonPropertyName("issued_at")]
    public required DateTimeOffset IssuedAt { get; init; }
}
```

`InitiatorPublicKey` and the two payload types need explicit `JsonPropertyName`
attributes because the snake-case policy would otherwise produce
`initiator_public_key`, `response_hash` is already correct by policy but is
pinned anyway, and `issued_at` likewise — being explicit here costs nothing and
the cost of being wrong is a pairing that fails with no diagnosis.

- [ ] **Step 4: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~PairingMessagesTests`

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Pairing/PairingMessages.cs windows/tests/Hypo.Core.Tests/PairingMessagesTests.cs
git commit -m "feat(windows): add pairing message models"
```

---
## Task 12: Pairing session

Drives both halves of the exchange. The sequence is the one measured from
`PairingSession.swift` and recorded in the design spec section 4.2 — not the one
in protocol section 9.2, which describes an ACK field that does not exist.

**Files:**
- Create: `windows/src/Hypo.Core/Pairing/PairingSession.cs`
- Test: `windows/tests/Hypo.Core.Tests/PairingSessionTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/PairingSessionTests.cs`:

```csharp
using Hypo.Core.Crypto;
using Hypo.Core.Pairing;

namespace Hypo.Core.Tests;

public class PairingSessionTests
{
    private const string InitiatorId = "550e8400-e29b-41d4-a716-446655440000";
    private static readonly Guid ResponderId = Guid.Parse("bbe296d6-0785-43d2-91b6-b135b72f4c41");

    private static (PairingSession Responder, byte[] ResponderPublicKey) StartResponder()
    {
        var session = PairingSession.StartResponder(ResponderId, "Peer");
        return (session, session.AgreementPublicKey);
    }

    [Fact]
    public void TheResponderPublishesAnAgreementKeyBeforeAnyChallenge()
    {
        var (_, publicKey) = StartResponder();

        Assert.Equal(CryptoService.X25519KeySizeBytes, publicKey.Length);
    }

    [Fact]
    public void EveryAttemptGeneratesAFreshKey()
    {
        // Protocol section 9.2's rotation claim is the one part of it that holds.
        Assert.NotEqual(StartResponder().ResponderPublicKey, StartResponder().ResponderPublicKey);
    }

    [Fact]
    public void BothSidesDeriveTheSameKey()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");

        var challenge = initiator.CreateChallenge(responderPublicKey);
        var result = responder.AcceptChallenge(challenge);

        Assert.NotNull(result);
        Assert.Equal(CryptoService.KeySizeBytes, result.SharedKey.Length);

        var completed = initiator.CompleteWithAck(result.Ack, responderPublicKey);
        Assert.NotNull(completed);
        Assert.Equal(result.SharedKey, completed.SharedKey);
    }

    [Fact]
    public void TheCompletedPairingNamesThePeer()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");

        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderPublicKey))!;
        var completed = initiator.CompleteWithAck(result.Ack, responderPublicKey)!;

        Assert.Equal(ResponderId.ToString("D"), completed.PeerDeviceId);
        Assert.Equal("Peer", completed.PeerDeviceName);
        Assert.Equal(InitiatorId, result.PeerDeviceId);
        Assert.Equal("Test PC", result.PeerDeviceName);
    }

    [Fact]
    public void AChallengeFromTheWrongKeyIsRejected()
    {
        var (responder, _) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var (_, strangerKey) = StartResponder();

        // Encrypted against a key the responder does not hold.
        Assert.Null(responder.AcceptChallenge(initiator.CreateChallenge(strangerKey)));
    }

    [Fact]
    public void ATamperedAckIsRejected()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderPublicKey))!;

        var tampered = result.Ack with { Tag = result.Ack.Tag.Select(b => (byte)(b ^ 0xFF)).ToArray() };

        Assert.Null(initiator.CompleteWithAck(tampered, responderPublicKey));
    }

    [Fact]
    public void AnAckForAnotherChallengeIsRejected()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderPublicKey))!;

        var wrongId = result.Ack with { ChallengeId = Guid.NewGuid() };

        Assert.Null(initiator.CompleteWithAck(wrongId, responderPublicKey));
    }

    [Fact]
    public void AnAckWhoseResponseHashDoesNotMatchIsRejected()
    {
        // The hash is what proves the responder actually decrypted the challenge
        // rather than replaying a well-formed but unrelated message.
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var challenge = initiator.CreateChallenge(responderPublicKey);
        var result = responder.AcceptChallenge(challenge)!;

        var other = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var otherResult = responder.AcceptChallenge(other.CreateChallenge(responderPublicKey))!;

        Assert.Null(initiator.CompleteWithAck(otherResult.Ack with { ChallengeId = challenge.ChallengeId }, responderPublicKey));
    }

    [Fact]
    public void ReplayingAChallengeIdIsRejected()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var challenge = initiator.CreateChallenge(responderPublicKey);

        Assert.NotNull(responder.AcceptChallenge(challenge));
        Assert.Null(responder.AcceptChallenge(challenge));
    }

    [Fact]
    public void AStaleChallengeIsRejected()
    {
        var (responder, responderPublicKey) = StartResponder();
        var initiator = PairingSession.StartInitiator(
            InitiatorId, "Test PC", clock: () => DateTimeOffset.UtcNow.AddMinutes(-10));

        Assert.Null(responder.AcceptChallenge(initiator.CreateChallenge(responderPublicKey)));
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~PairingSessionTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'PairingSession' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Pairing/PairingSession.cs`:

```csharp
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~PairingSessionTests`

Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Pairing/PairingSession.cs windows/tests/Hypo.Core.Tests/PairingSessionTests.cs
git commit -m "feat(windows): drive the pairing challenge and ack exchange"
```

---

## Task 13: Pairing over the LAN transport

Task 12 exercised the exchange in memory. This runs it over the real socket, in
the order the harness will, so a serialisation mistake surfaces here rather than
against a real device.

**Files:**
- Test: `windows/tests/Hypo.Core.Tests/PairingOverLanTests.cs`

- [ ] **Step 1: Write the test**

Create `windows/tests/Hypo.Core.Tests/PairingOverLanTests.cs`:

```csharp
using System.Text.Json;
using Hypo.Core.Pairing;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class PairingOverLanTests
{
    private const string InitiatorId = "550e8400-e29b-41d4-a716-446655440000";
    private static readonly Guid ResponderId = Guid.Parse("bbe296d6-0785-43d2-91b6-b135b72f4c41");

    [Fact]
    public void TheChallengeSurvivesAJsonRoundTrip()
    {
        var responder = PairingSession.StartResponder(ResponderId, "Peer");
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");

        var challenge = initiator.CreateChallenge(responder.AgreementPublicKey);
        var wire = JsonSerializer.Serialize(challenge, ProtocolJson.Options);
        var back = JsonSerializer.Deserialize<PairingChallengeMessage>(wire, ProtocolJson.Options)!;

        var result = responder.AcceptChallenge(back);

        Assert.NotNull(result);
    }

    [Fact]
    public void TheAckSurvivesAJsonRoundTrip()
    {
        var responder = PairingSession.StartResponder(ResponderId, "Peer");
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var responderKey = responder.AgreementPublicKey;

        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderKey))!;
        var wire = JsonSerializer.Serialize(result.Ack, ProtocolJson.Options);
        var back = JsonSerializer.Deserialize<PairingAckMessage>(wire, ProtocolJson.Options)!;

        var completed = initiator.CompleteWithAck(back, responderKey);

        Assert.NotNull(completed);
        Assert.Equal(result.SharedKey, completed.SharedKey);
    }

    [Fact]
    public void TheDerivedKeyEncryptsAClipboardPayloadBothWays()
    {
        // The point of pairing: the key it produces has to work for the traffic
        // that follows, with the associated data the sync path actually uses.
        var responder = PairingSession.StartResponder(ResponderId, "Peer");
        var initiator = PairingSession.StartInitiator(InitiatorId, "Test PC");
        var responderKey = responder.AgreementPublicKey;

        var result = responder.AcceptChallenge(initiator.CreateChallenge(responderKey))!;
        var completed = initiator.CompleteWithAck(result.Ack, responderKey)!;

        var plaintext = "clipboard contents"u8.ToArray();
        var nonce = new byte[Hypo.Core.Crypto.CryptoService.NonceSizeBytes];
        System.Security.Cryptography.RandomNumberGenerator.Fill(nonce);
        var aad = Hypo.Core.Crypto.CryptoService.BuildAssociatedData(InitiatorId);

        var (ciphertext, tag) = Hypo.Core.Crypto.CryptoService.Encrypt(
            plaintext, completed.SharedKey, nonce, aad);

        var decrypted = Hypo.Core.Crypto.CryptoService.Decrypt(
            ciphertext, result.SharedKey, nonce, tag, aad);

        Assert.Equal(plaintext, decrypted);
    }
}
```

- [ ] **Step 2: Run it**

Run: `cd windows && dotnet test --filter FullyQualifiedName~PairingOverLanTests`

Expected: PASS, 3 tests.

- [ ] **Step 3: Run the whole suite**

Run: `cd windows && dotnet test`

Expected: 0 failures.

- [ ] **Step 4: Commit**

```bash
git add windows/tests/Hypo.Core.Tests/PairingOverLanTests.cs
git commit -m "test(windows): pair over the wire format and use the derived key"
```

---
## Tasks 14 to 16 — still to be written

These remain scoped but not written.

Remaining scope:

14. **`SigningService`** — Ed25519 sign and verify via BouncyCastle, closing the one unimplemented row of spec §4.1.
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
