# Windows Client — Plan 2: LAN Interoperability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover a real macOS or Android Hypo peer on the local network, pair with it, and exchange a clipboard payload — proving the Windows client interoperates end to end.

**Architecture:** Plan 1 built `Hypo.Core`, which can encode, encrypt and frame protocol messages but cannot send them. This plan adds the pieces between that library and a socket: a streaming frame reader, an `ISyncTransport` abstraction, mDNS discovery, a LAN WebSocket client and server, Ed25519 pairing, and a console harness that ties them together. Still no Windows-specific API, no UI: everything here stays in `net10.0` so it can be developed and tested on any platform, and the harness runs anywhere.

**Tech Stack:** .NET 10, `Makaretu.Dns.Multicast`, `System.Net.WebSockets`, Kestrel, BouncyCastle (Ed25519), xUnit.

**Spec:** `docs/superpowers/specs/2026-08-28-windows-client-design.md` §3 (data flow), §4 (pairing), §7 (error handling).

**Prerequisite:** Plan 1, merged. `Hypo.Core` at 78 passing tests.

> **STATUS: INCOMPLETE — DO NOT EXECUTE PAST TASK 2.**
> Tasks 1 and 2 are written to this plan's own standard: failing test, complete
> implementation, exact commands, expected counts. Tasks 3–16 are currently only
> scoped, not written. A summarised task is a plan failure, not a shortcut — the
> whole reason Plan 1's subagents caught a JSON writer that escaped `+`, a
> converter override that was never invoked, and an associated-data formula that
> would have broken interoperability with both peer clients is that they were
> handed exact code to run and could watch it fail. Finish writing them before
> dispatching anyone past Task 2.

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

## Remaining tasks

The rest of this plan is written task-by-task in the same shape as Tasks 1 and 2 — failing test, exact implementation, exact commands and expected counts. They are:

3. **`DiscoveredPeer` and `IPeerDiscovery`** — the peer record and the publish/browse contract, with the TXT keys measured in spec §4.2 as typed properties.
4. **`MdnsPeerDiscovery`** — the `Makaretu.Dns.Multicast` implementation, filtering by service type (the spike found `ServiceInstanceDiscovered` fires for every service on the network) and resolving SRV, A and TXT into a `DiscoveredPeer`.
5. **Discovery integration test against a live peer** — an explicitly opt-in test, skipped unless `HYPO_LIVE_PEER=1`, that browses for 15 seconds and asserts at least one `_hypo._tcp` peer with a parseable `device_id` and `pub_key`. This is the regression guard for the interop the spike proved.
6. **`ISyncTransport` and `TransportEvents`** — connect, send, receive, disconnect, plus state-change and envelope-received events.
7. **`LanWebSocketClient`** — dials `ws://host:port/?device_id=<id>` and sets `X-Device-Id`, because the macOS server accepts either and sending both costs nothing. Framed send and receive over `FrameReader`.
8. **`LanWebSocketServer`** — Kestrel, accepting peer connections, extracting the device id from header or query, and surfacing received envelopes. Falls back to an ephemeral port when 7010 is taken, and reports the bound port so discovery advertises the real one (spec §7).
9. **Loopback transport test** — client and server in one process, exchanging a framed envelope both ways.
10. **`SigningService`** — Ed25519 sign and verify via BouncyCastle, closing the one unimplemented row of spec §4.1.
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
