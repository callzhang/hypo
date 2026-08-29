# Windows Client — Plan 3: Bidirectional LAN Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Receive a clipboard item copied on a real phone, on Windows — closing the one direction Plan 2 could not verify.

**Architecture:** Plan 2 proved Windows → phone end to end: pairing completes against a shipping Android client and a clipboard item arrives on the device. The reverse was never exercised, for a reason that has nothing to do with the protocol: the harness cannot both advertise itself and hold a paired key at the same time. This plan fixes exactly that and verifies the result against the same phone.

**Tech Stack:** .NET 10, the existing `Hypo.Core`.

**Spec:** `docs/superpowers/specs/2026-08-28-windows-client-design.md` §3.2 (inbound flow), §4.2 (discovery).

**Prerequisite:** Plan 2, merged. 169 tests, 167 passing and 2 skipped.

---

## Why this before the cloud relay

Plan 2's handoff put cloud relay, `DualSyncTransport`, `TransportManager` and the SQLite history store next. This plan goes ahead of all of them, because the LAN story has a hole that is cheap to close and expensive to leave:

Plan 2's Task 19 established that a clipboard item sent from Windows arrives on the phone, verified in the device's own logcat. The reverse was attempted and produced nothing, and the diagnosis was precise — **the phone only dials peers it has both paired with and discovered over mDNS**, and the harness never advertises while it holds a key:

| Harness mode | Advertises | Holds a paired key |
|--------------|-----------|--------------------|
| `pair` | no | yes, in memory, until the process exits |
| `listen` | yes | no — a fresh process starts with an empty store |

So the phone has no route back to us. Nothing about the protocol, the crypto or the framing is implicated; Plan 2 proved all three work in both directions at the message level. What is missing is that the two halves of the harness have never been in one process at one time.

Building the cloud relay on top of a LAN path that has only ever been verified one way would mean debugging two unproven transports at once the first time something fails.

---

## What this plan is NOT

- **No DPAPI.** Task 1 writes keys to a plain file, which is right for a development harness and wrong for a product. The Windows platform plan replaces it; the interface does not change.
- **No deduplication, no staleness eviction, no history.** Both directions flowing is the milestone. Duplicate suppression (protocol §6) matters once a message can arrive twice, which needs the cloud relay; peer eviction is Plan 2's carry-forward and does not block anything.
- **No cloud relay.** Next plan.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `windows/src/Hypo.Core/Abstractions/FileSecretStore.cs` | `ISecretStore` backed by a directory of files, so keys outlive a process |
| `windows/tests/Hypo.Core.Tests/FileSecretStoreTests.cs` | Its tests |
| `windows/tools/Hypo.Harness/Program.cs` | **Modified** — one long-running mode that advertises, listens and pairs |

---

## Task 1: Persist keys across processes

`InMemorySecretStore` was correct for Plan 1, where nothing outlived a test. A harness that pairs in one run and receives in the next needs the key to survive.

**Files:**
- Create: `windows/src/Hypo.Core/Abstractions/FileSecretStore.cs`
- Test: `windows/tests/Hypo.Core.Tests/FileSecretStoreTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/FileSecretStoreTests.cs`:

```csharp
using Hypo.Core.Abstractions;

namespace Hypo.Core.Tests;

public class FileSecretStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "hypo-secret-store-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_dir))
        {
            Directory.Delete(_dir, recursive: true);
        }
    }

    [Fact]
    public void ReturnsNullForAnAbsentKey()
    {
        Assert.Null(new FileSecretStore(_dir).Read("missing"));
    }

    [Fact]
    public void ReadsBackWhatItWrote()
    {
        var store = new FileSecretStore(_dir);

        store.Write("device-key", [0x01, 0x02, 0x03]);

        Assert.Equal(new byte[] { 0x01, 0x02, 0x03 }, store.Read("device-key"));
    }

    [Fact]
    public void SurvivesANewInstance()
    {
        // The whole point: pair in one process, receive in the next.
        new FileSecretStore(_dir).Write("device-key", [0xAB, 0xCD]);

        Assert.Equal(new byte[] { 0xAB, 0xCD }, new FileSecretStore(_dir).Read("device-key"));
    }

    [Fact]
    public void OverwritesAnExistingKey()
    {
        var store = new FileSecretStore(_dir);

        store.Write("device-key", [0x01]);
        store.Write("device-key", [0x02]);

        Assert.Equal(new byte[] { 0x02 }, store.Read("device-key"));
    }

    [Fact]
    public void DeleteRemovesAKeyAndReportsWhetherItExisted()
    {
        var store = new FileSecretStore(_dir);
        store.Write("device-key", [0x01]);

        Assert.True(store.Delete("device-key"));
        Assert.False(store.Delete("device-key"));
        Assert.Null(store.Read("device-key"));
    }

    [Fact]
    public void NormalisesKeysToLowercase()
    {
        var store = new FileSecretStore(_dir);

        store.Write("Device-KEY", [0x01]);

        Assert.Equal(new byte[] { 0x01 }, store.Read("device-key"));
    }

    [Fact]
    public void RejectsAKeyThatWouldEscapeTheDirectory()
    {
        // Device ids come off the network. A store that pastes one into a path
        // is a directory traversal waiting to happen.
        var store = new FileSecretStore(_dir);

        Assert.Throws<ArgumentException>(() => store.Write("../escape", [0x01]));
        Assert.Throws<ArgumentException>(() => store.Read("../../etc/passwd"));
    }

    [Fact]
    public void AcceptsARealDeviceId()
    {
        var store = new FileSecretStore(_dir);

        store.Write("bbe296d6-0785-43d2-91b6-b135b72f4c41", [0x01]);

        Assert.NotNull(store.Read("bbe296d6-0785-43d2-91b6-b135b72f4c41"));
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~FileSecretStoreTests`

Expected: a missing-type compile error for `FileSecretStore`. See the standing
note in Plan 2 on which code the compiler picks.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Abstractions/FileSecretStore.cs`:

```csharp
namespace Hypo.Core.Abstractions;

/// <summary>
/// Stores secrets as files in one directory, so they outlive a process.
///
/// Development use only: the bytes are written unencrypted. The Windows client
/// stores keys through DPAPI instead — see the design spec section 4.5 — and
/// that implementation satisfies this same interface, so nothing above it
/// changes.
/// </summary>
public sealed class FileSecretStore : ISecretStore
{
    private readonly string _directory;

    public FileSecretStore(string directory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(directory);
        _directory = directory;
        Directory.CreateDirectory(_directory);
    }

    public byte[]? Read(string key)
    {
        var path = PathFor(key);
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }

    public void Write(string key, ReadOnlySpan<byte> value) =>
        File.WriteAllBytes(PathFor(key), value);

    public bool Delete(string key)
    {
        var path = PathFor(key);
        if (!File.Exists(path))
        {
            return false;
        }

        File.Delete(path);
        return true;
    }

    /// <summary>
    /// Keys are device ids that arrive over the network, so the name is
    /// validated rather than trusted: anything outside the expected alphabet is
    /// rejected instead of being pasted into a path.
    /// </summary>
    private string PathFor(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);

        var normalised = key.ToLowerInvariant();
        foreach (var c in normalised)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c != '-' && c != '_')
            {
                throw new ArgumentException(
                    $"A secret key may contain only letters, digits, '-' and '_'; got '{key}'.",
                    nameof(key));
            }
        }

        return Path.Combine(_directory, normalised);
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~FileSecretStoreTests`

Expected: PASS, 8 tests.

- [ ] **Step 5: Run the whole suite**

Run: `cd windows && dotnet test`

Expected: 177 total, 175 passing and 2 skipped.

- [ ] **Step 6: Commit**

```bash
git add windows/src/Hypo.Core/Abstractions/FileSecretStore.cs windows/tests/Hypo.Core.Tests/FileSecretStoreTests.cs
git commit -m "feat(windows): persist secrets to a directory"
```

---

## Task 2: One harness mode that advertises, listens and pairs

The phone dials peers it has paired with **and** can currently see. Splitting
those across two processes is why nothing ever came back.

**Files:**
- Modify: `windows/tools/Hypo.Harness/Program.cs`

- [ ] **Step 1: Switch the store to the persistent one**

Replace `var store = new InMemorySecretStore();` with:

```csharp
// Keys must outlive the process: we pair in one run and may receive in the next.
var storeDir = Environment.GetEnvironmentVariable("HYPO_STORE_DIR")
               ?? Path.Combine(Path.GetTempPath(), "hypo-harness-keys");
var store = new FileSecretStore(storeDir);
```

- [ ] **Step 2: Advertise from within `PairAsync`**

The harness must be visible while it holds the key. After a successful pairing,
before the wait loop, start the server and advertise:

```csharp
    store.Write(completed.PeerDeviceId, completed.SharedKey);
    Console.WriteLine($"Paired with {completed.PeerDeviceName} ({completed.PeerDeviceId}).");

    // Stay discoverable. The peer dials devices it has paired with and can see;
    // being paired is not enough on its own.
    await using var server = new LanWebSocketServer();
    server.EnvelopeReceived += (_, e) => PrintClipboard(e);
    await server.StartAsync();

    await using var advert = new MdnsPeerDiscovery();
    await advert.AdvertiseAsync(deviceName, server.BoundPort, new Dictionary<string, string>
    {
        ["device_id"] = deviceId,
        ["pub_key"] = Convert.ToBase64String(session.AgreementPublicKey),
        ["signing_pub_key"] = Convert.ToBase64String(SigningService.DerivePublicKey(SigningService.GeneratePrivateKey())),
        ["version"] = "3.0.0-harness",
    });

    Console.WriteLine($"Listening on {server.BoundPort} and advertising as \"{deviceName}\".");
    Console.WriteLine("Copy something on the peer; Ctrl+C to exit.");
```

- [ ] **Step 3: Build**

Run: `cd windows && dotnet build`

Expected: `Build succeeded`, 0 warnings.

- [ ] **Step 4: Confirm the advertisement is visible**

With the harness running, from another terminal:

`dns-sd -B _hypo._tcp local`

Expected: the harness's name appears alongside the real peers. If it does not,
nothing later in this plan can work — stop and report.

- [ ] **Step 5: Commit**

```bash
git add windows/tools/Hypo.Harness/Program.cs
git commit -m "feat(windows): keep the harness discoverable while it holds a key"
```

---

## Task 3: Receive a clipboard item from a real phone

The milestone.

**Files:**
- Modify: `docs/superpowers/plans/2026-08-29-windows-bidirectional-lan.md` (record the outcome)

- [ ] **Step 1: Pair and stay up**

```
cd windows && dotnet run --project tools/Hypo.Harness -- discover
cd windows && dotnet run --project tools/Hypo.Harness -- pair <device-id>
```

Leave it running.

- [ ] **Step 2: Confirm the phone can see us**

`dns-sd -B _hypo._tcp local` should list the harness. On the phone, the paired
device list should show it as reachable.

- [ ] **Step 3: Copy something on the phone**

This needs a human: `cmd clipboard set-primary-clip` is not implemented on the
test device, so the copy cannot be driven over adb.

Expected: the harness prints the copied text.

- [ ] **Step 4: If nothing arrives, narrow it before changing anything**

In order, because each answer changes what the next step means:

1. `adb logcat | grep -i clipboard` — did the phone detect the copy at all?
   Android restricts background clipboard reads; the app needs its
   accessibility service enabled, which it has on the test device.
2. Did the phone try to connect to us? Look for our address in its
   `WebSocketTransportClient` logs.
3. Did it connect and send something we dropped? Compare against Plan 2's
   finding that the pairing channel is unframed — a clipboard envelope should
   arrive as a *binary* frame with a length prefix, so a text frame here would
   mean something unexpected.

- [ ] **Step 5: Record the outcome**

Add a "Task 3 outcome" section stating what ran and what happened, success or
not. Plan 2's value came as much from its recorded failures as its successes.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/plans/2026-08-29-windows-bidirectional-lan.md
git commit -m "docs: record the reverse-direction interoperability attempt"
```

---

## Done criteria

1. `cd windows && dotnet test` passes, 177 total with 2 skipped.
2. The harness appears in `dns-sd -B _hypo._tcp local` while paired.
3. Text copied on a real phone is printed by the harness.
4. Criterion 3's outcome is recorded either way.

## What comes after

Cloud relay, `DualSyncTransport` and `TransportManager`, then the SQLite history
store — Plan 2's original handoff list, minus what this plan closes. Message-id
deduplication (protocol §6) belongs with the cloud relay, since that is when a
message can first arrive twice. Peer staleness eviction remains open from Plan 2.
