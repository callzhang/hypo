# Windows Client — Plan 1: Core Protocol and Crypto Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Hypo.Core`, a platform-neutral .NET library that encodes, decodes, encrypts, decrypts and compresses Hypo protocol messages byte-compatibly with the existing macOS and Android clients.

**Architecture:** A single `net10.0` class library with no Windows APIs, no UI and no network code, plus an xUnit suite that validates it against the repository's shared test vectors — the same JSON fixtures the macOS and Android suites already consume. Every public behaviour in this plan is verified against a fixture or a round-trip property, never against hand-written expectations that could drift from the other clients.

**Tech Stack:** .NET 10 (LTS), C#, System.Text.Json, `System.Security.Cryptography` (`AesGcm`, `HKDF`), BouncyCastle.Cryptography (X25519), xUnit.

**Spec:** `docs/superpowers/specs/2026-08-28-windows-client-design.md` §2 (architecture, library selection), §3.1–3.2 (wire format), §4.1 (primitive mapping), §8.1 (shared vectors).

**Scope boundary:** This plan stops at pure protocol and crypto. Transport, mDNS, pairing, storage, clipboard access, UI and packaging are Plans 2–5. Nothing in this plan opens a socket or touches the registry.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `windows/Hypo.sln` | Solution root for all Windows work |
| `windows/src/Hypo.Core/Hypo.Core.csproj` | `net10.0`, no Windows-specific references |
| `windows/src/Hypo.Core/Protocol/Base64Compat.cs` | Padding-tolerant base64 decoding (Android emits unpadded base64) |
| `windows/src/Hypo.Core/Protocol/Base64ByteArrayConverter.cs` | `System.Text.Json` converter applying `Base64Compat` to `byte[]` members |
| `windows/src/Hypo.Core/Protocol/Iso8601DateTimeOffsetConverter.cs` | Writes timestamps with a `Z` designator, as both existing clients do |
| `windows/src/Hypo.Core/Protocol/EncryptionMetadata.cs` | `algorithm` / `nonce` / `tag` |
| `windows/src/Hypo.Core/Protocol/EnvelopePayload.cs` | Envelope payload: content type, ciphertext, device identity, target, encryption |
| `windows/src/Hypo.Core/Protocol/SyncEnvelope.cs` | The top-level message |
| `windows/src/Hypo.Core/Protocol/ClipboardPayload.cs` | The plaintext document that lives inside the ciphertext |
| `windows/src/Hypo.Core/Protocol/ProtocolJson.cs` | Shared protocol vocabulary: the `ContentType` and `MessageType` enums with their wire strings, plus the single shared `JsonSerializerOptions` |
| `windows/src/Hypo.Core/Protocol/TransportFrameCodec.cs` | 4-byte big-endian length prefix framing plus size limits |
| `windows/src/Hypo.Core/Crypto/CryptoService.cs` | AES-256-GCM, X25519 agreement, HKDF-SHA256 |
| `windows/src/Hypo.Core/Utils/GzipCompressor.cs` | Gzip container compress and decompress |
| `windows/src/Hypo.Core/Abstractions/ISecretStore.cs` | Key persistence contract; DPAPI implementation arrives in Plan 3 |
| `windows/src/Hypo.Core/Abstractions/InMemorySecretStore.cs` | Test and development implementation |
| `windows/tests/Hypo.Core.Tests/Hypo.Core.Tests.csproj` | xUnit suite |
| `windows/tests/Hypo.Core.Tests/RepoFixtures.cs` | Locates the repository root and the shared fixture files |
| `windows/tests/Hypo.Core.Tests/*Tests.cs` | One test file per unit under test |
| `tests/crypto_test_vectors.json` | **Modified** — gains a `gzip` section shared by all three clients |

Protocol types live together in one folder because they change together: a wire-format change touches the models, the converter and the codec in one edit. They are split into one file per type rather than one large `Protocol.cs` so that each stays small enough to reason about in isolation.

---

## Task 1: Solution and project scaffolding

**Files:**
- Create: `windows/Hypo.sln`
- Create: `windows/src/Hypo.Core/Hypo.Core.csproj`
- Create: `windows/tests/Hypo.Core.Tests/Hypo.Core.Tests.csproj`
- Create: `windows/.gitignore`

- [ ] **Step 1: Verify the .NET 10 SDK is present**

Run: `dotnet --list-sdks`

Expected: at least one line beginning with `10.`. If not, install the .NET 10 SDK before continuing — every later step depends on it.

- [ ] **Step 2: Create the solution and projects**

```bash
cd windows
dotnet new sln --name Hypo --format sln
dotnet new classlib --name Hypo.Core --output src/Hypo.Core --framework net10.0
dotnet new xunit --name Hypo.Core.Tests --output tests/Hypo.Core.Tests --framework net10.0
dotnet sln add src/Hypo.Core/Hypo.Core.csproj tests/Hypo.Core.Tests/Hypo.Core.Tests.csproj
dotnet add tests/Hypo.Core.Tests/Hypo.Core.Tests.csproj reference src/Hypo.Core/Hypo.Core.csproj
dotnet add src/Hypo.Core/Hypo.Core.csproj package BouncyCastle.Cryptography
rm -f src/Hypo.Core/Class1.cs
rm -f tests/Hypo.Core.Tests/UnitTest1.cs
```

Two details that bite on SDK 10.0.400:

- `--format sln` is required. `dotnet new sln` now defaults to the newer `.slnx`
  XML format, which would not produce the `windows/Hypo.sln` this plan and the
  CI job in Task 17 both reference.
- The xunit template writes a placeholder `UnitTest1.cs` containing an empty but
  discoverable `[Fact]`. Left in place it silently adds one to every later test
  count in this plan, so it is removed here.

- [ ] **Step 3: Set language and analysis options on `Hypo.Core`**

Replace the contents of `windows/src/Hypo.Core/Hypo.Core.csproj` `<PropertyGroup>` so it reads:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <LangVersion>latest</LangVersion>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="BouncyCastle.Cryptography" />
  </ItemGroup>

</Project>
```

Leave the version attribute that `dotnet add package` wrote on the `PackageReference` if one is present; do not pin it by hand.

`TargetFramework` is `net10.0`, not `net10.0-windows`. This is load-bearing: it is what mechanically prevents Windows APIs from leaking into the core layer (spec §2, dependency rule).

- [ ] **Step 4: Add the ignore file**

Create `windows/.gitignore`:

```gitignore
bin/
obj/
*.user
TestResults/
.vs/
```

`.vs/` is not build output — Visual Studio creates it the first time someone
opens the solution on Windows, which is the normal case from Plan 3 onward.

- [ ] **Step 5: Verify the solution builds**

Run: `cd windows && dotnet build`

Expected: `Build succeeded` with 0 errors and 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add windows/
git commit -m "build(windows): scaffold Hypo.Core solution and test project"
```

---

## Task 2: Fixture location helper

The test suite must read the repository's shared fixtures. Tests run from `windows/tests/Hypo.Core.Tests/bin/<config>/net10.0/`, so the repository root has to be discovered by walking up.

**Files:**
- Create: `windows/tests/Hypo.Core.Tests/RepoFixtures.cs`
- Test: `windows/tests/Hypo.Core.Tests/RepoFixturesTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/RepoFixturesTests.cs`:

```csharp
namespace Hypo.Core.Tests;

public class RepoFixturesTests
{
    [Fact]
    public void LocatesTheSharedCryptoVectorFile()
    {
        Assert.True(File.Exists(RepoFixtures.CryptoVectorsPath));
    }

    [Fact]
    public void LocatesTheSharedFrameVectorFile()
    {
        Assert.True(File.Exists(RepoFixtures.FrameVectorsPath));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~RepoFixturesTests`

Expected: FAIL to compile with `CS0103: The name 'RepoFixtures' does not exist in the current context`.

- [ ] **Step 3: Write the implementation**

Create `windows/tests/Hypo.Core.Tests/RepoFixtures.cs`:

```csharp
namespace Hypo.Core.Tests;

/// <summary>
/// Resolves the repository root so tests can read the fixtures shared with the
/// macOS and Android suites. See spec section 8.1.
/// </summary>
public static class RepoFixtures
{
    private const string CryptoVectorsRelative = "tests/crypto_test_vectors.json";
    private const string FrameVectorsRelative = "tests/transport/frame_vectors.json";

    public static string Root { get; } = FindRoot();

    public static string CryptoVectorsPath => Combine(CryptoVectorsRelative);

    public static string FrameVectorsPath => Combine(FrameVectorsRelative);

    private static string Combine(string relative) =>
        Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar));

    private static string FindRoot()
    {
        var marker = CryptoVectorsRelative.Replace('/', Path.DirectorySeparatorChar);
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, marker)))
            {
                return dir.FullName;
            }
        }

        throw new InvalidOperationException(
            $"Could not locate the repository root by walking up from '{AppContext.BaseDirectory}' " +
            $"looking for '{CryptoVectorsRelative}'.");
    }
}
```

The marker is the crypto vector file itself rather than `.git`, so the helper fails loudly and specifically if the fixtures are ever moved.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~RepoFixturesTests`

Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/tests/Hypo.Core.Tests/RepoFixtures.cs windows/tests/Hypo.Core.Tests/RepoFixturesTests.cs
git commit -m "test(windows): locate shared protocol fixtures from the test suite"
```

---

## Task 3: Padding-tolerant base64

Android encodes with `Base64.withoutPadding()`. .NET's `Convert.FromBase64String` throws on unpadded input, so every base64 field arriving from Android would fail to parse. macOS handles this by re-padding before decoding; Windows must do the same.

**Files:**
- Create: `windows/src/Hypo.Core/Protocol/Base64Compat.cs`
- Test: `windows/tests/Hypo.Core.Tests/Base64CompatTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/Base64CompatTests.cs`:

```csharp
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class Base64CompatTests
{
    [Theory]
    [InlineData("3q2+7w==", new byte[] { 0xDE, 0xAD, 0xBE, 0xEF })]
    [InlineData("3q2+7w", new byte[] { 0xDE, 0xAD, 0xBE, 0xEF })]
    [InlineData("qrvM", new byte[] { 0xAA, 0xBB, 0xCC })]
    [InlineData("", new byte[0])]
    public void DecodesPaddedAndUnpaddedInput(string input, byte[] expected)
    {
        Assert.Equal(expected, Base64Compat.Decode(input));
    }

    [Fact]
    public void DecodesUnpaddedInputRequiringTwoPadCharacters()
    {
        // "AA" decodes to a single 0x00 byte and needs "==" appended.
        Assert.Equal(new byte[] { 0x00 }, Base64Compat.Decode("AA"));
    }

    [Fact]
    public void ThrowsOnInputThatIsNotValidBase64()
    {
        Assert.Throws<FormatException>(() => Base64Compat.Decode("not base64!"));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~Base64CompatTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'Hypo.Core.Protocol' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Protocol/Base64Compat.cs`:

```csharp
namespace Hypo.Core.Protocol;

/// <summary>
/// Base64 decoding that tolerates missing padding. The Android client encodes
/// with Base64.withoutPadding(), which Convert.FromBase64String rejects.
/// </summary>
public static class Base64Compat
{
    public static byte[] Decode(string value)
    {
        ArgumentNullException.ThrowIfNull(value);

        var remainder = value.Length % 4;
        var padded = remainder == 0 ? value : value + new string('=', 4 - remainder);
        return Convert.FromBase64String(padded);
    }
}
```

A remainder of 1 is not valid base64; `Convert.FromBase64String` rejects it after padding, which is the behaviour we want.

Two properties of this implementation are deliberate rather than oversights:

- **Whitespace is not tolerated.** `Convert.FromBase64String` on its own strips
  embedded whitespace, but computing the remainder over the raw length means a
  line-wrapped input gets the wrong number of pad characters and is rejected.
  No client in this repo emits wrapped base64, and being strict with untrusted
  peer data is the behaviour we want here — such input surfaces as a
  `JsonException` through the converter in Task 4 and the message is dropped.
- **Padding allocates.** `value + new string('=', ...)` copies the whole string
  to append one or two characters. For a 10 MB file payload (~13.3 MB of
  base64) that is a large-object-heap allocation per inbound message. It is not
  worth optimising without profiling data, but if the transport work in Plan 2
  shows it mattering, `Convert.TryFromBase64Chars` over a rented buffer is the
  route.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~Base64CompatTests`

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Protocol/Base64Compat.cs windows/tests/Hypo.Core.Tests/Base64CompatTests.cs
git commit -m "feat(windows): decode unpadded base64 for Android interoperability"
```

---

## Task 4: JSON converter for base64 byte arrays

`System.Text.Json` already maps `byte[]` to base64 strings, but its reader rejects unpadded input. This converter routes reads through `Base64Compat`.

**Files:**
- Create: `windows/src/Hypo.Core/Protocol/Base64ByteArrayConverter.cs`
- Test: `windows/tests/Hypo.Core.Tests/Base64ByteArrayConverterTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/Base64ByteArrayConverterTests.cs`:

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class Base64ByteArrayConverterTests
{
    private sealed record Holder
    {
        [JsonPropertyName("value")]
        [JsonConverter(typeof(Base64ByteArrayConverter))]
        public byte[] Value { get; init; } = [];
    }

    [Fact]
    public void ReadsUnpaddedBase64()
    {
        var holder = JsonSerializer.Deserialize<Holder>("""{"value":"3q2+7w"}""");
        Assert.NotNull(holder);
        Assert.Equal(new byte[] { 0xDE, 0xAD, 0xBE, 0xEF }, holder.Value);
    }

    [Fact]
    public void WritesPaddedBase64()
    {
        var json = JsonSerializer.Serialize(new Holder { Value = [0xDE, 0xAD, 0xBE, 0xEF] });
        Assert.Equal("""{"value":"3q2+7w=="}""", json);
    }

    [Fact]
    public void ReadsJsonNullAsAnEmptyArray()
    {
        var holder = JsonSerializer.Deserialize<Holder>("""{"value":null}""");
        Assert.NotNull(holder);
        Assert.Empty(holder.Value);
    }

    [Fact]
    public void ThrowsJsonExceptionOnMalformedBase64()
    {
        var error = Assert.Throws<JsonException>(
            () => JsonSerializer.Deserialize<Holder>("""{"value":"not base64!"}"""));

        Assert.IsType<FormatException>(error.InnerException);
    }
}
```

That last test drives the `try`/`catch` in `Read` below. This converter sits on
the boundary that decodes untrusted peer data — later tasks route ciphertext,
nonce and tag through it — and callers there catch `JsonException` to mean "the
peer sent malformed protocol data, drop the message". An unwrapped
`FormatException` would slip past that handler, and carries no field path.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~Base64ByteArrayConverterTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'Base64ByteArrayConverter' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Protocol/Base64ByteArrayConverter.cs`:

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>
/// Serialises byte arrays as base64 strings, accepting unpadded input on read.
/// </summary>
public sealed class Base64ByteArrayConverter : JsonConverter<byte[]>
{
    /// <summary>
    /// Required. For reference types this defaults to false, which means
    /// System.Text.Json never calls Read on a null token and assigns null
    /// straight to the property — making the null branch below dead code.
    /// </summary>
    public override bool HandleNull => true;

    public override byte[] Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null)
        {
            return [];
        }

        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException($"Expected a base64 string but found {reader.TokenType}.");
        }

        try
        {
            return Base64Compat.Decode(reader.GetString()!);
        }
        catch (FormatException ex)
        {
            throw new JsonException("Expected a valid base64 string.", ex);
        }
    }

    public override void Write(Utf8JsonWriter writer, byte[] value, JsonSerializerOptions options)
    {
        writer.WriteBase64StringValue(value);
    }
}
```

Two details that are easy to get wrong here, both caught by the tests above:

- Write with `WriteBase64StringValue`, not `WriteStringValue`. The default
  `System.Text.Json` encoder escapes `+` as `\u002B`, so `WriteStringValue`
  would emit `3q2\u002B7w==` where macOS and Android emit `3q2+7w==`. Both
  forms parse identically, so this is not a wire-compatibility break, but it
  inflates every payload and diverges from what the other two clients produce.
  `WriteBase64StringValue` writes the base64 alphabet verbatim and is what the
  built-in `byte[]` converter uses.
- The `try`/`catch` is load-bearing, not defence in depth. It was measured:
  removing it lets a bare `FormatException` escape `JsonSerializer.Deserialize`
  entirely. `System.Text.Json` auto-wraps `FormatException` only when its own
  reader methods raise it (`Utf8JsonReader.GetDateTimeOffset` and friends);
  `Convert.FromBase64String` is user code on this path and is not wrapped.
  Keep the comment that records this — a reviewer previously concluded the
  guard was redundant after testing the reader path instead.
- `HandleNull` must be overridden to `true`, as noted in the code comment. It has
  one side effect on the write path: a null `byte[]` is routed to `Write` and
  emits `""` rather than `null`. Every protocol model in this plan is serialised
  through `ProtocolJson.Options`, whose `WhenWritingNull` drops the property
  before the converter sees it, so the effect is unreachable today. It would
  become visible only if a later task added a nullable `byte[]?` field
  serialised without those options.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~Base64ByteArrayConverterTests`

Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Protocol/Base64ByteArrayConverter.cs windows/tests/Hypo.Core.Tests/Base64ByteArrayConverterTests.cs
git commit -m "feat(windows): add padding-tolerant base64 JSON converter"
```

---

## Task 5: Protocol enums and the shared serializer options

**Files:**
- Create: `windows/src/Hypo.Core/Protocol/ProtocolJson.cs`
- Create: `windows/src/Hypo.Core/Protocol/Iso8601DateTimeOffsetConverter.cs`
- Test: `windows/tests/Hypo.Core.Tests/ProtocolJsonTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/ProtocolJsonTests.cs`:

```csharp
using System.Globalization;
using System.Text.Json;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class ProtocolJsonTests
{
    private sealed record Sample
    {
        public string ContentType { get; init; } = "";
        public string? DevicePlatform { get; init; }
    }

    [Fact]
    public void UsesSnakeCaseForPropertyNames()
    {
        var json = JsonSerializer.Serialize(new Sample { ContentType = "text" }, ProtocolJson.Options);
        Assert.Contains("\"content_type\":\"text\"", json);
    }

    [Fact]
    public void OmitsNullProperties()
    {
        var json = JsonSerializer.Serialize(new Sample { ContentType = "text" }, ProtocolJson.Options);
        Assert.DoesNotContain("device_platform", json);
    }

    [Theory]
    [InlineData(ContentType.Text, "text")]
    [InlineData(ContentType.Link, "link")]
    [InlineData(ContentType.Image, "image")]
    [InlineData(ContentType.File, "file")]
    public void SerialisesContentTypeAsALowercaseString(ContentType value, string expected)
    {
        Assert.Equal($"\"{expected}\"", JsonSerializer.Serialize(value, ProtocolJson.Options));
    }

    [Theory]
    [InlineData(MessageType.Clipboard, "clipboard")]
    [InlineData(MessageType.Control, "control")]
    [InlineData(MessageType.Error, "error")]
    public void SerialisesMessageTypeAsALowercaseString(MessageType value, string expected)
    {
        Assert.Equal($"\"{expected}\"", JsonSerializer.Serialize(value, ProtocolJson.Options));
    }

    [Fact]
    public void WritesTimestampsWithAZDesignatorAndNoFractionalSeconds()
    {
        var value = DateTimeOffset.Parse("2025-10-03T00:00:00Z", CultureInfo.InvariantCulture);
        Assert.Equal("\"2025-10-03T00:00:00Z\"", JsonSerializer.Serialize(value, ProtocolJson.Options));
    }

    [Fact]
    public void WritesNonUtcTimestampsAsUtc()
    {
        var value = DateTimeOffset.Parse("2025-10-03T08:00:00+08:00", CultureInfo.InvariantCulture);
        Assert.Equal("\"2025-10-03T00:00:00Z\"", JsonSerializer.Serialize(value, ProtocolJson.Options));
    }

    [Fact]
    public void TruncatesSubSecondPrecisionRatherThanRounding()
    {
        var value = DateTimeOffset.Parse("2025-10-03T00:00:00.999Z", CultureInfo.InvariantCulture);
        Assert.Equal("\"2025-10-03T00:00:00Z\"", JsonSerializer.Serialize(value, ProtocolJson.Options));
    }

    [Fact]
    public void ReadsBothZAndNumericOffsetTimestamps()
    {
        var withZ = JsonSerializer.Deserialize<DateTimeOffset>("\"2025-10-03T00:00:00Z\"", ProtocolJson.Options);
        var withOffset = JsonSerializer.Deserialize<DateTimeOffset>("\"2025-10-03T00:00:00+00:00\"", ProtocolJson.Options);
        Assert.Equal(withZ, withOffset);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~ProtocolJsonTests`

Expected: FAIL to compile with `CS0246` for `ProtocolJson`, `ContentType` and `MessageType`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Protocol/ProtocolJson.cs`:

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>Clipboard content types. Protocol section 3.2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ContentType>))]
public enum ContentType
{
    [JsonStringEnumMemberName("text")] Text,
    [JsonStringEnumMemberName("link")] Link,
    [JsonStringEnumMemberName("image")] Image,
    [JsonStringEnumMemberName("file")] File,
}

/// <summary>Envelope message types. Protocol section 2.1.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<MessageType>))]
public enum MessageType
{
    [JsonStringEnumMemberName("clipboard")] Clipboard,
    [JsonStringEnumMemberName("control")] Control,
    [JsonStringEnumMemberName("error")] Error,
}

/// <summary>
/// The single serializer configuration used for every protocol message.
/// Snake case matches the macOS codec's convertToSnakeCase strategy and the
/// Android client's field names.
/// </summary>
public static class ProtocolJson
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new Iso8601DateTimeOffsetConverter() },
    };
}
```

Also create `windows/src/Hypo.Core/Protocol/Iso8601DateTimeOffsetConverter.cs`:

```csharp
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>
/// Writes timestamps the way the macOS and Android clients write them: ISO 8601
/// in UTC with a "Z" designator and no fractional seconds. System.Text.Json's
/// built-in DateTimeOffset writer emits a numeric offset ("+00:00") instead,
/// which diverges from tests/transport/frame_vectors.json and from what both
/// existing clients put on the wire.
/// </summary>
public sealed class Iso8601DateTimeOffsetConverter : JsonConverter<DateTimeOffset>
{
    private const string Format = "yyyy-MM-dd'T'HH:mm:ss'Z'";

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetDateTimeOffset();

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToUniversalTime().ToString(Format, CultureInfo.InvariantCulture));
}
```

`macos/Sources/HypoApp/Services/TransportFrameCodec.swift:16` sets
`encoder.dateEncodingStrategy = .iso8601`, which is `ISO8601DateFormatter` with
`.withInternetDateTime` — `Z`, no fractional seconds. Kotlin's
`Instant.toString()` matches. Dropping sub-second precision is therefore
alignment, not loss: the other two clients already drop it, and the timestamp's
only protocol role is the five-minute replay window.

Reading stays permissive. `reader.GetDateTimeOffset()` accepts both forms, so a
peer sending `+00:00` still parses. Only what we emit is constrained.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~ProtocolJsonTests`

Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Protocol/ProtocolJson.cs windows/src/Hypo.Core/Protocol/Iso8601DateTimeOffsetConverter.cs windows/tests/Hypo.Core.Tests/ProtocolJsonTests.cs
git commit -m "feat(windows): define protocol enums and shared serializer options"
```

---

## Task 6: Envelope models

Field names and optionality mirror `macos/Sources/HypoApp/Services/SyncEngine.swift` lines 29–205.

**Files:**
- Create: `windows/src/Hypo.Core/Protocol/EncryptionMetadata.cs`
- Create: `windows/src/Hypo.Core/Protocol/EnvelopePayload.cs`
- Create: `windows/src/Hypo.Core/Protocol/SyncEnvelope.cs`
- Test: `windows/tests/Hypo.Core.Tests/SyncEnvelopeTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/SyncEnvelopeTests.cs`:

```csharp
using System.Text.Json;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class SyncEnvelopeTests
{
    private const string AndroidStyleJson = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "timestamp": "2025-10-03T00:00:00Z",
      "version": "1.0",
      "type": "clipboard",
      "payload": {
        "content_type": "text",
        "ciphertext": "3q2+7w",
        "device_id": "mac-device",
        "target": "android-device",
        "encryption": { "algorithm": "AES-256-GCM", "nonce": "qrvM", "tag": "EBES" }
      }
    }
    """;

    [Fact]
    public void DeserialisesAnUnpaddedAndroidStyleEnvelope()
    {
        var envelope = JsonSerializer.Deserialize<SyncEnvelope>(AndroidStyleJson, ProtocolJson.Options);

        Assert.NotNull(envelope);
        Assert.Equal(Guid.Parse("11111111-1111-1111-1111-111111111111"), envelope.Id);
        Assert.Equal("1.0", envelope.Version);
        Assert.Equal(MessageType.Clipboard, envelope.Type);
        Assert.Equal(ContentType.Text, envelope.Payload.ContentType);
        Assert.Equal(new byte[] { 0xDE, 0xAD, 0xBE, 0xEF }, envelope.Payload.Ciphertext);
        Assert.Equal("mac-device", envelope.Payload.DeviceId);
        Assert.Equal("android-device", envelope.Payload.Target);
        Assert.Equal(new byte[] { 0xAA, 0xBB, 0xCC }, envelope.Payload.Encryption.Nonce);
        Assert.Equal(new byte[] { 0x10, 0x11, 0x12 }, envelope.Payload.Encryption.Tag);
    }

    [Fact]
    public void OmitsAbsentOptionalFieldsWhenSerialising()
    {
        var envelope = new SyncEnvelope
        {
            Id = Guid.Parse("11111111-1111-1111-1111-111111111111"),
            Timestamp = DateTimeOffset.Parse("2025-10-03T00:00:00Z"),
            Type = MessageType.Clipboard,
            Payload = new EnvelopePayload
            {
                ContentType = ContentType.Text,
                Ciphertext = [0xDE, 0xAD, 0xBE, 0xEF],
                DeviceId = "mac-device",
                Encryption = new EncryptionMetadata { Nonce = [0xAA], Tag = [0xBB] },
            },
        };

        var json = JsonSerializer.Serialize(envelope, ProtocolJson.Options);

        Assert.DoesNotContain("device_platform", json);
        Assert.DoesNotContain("device_name", json);
        Assert.DoesNotContain("target", json);
        Assert.Contains("\"version\":\"1.0\"", json);
        Assert.Contains("\"algorithm\":\"AES-256-GCM\"", json);
    }

    [Fact]
    public void RoundTripsThroughJson()
    {
        var original = JsonSerializer.Deserialize<SyncEnvelope>(AndroidStyleJson, ProtocolJson.Options)!;
        var json = JsonSerializer.Serialize(original, ProtocolJson.Options);
        var again = JsonSerializer.Deserialize<SyncEnvelope>(json, ProtocolJson.Options)!;

        Assert.Equal(original.Id, again.Id);
        Assert.Equal(original.Payload.Ciphertext, again.Payload.Ciphertext);
        Assert.Equal(original.Payload.Encryption.Tag, again.Payload.Encryption.Tag);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~SyncEnvelopeTests`

Expected: FAIL to compile with `CS0246` for `SyncEnvelope`, `EnvelopePayload` and `EncryptionMetadata`.

- [ ] **Step 3: Write `EncryptionMetadata`**

Create `windows/src/Hypo.Core/Protocol/EncryptionMetadata.cs`:

```csharp
using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>AES-GCM parameters carried alongside the ciphertext. Protocol section 3.5.</summary>
public sealed record EncryptionMetadata
{
    public const string AesGcmAlgorithm = "AES-256-GCM";

    public string Algorithm { get; init; } = AesGcmAlgorithm;

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Nonce { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Tag { get; init; }
}
```

- [ ] **Step 4: Write `EnvelopePayload`**

Create `windows/src/Hypo.Core/Protocol/EnvelopePayload.cs`:

```csharp
using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>
/// The envelope payload. Mirrors SyncEnvelope.Payload in the macOS client.
/// DeviceId is a bare lowercase UUID with no platform prefix (protocol v1.1+).
/// </summary>
public sealed record EnvelopePayload
{
    public required ContentType ContentType { get; init; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Ciphertext { get; init; }

    public required string DeviceId { get; init; }

    public string? DevicePlatform { get; init; }

    public string? DeviceName { get; init; }

    public string? Target { get; init; }

    public required EncryptionMetadata Encryption { get; init; }
}
```

- [ ] **Step 5: Write `SyncEnvelope`**

Create `windows/src/Hypo.Core/Protocol/SyncEnvelope.cs`:

```csharp
namespace Hypo.Core.Protocol;

/// <summary>The top-level protocol message. Protocol section 2.1.</summary>
public sealed record SyncEnvelope
{
    public const string CurrentVersion = "1.0";

    public required Guid Id { get; init; }

    public required DateTimeOffset Timestamp { get; init; }

    public string Version { get; init; } = CurrentVersion;

    public required MessageType Type { get; init; }

    public required EnvelopePayload Payload { get; init; }
}
```

`Guid` is handled natively by `System.Text.Json`, reading and writing as a
string. `DateTimeOffset` is **not** safe to leave to the built-in writer: it
emits a numeric offset (`2025-10-03T00:00:00+00:00`) where both existing clients
emit `2025-10-03T00:00:00Z`. Task 5 registers
`Iso8601DateTimeOffsetConverter` on `ProtocolJson.Options` to correct that, and
the shared frame vector in Task 8 is what catches it if the registration is ever
lost.

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~SyncEnvelopeTests`

Expected: PASS, 3 tests.

- [ ] **Step 7: Commit**

```bash
git add windows/src/Hypo.Core/Protocol/EncryptionMetadata.cs windows/src/Hypo.Core/Protocol/EnvelopePayload.cs windows/src/Hypo.Core/Protocol/SyncEnvelope.cs windows/tests/Hypo.Core.Tests/SyncEnvelopeTests.cs
git commit -m "feat(windows): add sync envelope protocol models"
```

---

## Task 7: Clipboard payload model

This is the plaintext document that sits inside the ciphertext. It is gzip-compressed before encryption (protocol section 3.6). The wire field is `data_base64`, not `data`.

**Files:**
- Create: `windows/src/Hypo.Core/Protocol/ClipboardPayload.cs`
- Test: `windows/tests/Hypo.Core.Tests/ClipboardPayloadTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/ClipboardPayloadTests.cs`:

```csharp
using System.Text.Json;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class ClipboardPayloadTests
{
    [Fact]
    public void DeserialisesTheAndroidWireShape()
    {
        const string json = """
        {
          "content_type": "text",
          "data_base64": "SGVsbG8sIEh5cG8h",
          "metadata": { "size": "12", "hash": "abc" },
          "compressed": true
        }
        """;

        var payload = JsonSerializer.Deserialize<ClipboardPayload>(json, ProtocolJson.Options);

        Assert.NotNull(payload);
        Assert.Equal(ContentType.Text, payload.ContentType);
        Assert.Equal("Hello, Hypo!", System.Text.Encoding.UTF8.GetString(payload.Data));
        Assert.True(payload.Compressed);
        Assert.Equal("12", payload.Metadata!["size"]);
    }

    [Fact]
    public void SerialisesDataAsDataBase64AndNeverAsAByteArray()
    {
        var payload = new ClipboardPayload
        {
            ContentType = ContentType.Text,
            Data = System.Text.Encoding.UTF8.GetBytes("Hello, Hypo!"),
            Compressed = true,
        };

        var json = JsonSerializer.Serialize(payload, ProtocolJson.Options);

        Assert.Contains("\"data_base64\":\"SGVsbG8sIEh5cG8h\"", json);
        Assert.DoesNotContain("\"data\":", json);
        Assert.DoesNotContain("metadata", json);
    }

    [Fact]
    public void TreatsAMissingCompressedFlagAsFalse()
    {
        const string json = """{ "content_type": "file", "data_base64": "AA" }""";

        var payload = JsonSerializer.Deserialize<ClipboardPayload>(json, ProtocolJson.Options);

        Assert.NotNull(payload);
        Assert.False(payload.Compressed);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~ClipboardPayloadTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'ClipboardPayload' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Protocol/ClipboardPayload.cs`:

```csharp
using System.Text.Json.Serialization;

namespace Hypo.Core.Protocol;

/// <summary>
/// The plaintext document carried inside the envelope ciphertext.
/// Serialised, gzipped, then encrypted (protocol section 3.6).
/// </summary>
public sealed record ClipboardPayload
{
    public required ContentType ContentType { get; init; }

    /// <summary>
    /// The clipboard bytes. Always written as "data_base64"; the macOS client
    /// dropped the array-valued "data" field because it inflates large payloads
    /// three- to fourfold.
    /// </summary>
    [JsonPropertyName("data_base64")]
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public required byte[] Data { get; init; }

    public IReadOnlyDictionary<string, string>? Metadata { get; init; }

    public bool Compressed { get; init; }
}
```

`Metadata` is `string`-to-`string` because that is what the macOS model declares; values such as `size` arrive as strings on the wire.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~ClipboardPayloadTests`

Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Protocol/ClipboardPayload.cs windows/tests/Hypo.Core.Tests/ClipboardPayloadTests.cs
git commit -m "feat(windows): add clipboard payload model"
```

---

## Task 8: Transport frame codec

Frames are a 4-byte big-endian length prefix followed by the JSON body. The ceiling is 20 MB, matching `SizeConstants.maxTransportPayloadBytes` on macOS.

**Files:**
- Create: `windows/src/Hypo.Core/Protocol/TransportFrameCodec.cs`
- Test: `windows/tests/Hypo.Core.Tests/TransportFrameCodecTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/TransportFrameCodecTests.cs`:

```csharp
using System.Buffers.Binary;
using System.Text;
using System.Text.Json.Nodes;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class TransportFrameCodecTests
{
    private static SyncEnvelope SampleEnvelope() => new()
    {
        Id = Guid.Parse("11111111-1111-1111-1111-111111111111"),
        Timestamp = DateTimeOffset.Parse("2025-10-03T00:00:00Z"),
        Type = MessageType.Clipboard,
        Payload = new EnvelopePayload
        {
            ContentType = ContentType.Text,
            Ciphertext = [0x01, 0x02, 0x03],
            DeviceId = "deviceA",
            Target = "deviceB",
            Encryption = new EncryptionMetadata { Nonce = [0xAA], Tag = [0xBB] },
        },
    };

    [Fact]
    public void RoundTripsAnEnvelope()
    {
        var codec = new TransportFrameCodec();

        var decoded = codec.Decode(codec.Encode(SampleEnvelope()));

        Assert.Equal("deviceA", decoded.Payload.DeviceId);
        Assert.Equal("deviceB", decoded.Payload.Target);
        Assert.Equal(new byte[] { 0x01, 0x02, 0x03 }, decoded.Payload.Ciphertext);
    }

    [Fact]
    public void WritesABigEndianLengthPrefix()
    {
        var codec = new TransportFrameCodec();

        var frame = codec.Encode(SampleEnvelope());
        var declared = BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(0, 4));

        Assert.Equal((uint)(frame.Length - 4), declared);
    }

    [Fact]
    public void DecodesTheSharedFrameVectorAndReEncodesToAnEquivalentBody()
    {
        var codec = new TransportFrameCodec();
        var vectors = JsonNode.Parse(File.ReadAllText(RepoFixtures.FrameVectorsPath))!.AsArray();
        var vector = vectors[0]!;
        var frame = Convert.FromBase64String(vector["base64"]!.GetValue<string>());
        var expectedDeviceId = vector["envelope"]!["payload"]!["device_id"]!.GetValue<string>();

        var decoded = codec.Decode(frame);
        Assert.Equal(expectedDeviceId, decoded.Payload.DeviceId);

        // Compare parsed bodies, not raw bytes: JSON key order is not part of
        // the contract and differs between Swift, Kotlin and .NET.
        var originalBody = JsonNode.Parse(Encoding.UTF8.GetString(frame, 4, frame.Length - 4))!;
        var reEncoded = codec.Encode(decoded);
        var reEncodedBody = JsonNode.Parse(Encoding.UTF8.GetString(reEncoded, 4, reEncoded.Length - 4))!;
        Assert.True(JsonNode.DeepEquals(originalBody, reEncodedBody));
    }

    [Fact]
    public void ThrowsWhenTheFrameIsShorterThanItsLengthPrefixClaims()
    {
        var codec = new TransportFrameCodec();

        var error = Assert.Throws<TransportFrameException>(
            () => codec.Decode(new byte[] { 0x00, 0x00, 0x00, 0x05, 0x01 }));

        Assert.Equal(TransportFrameError.Truncated, error.Error);
    }

    [Fact]
    public void ThrowsWhenTheFrameIsShorterThanTheLengthPrefixItself()
    {
        var codec = new TransportFrameCodec();

        var error = Assert.Throws<TransportFrameException>(() => codec.Decode(new byte[] { 0x00, 0x00 }));

        Assert.Equal(TransportFrameError.Truncated, error.Error);
    }

    [Fact]
    public void ThrowsWhenTheLengthPrefixExceedsTheCeiling()
    {
        var codec = new TransportFrameCodec();
        var frame = new byte[8];
        BinaryPrimitives.WriteUInt32BigEndian(
            frame.AsSpan(0, 4), (uint)TransportFrameCodec.DefaultMaxPayloadBytes + 1);

        var error = Assert.Throws<TransportFrameException>(() => codec.Decode(frame));

        Assert.Equal(TransportFrameError.PayloadTooLarge, error.Error);
    }

    [Fact]
    public void ThrowsWhenTheLengthPrefixIsUIntMaxValue()
    {
        var codec = new TransportFrameCodec();
        var frame = new byte[] { 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };

        var error = Assert.Throws<TransportFrameException>(() => codec.Decode(frame));

        Assert.Equal(TransportFrameError.PayloadTooLarge, error.Error);
    }

    [Fact]
    public void ThrowsWhenTheEncodedBodyExceedsTheConfiguredCeiling()
    {
        var codec = new TransportFrameCodec(maxPayloadBytes: 1);

        var error = Assert.Throws<TransportFrameException>(() => codec.Encode(SampleEnvelope()));

        Assert.Equal(TransportFrameError.PayloadTooLarge, error.Error);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~TransportFrameCodecTests`

Expected: FAIL to compile with `CS0246` for `TransportFrameCodec`, `TransportFrameException` and `TransportFrameError`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Protocol/TransportFrameCodec.cs`:

```csharp
using System.Buffers.Binary;
using System.Text.Json;

namespace Hypo.Core.Protocol;

public enum TransportFrameError
{
    PayloadTooLarge,
    Truncated,
}

public sealed class TransportFrameException(TransportFrameError error, string message)
    : Exception(message)
{
    public TransportFrameError Error { get; } = error;
}

/// <summary>
/// Length-prefixed framing for the LAN transport: a 4-byte big-endian body
/// length followed by the JSON-encoded envelope.
/// </summary>
public sealed class TransportFrameCodec
{
    /// <summary>Matches SizeConstants.maxTransportPayloadBytes on macOS.</summary>
    public const int DefaultMaxPayloadBytes = 20 * 1024 * 1024;

    private const int LengthPrefixBytes = 4;

    private readonly int _maxPayloadBytes;

    public TransportFrameCodec(int maxPayloadBytes = DefaultMaxPayloadBytes)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxPayloadBytes);
        _maxPayloadBytes = maxPayloadBytes;
    }

    public byte[] Encode(SyncEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);

        var body = JsonSerializer.SerializeToUtf8Bytes(envelope, ProtocolJson.Options);
        if (body.Length > _maxPayloadBytes)
        {
            throw new TransportFrameException(
                TransportFrameError.PayloadTooLarge,
                $"Encoded envelope is {body.Length} bytes, exceeding the {_maxPayloadBytes} byte ceiling.");
        }

        var frame = new byte[LengthPrefixBytes + body.Length];
        BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(0, LengthPrefixBytes), (uint)body.Length);
        body.CopyTo(frame.AsSpan(LengthPrefixBytes));
        return frame;
    }

    public SyncEnvelope Decode(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < LengthPrefixBytes)
        {
            throw new TransportFrameException(
                TransportFrameError.Truncated,
                $"Frame is {frame.Length} bytes, shorter than the {LengthPrefixBytes} byte length prefix.");
        }

        var declaredLength = BinaryPrimitives.ReadUInt32BigEndian(frame[..LengthPrefixBytes]);
        if (declaredLength > _maxPayloadBytes)
        {
            throw new TransportFrameException(
                TransportFrameError.PayloadTooLarge,
                $"Frame declares {declaredLength} bytes, exceeding the {_maxPayloadBytes} byte ceiling.");
        }

        var body = frame[LengthPrefixBytes..];
        if (body.Length < declaredLength)
        {
            throw new TransportFrameException(
                TransportFrameError.Truncated,
                $"Frame declares {declaredLength} body bytes but carries {body.Length}.");
        }

        return JsonSerializer.Deserialize<SyncEnvelope>(body[..(int)declaredLength], ProtocolJson.Options)
               ?? throw new TransportFrameException(
                   TransportFrameError.Truncated,
                   "Frame body deserialised to null.");
    }
}
```

The declared-length check runs before the body-length check so an
attacker-supplied huge prefix is rejected without allocating. The two tests
above cover that branch directly: a peer controls the prefix, and later plans
put a real socket behind this. The `uint.MaxValue` case also protects the
`(int)declaredLength` cast — the comparison promotes both operands to `long`,
so there is no wraparound, and the cast is unreachable except when already
bounded by an `int`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~TransportFrameCodecTests`

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Protocol/TransportFrameCodec.cs windows/tests/Hypo.Core.Tests/TransportFrameCodecTests.cs
git commit -m "feat(windows): add length-prefixed transport frame codec"
```

---

## Task 9: AES-256-GCM encryption

**Files:**
- Create: `windows/src/Hypo.Core/Crypto/CryptoService.cs`
- Test: `windows/tests/Hypo.Core.Tests/CryptoServiceAesGcmTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/CryptoServiceAesGcmTests.cs`:

```csharp
using System.Text.Json.Nodes;
using Hypo.Core.Crypto;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class CryptoServiceAesGcmTests
{
    private static JsonNode Vectors() =>
        JsonNode.Parse(File.ReadAllText(RepoFixtures.CryptoVectorsPath))!;

    private static byte[] Field(JsonNode testCase, string name) =>
        Base64Compat.Decode(testCase[name]!.GetValue<string>());

    [Fact]
    public void DecryptsTheSharedAesGcmVector()
    {
        var testCase = Vectors()["test_cases"]!.AsArray()[0]!;
        var aad = Field(testCase, "aad_base64");

        var plaintext = CryptoService.Decrypt(
            ciphertext: Field(testCase, "ciphertext_base64"),
            key: Field(testCase, "key_base64"),
            nonce: Field(testCase, "nonce_base64"),
            tag: Field(testCase, "tag_base64"),
            associatedData: aad.Length == 0 ? null : aad);

        Assert.Equal(Field(testCase, "plaintext_base64"), plaintext);
    }

    [Fact]
    public void EncryptsToTheSharedAesGcmVector()
    {
        var testCase = Vectors()["test_cases"]!.AsArray()[0]!;
        var aad = Field(testCase, "aad_base64");

        var (ciphertext, tag) = CryptoService.Encrypt(
            plaintext: Field(testCase, "plaintext_base64"),
            key: Field(testCase, "key_base64"),
            nonce: Field(testCase, "nonce_base64"),
            associatedData: aad.Length == 0 ? null : aad);

        Assert.Equal(Field(testCase, "ciphertext_base64"), ciphertext);
        Assert.Equal(Field(testCase, "tag_base64"), tag);
    }

    [Fact]
    public void RoundTripsWithAssociatedData()
    {
        var key = new byte[32];
        var nonce = new byte[12];
        // A CSPRNG, not Random: CryptoService.Encrypt's remarks require a fresh
        // nonce from a secure source and no reuse under one key, and this test is
        // the shape Plan 2 will copy when it builds the send path.
        RandomNumberGenerator.Fill(key);
        RandomNumberGenerator.Fill(nonce);
        var plaintext = System.Text.Encoding.UTF8.GetBytes("clipboard contents");
        var aad = System.Text.Encoding.UTF8.GetBytes("device-id|2026-08-28T00:00:00Z");

        var (ciphertext, tag) = CryptoService.Encrypt(plaintext, key, nonce, aad);

        Assert.Equal(plaintext, CryptoService.Decrypt(ciphertext, key, nonce, tag, aad));
    }

    [Fact]
    public void RejectsATamperedTag()
    {
        var key = new byte[32];
        var nonce = new byte[12];
        var plaintext = System.Text.Encoding.UTF8.GetBytes("clipboard contents");
        var (ciphertext, tag) = CryptoService.Encrypt(plaintext, key, nonce, default);
        tag[0] ^= 0xFF;

        Assert.Throws<System.Security.Cryptography.AuthenticationTagMismatchException>(
            () => CryptoService.Decrypt(ciphertext, key, nonce, tag, default));
    }

    [Fact]
    public void BuildsAssociatedDataFromTheLowercasedDeviceId()
    {
        const string deviceId = "550E8400-E29B-41D4-A716-446655440000";

        Assert.Equal(
            System.Text.Encoding.UTF8.GetBytes(deviceId.ToLowerInvariant()),
            CryptoService.BuildAssociatedData(deviceId));
    }

    [Fact]
    public void AssociatedDataCarriesNothingButTheDeviceId()
    {
        // Guards the correction in section 4.1: protocol section 9.2 once
        // described this as device_id + timestamp. Neither shipping client does
        // that, and a client that did would fail authentication on every
        // message against every peer.
        const string deviceId = "550e8400-e29b-41d4-a716-446655440000";

        Assert.Equal(deviceId.Length, CryptoService.BuildAssociatedData(deviceId).Length);
    }

    [Fact]
    public void RejectsMismatchedAssociatedData()
    {
        var key = new byte[32];
        var nonce = new byte[12];
        var plaintext = System.Text.Encoding.UTF8.GetBytes("clipboard contents");
        var (ciphertext, tag) = CryptoService.Encrypt(
            plaintext, key, nonce, System.Text.Encoding.UTF8.GetBytes("device-a"));

        Assert.Throws<System.Security.Cryptography.AuthenticationTagMismatchException>(
            () => CryptoService.Decrypt(
                ciphertext, key, nonce, tag, System.Text.Encoding.UTF8.GetBytes("device-b")));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~CryptoServiceAesGcmTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'Hypo.Core.Crypto' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Crypto/CryptoService.cs`:

```csharp
using System.Security.Cryptography;
using System.Text;

namespace Hypo.Core.Crypto;

/// <summary>
/// Protocol cryptography. Constants and algorithms must match CryptoConstants
/// in the macOS client and its Android counterpart byte for byte; see spec
/// section 4.1.
/// </summary>
public static class CryptoService
{
    public const int KeySizeBytes = 32;
    public const int NonceSizeBytes = 12;
    public const int TagSizeBytes = 16;

    /// <summary>UTF-8 bytes of "hypo-clipboard-ecdh".</summary>
    public static ReadOnlySpan<byte> HkdfSalt => "hypo-clipboard-ecdh"u8;

    /// <summary>UTF-8 bytes of "hypo-aes-256-gcm".</summary>
    public static ReadOnlySpan<byte> HkdfInfo => "hypo-aes-256-gcm"u8;

    public static (byte[] Ciphertext, byte[] Tag) Encrypt(
        ReadOnlySpan<byte> plaintext,
        ReadOnlySpan<byte> key,
        ReadOnlySpan<byte> nonce,
        ReadOnlySpan<byte> associatedData)
    {
        using var aes = new AesGcm(key, TagSizeBytes);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[TagSizeBytes];
        aes.Encrypt(nonce, plaintext, ciphertext, tag, associatedData);
        return (ciphertext, tag);
    }

    public static byte[] Decrypt(
        ReadOnlySpan<byte> ciphertext,
        ReadOnlySpan<byte> key,
        ReadOnlySpan<byte> nonce,
        ReadOnlySpan<byte> tag,
        ReadOnlySpan<byte> associatedData)
    {
        using var aes = new AesGcm(key, TagSizeBytes);
        var plaintext = new byte[ciphertext.Length];
        aes.Decrypt(nonce, ciphertext, tag, plaintext, associatedData);
        return plaintext;
    }

    /// <summary>
    /// Builds the associated data for a clipboard payload: the UTF-8 bytes of
    /// the sender's device id, lowercased.
    /// </summary>
    /// <remarks>
    /// Protocol section 9.2 describes this as "device_id + timestamp", but
    /// neither shipping client does that. macOS uses
    /// <c>Data(entry.deviceId.utf8)</c> when encrypting and
    /// <c>Data(senderId.utf8)</c> when decrypting; Android uses
    /// <c>normalizedSenderDeviceId.encodeToByteArray()</c>. Including a
    /// timestamp here would make every message fail authentication against both
    /// peers. The wire format is defined by the implementations, not the prose.
    ///
    /// Lowercasing follows Android, which normalises defensively on both sides.
    /// macOS instead trusts the wire value, relying on device ids already being
    /// lowercase UUIDs as protocol v1.1 requires. For any peer that honours that
    /// requirement the two behaviours are identical, and the defensive form
    /// fails closed rather than silently mismatching.
    /// </remarks>
    public static byte[] BuildAssociatedData(string deviceId)
    {
        ArgumentNullException.ThrowIfNull(deviceId);
        return Encoding.UTF8.GetBytes(deviceId.ToLowerInvariant());
    }
}
```

Associated data is a `ReadOnlySpan<byte>`, so callers with no associated data pass `default` (an empty span). GCM treats zero-length associated data and absent associated data identically, so this matches the macOS client, which passes `nil`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~CryptoServiceAesGcmTests`

Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Crypto/CryptoService.cs windows/tests/Hypo.Core.Tests/CryptoServiceAesGcmTests.cs
git commit -m "feat(windows): add AES-256-GCM encryption verified against shared vectors"
```

---

## Task 10: X25519 key agreement and HKDF derivation

**Files:**
- Modify: `windows/src/Hypo.Core/Crypto/CryptoService.cs`
- Test: `windows/tests/Hypo.Core.Tests/CryptoServiceKeyAgreementTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/CryptoServiceKeyAgreementTests.cs`:

```csharp
using System.Text.Json.Nodes;
using Hypo.Core.Crypto;
using Hypo.Core.Protocol;

namespace Hypo.Core.Tests;

public class CryptoServiceKeyAgreementTests
{
    private static JsonNode KeyAgreement() =>
        JsonNode.Parse(File.ReadAllText(RepoFixtures.CryptoVectorsPath))!["key_agreement"]!;

    private static byte[] Field(string name) =>
        Base64Compat.Decode(KeyAgreement()[name]!.GetValue<string>());

    [Fact]
    public void DerivesTheSharedKeyFromTheSharedVector()
    {
        var derived = CryptoService.DeriveKey(
            privateKey: Field("alice_private_base64"),
            peerPublicKey: Field("bob_public_base64"));

        Assert.Equal(Field("shared_key_base64"), derived);
    }

    [Fact]
    public void BothSidesDeriveTheSameKey()
    {
        var fromAlice = CryptoService.DeriveKey(Field("alice_private_base64"), Field("bob_public_base64"));
        var fromBob = CryptoService.DeriveKey(Field("bob_private_base64"), Field("alice_public_base64"));

        Assert.Equal(fromAlice, fromBob);
    }

    [Fact]
    public void DerivesAThirtyTwoByteKey()
    {
        var derived = CryptoService.DeriveKey(Field("alice_private_base64"), Field("bob_public_base64"));

        Assert.Equal(CryptoService.KeySizeBytes, derived.Length);
    }

    [Fact]
    public void DerivesTheAdvertisedPublicKeyFromAPrivateKey()
    {
        Assert.Equal(Field("alice_public_base64"), CryptoService.DerivePublicKey(Field("alice_private_base64")));
        Assert.Equal(Field("bob_public_base64"), CryptoService.DerivePublicKey(Field("bob_private_base64")));
    }

    [Fact]
    public void ADifferentSaltProducesADifferentKey()
    {
        var withDefault = CryptoService.DeriveKey(Field("alice_private_base64"), Field("bob_public_base64"));
        var withOther = CryptoService.DeriveKey(
            Field("alice_private_base64"),
            Field("bob_public_base64"),
            salt: System.Text.Encoding.UTF8.GetBytes("different-salt"));

        Assert.NotEqual(withDefault, withOther);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~CryptoServiceKeyAgreementTests`

Expected: FAIL to compile with `CS0117: 'CryptoService' does not contain a definition for 'DeriveKey'`.

- [ ] **Step 3: Add the key agreement members**

Add these `using` directives at the top of `windows/src/Hypo.Core/Crypto/CryptoService.cs`:

```csharp
using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Parameters;
```

Then add these members inside the `CryptoService` class, after `BuildAssociatedData`:

```csharp
    /// <summary>
    /// X25519 agreement followed by HKDF-SHA256, matching
    /// CryptoService.deriveKey in the macOS client.
    /// </summary>
    public static byte[] DeriveKey(
        byte[] privateKey,
        byte[] peerPublicKey,
        byte[]? salt = null,
        byte[]? info = null)
    {
        ArgumentNullException.ThrowIfNull(privateKey);
        ArgumentNullException.ThrowIfNull(peerPublicKey);

        var agreement = new X25519Agreement();
        agreement.Init(new X25519PrivateKeyParameters(privateKey));

        var sharedSecret = new byte[agreement.AgreementSize];
        agreement.CalculateAgreement(new X25519PublicKeyParameters(peerPublicKey), sharedSecret, 0);

        try
        {
            return HKDF.DeriveKey(
                HashAlgorithmName.SHA256,
                sharedSecret,
                KeySizeBytes,
                salt ?? HkdfSalt.ToArray(),
                info ?? HkdfInfo.ToArray());
        }
        finally
        {
            CryptographicOperations.ZeroMemory(sharedSecret);
        }
    }

    /// <summary>Derives the X25519 public key advertised for a private key.</summary>
    public static byte[] DerivePublicKey(byte[] privateKey)
    {
        ArgumentNullException.ThrowIfNull(privateKey);
        return new X25519PrivateKeyParameters(privateKey).GeneratePublicKey().GetEncoded();
    }
```

The shared secret is zeroed after derivation; it is the one intermediate value that would otherwise linger in the heap.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~CryptoServiceKeyAgreementTests`

Expected: PASS, 5 tests.

If `DerivesTheSharedKeyFromTheSharedVector` fails while `BothSidesDeriveTheSameKey` passes, the agreement is correct but the HKDF inputs differ — check that the salt and info constants are the UTF-8 bytes of `hypo-clipboard-ecdh` and `hypo-aes-256-gcm` and that the output length is 32.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Crypto/CryptoService.cs windows/tests/Hypo.Core.Tests/CryptoServiceKeyAgreementTests.cs
git commit -m "feat(windows): add X25519 agreement and HKDF derivation"
```

---

## Task 11: Gzip compression

Compression sits between JSON encoding and encryption and is always on (protocol section 3.6).

**Files:**
- Create: `windows/src/Hypo.Core/Utils/GzipCompressor.cs`
- Test: `windows/tests/Hypo.Core.Tests/GzipCompressorTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/GzipCompressorTests.cs`:

```csharp
using System.Text;
using Hypo.Core.Utils;

namespace Hypo.Core.Tests;

public class GzipCompressorTests
{
    [Fact]
    public void RoundTripsText()
    {
        var original = Encoding.UTF8.GetBytes(new string('a', 5000));

        Assert.Equal(original, GzipCompressor.Decompress(GzipCompressor.Compress(original)));
    }

    [Fact]
    public void RoundTripsAnEmptyInput()
    {
        Assert.Empty(GzipCompressor.Decompress(GzipCompressor.Compress([])));
    }

    [Fact]
    public void EmitsAGzipContainerNotRawDeflate()
    {
        var compressed = GzipCompressor.Compress(Encoding.UTF8.GetBytes("hello"));

        // RFC 1952 header: magic 0x1f 0x8b, compression method 0x08 (deflate).
        Assert.Equal(0x1F, compressed[0]);
        Assert.Equal(0x8B, compressed[1]);
        Assert.Equal(0x08, compressed[2]);
    }

    [Fact]
    public void CompressesRepetitiveTextSubstantially()
    {
        var original = Encoding.UTF8.GetBytes(new string('a', 10000));

        Assert.True(GzipCompressor.Compress(original).Length < original.Length / 10);
    }

    [Fact]
    public void ThrowsOnInputThatIsNotGzip()
    {
        Assert.ThrowsAny<Exception>(() => GzipCompressor.Decompress([0x00, 0x01, 0x02, 0x03]));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~GzipCompressorTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'Hypo.Core.Utils' could not be found`.

- [ ] **Step 3: Write the implementation**

Create `windows/src/Hypo.Core/Utils/GzipCompressor.cs`:

```csharp
using System.IO.Compression;

namespace Hypo.Core.Utils;

/// <summary>
/// Gzip container compression (RFC 1952), matching the macOS client's
/// Compression framework usage and Android's GZIPOutputStream. Raw deflate is
/// not interoperable with either and must not be substituted.
/// </summary>
public static class GzipCompressor
{
    public static byte[] Compress(ReadOnlySpan<byte> data)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.Optimal, leaveOpen: true))
        {
            gzip.Write(data);
        }

        return output.ToArray();
    }

    public static byte[] Decompress(ReadOnlySpan<byte> data)
    {
        using var input = new MemoryStream(data.ToArray(), writable: false);
        using var gzip = new GZipStream(input, CompressionMode.Decompress);
        using var output = new MemoryStream();
        gzip.CopyTo(output);
        return output.ToArray();
    }
}
```

`leaveOpen: true` matters: the `GZipStream` must be disposed to flush its trailer, but disposing it must not close the `MemoryStream` before `ToArray` reads it.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~GzipCompressorTests`

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/src/Hypo.Core/Utils/GzipCompressor.cs windows/tests/Hypo.Core.Tests/GzipCompressorTests.cs
git commit -m "feat(windows): add gzip compression helper"
```

---

## Task 12: Add a shared gzip interop vector

Spec section 8.1 records that gzip is the one protocol stage with no shared fixture, so a divergence — most plausibly raw deflate versus a gzip container — would not be caught until two real devices failed to talk. This task closes that gap for all three clients.

The vector deliberately does **not** assert that compression produces specific bytes. Gzip output varies legitimately with compression level, the `MTIME` field and the OS byte, so a byte-equality assertion on compressed output would produce false failures. What every client must agree on is that a given gzip container decompresses to a given plaintext.

**Files:**
- Modify: `tests/crypto_test_vectors.json`
- Test: `windows/tests/Hypo.Core.Tests/GzipVectorTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/GzipVectorTests.cs`:

```csharp
using System.Text.Json.Nodes;
using Hypo.Core.Protocol;
using Hypo.Core.Utils;

namespace Hypo.Core.Tests;

public class GzipVectorTests
{
    private static JsonNode Gzip() =>
        JsonNode.Parse(File.ReadAllText(RepoFixtures.CryptoVectorsPath))!["gzip"]!;

    private static byte[] Field(string name) => Base64Compat.Decode(Gzip()[name]!.GetValue<string>());

    [Fact]
    public void DecompressesTheSharedGzipVector()
    {
        Assert.Equal(Field("plaintext_base64"), GzipCompressor.Decompress(Field("compressed_base64")));
    }

    [Fact]
    public void OwnCompressionRoundTripsToTheSharedPlaintext()
    {
        var plaintext = Field("plaintext_base64");

        Assert.Equal(plaintext, GzipCompressor.Decompress(GzipCompressor.Compress(plaintext)));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~GzipVectorTests`

Expected: FAIL with a `NullReferenceException` from `Gzip()`, because `tests/crypto_test_vectors.json` has no `gzip` key yet.

- [ ] **Step 3: Add the vector to the shared fixture**

Adding a top-level key here cannot break the existing macOS or Android suites: Swift's `JSONDecoder` ignores keys that are absent from a type's `CodingKeys`, and the Android suite builds its decoder with `Json { ignoreUnknownKeys = true }`. Tasks 13 and 14 then make those suites actually read it.

Edit `tests/crypto_test_vectors.json`. Add the `gzip` object as a new top-level key, after `key_agreement`. The file becomes:

```json
{
  "hkdf": {
    "salt_base64": "aHlwby1jbGlwYm9hcmQtZWNkaA==",
    "info_base64": "aHlwby1hZXMtMjU2LWdjbQ=="
  },
  "test_cases": [
    {
      "name": "rfc-5116-case-17",
      "plaintext_base64": "AAAAAAAAAAAAAAAAAAAAAA==",
      "key_base64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      "nonce_base64": "AAAAAAAAAAAAAAAA",
      "aad_base64": "",
      "ciphertext_base64": "zqdAPU1ga24HTsXTuvOdGA==",
      "tag_base64": "0NHIp5mZa/AmW5i11Iq5GQ=="
    }
  ],
  "key_agreement": {
    "alice_private_base64": "9pKJeIXAyyCj5M0QagsVvDYHlPF+cymJCbB5iHPsdEE=",
    "alice_public_base64": "ACG/n84Mm4nrPPX0x3zvphyXzeGoAAkCqfhvA9xTvBU=",
    "bob_private_base64": "gYj5PaHP9CCg3aR/WASi21CJR0mxp/tojUc2JR1RKSU=",
    "bob_public_base64": "0Bdsk+FlRveSB70cQcwTnaksP5iNPa1bAK2Yb7bpsls=",
    "shared_key_base64": "qeEkuYq/7Hrvr8Fc5UxPyzBF8zoxmqhBjhG1x6Nal7Q="
  },
  "gzip": {
    "description": "A gzip container (RFC 1952) holding a representative ClipboardPayload document. Every client must decompress compressed_base64 to plaintext_base64, and must round-trip plaintext_base64 through its own compressor. Clients must NOT assert that their own compression reproduces compressed_base64 byte for byte: gzip output varies legitimately with compression level, the MTIME field and the OS byte.",
    "plaintext_base64": "eyJjb250ZW50X3R5cGUiOiJ0ZXh0IiwiZGF0YV9iYXNlNjQiOiJTR1ZzYkc4c0lFaDVjRzhoIiwiY29tcHJlc3NlZCI6dHJ1ZX0=",
    "compressed_base64": "H4sIAAAAAAAA/6tWSs7PK0nNK4kvqSxIVbJSKkmtKFHSUUpJLEmMT0osTjUzAQoGu4cVJ7lbFHu6Zpgmu1tkABUk5+cWFKUWF6emKFmVFJWm1gIAa9Z3oUoAAAA="
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~GzipVectorTests`

Expected: PASS, 2 tests.

- [ ] **Step 5: Verify the fixture is still valid JSON and the other vectors still load**

Run: `cd windows && dotnet test --filter FullyQualifiedName~CryptoService`

Expected: PASS, 19 tests. This confirms the edit did not corrupt the sections the crypto tests read. (The count grew past the fixture work itself because the AES and X25519 length guards added seven tests to those same classes.)

- [ ] **Step 6: Commit**

```bash
git add tests/crypto_test_vectors.json windows/tests/Hypo.Core.Tests/GzipVectorTests.cs
git commit -m "test: add shared gzip interoperability vector"
```

---

## Task 13: Back-fill the gzip vector into the macOS suite

A vector that only one client reads proves nothing. This task makes the macOS suite assert the same bytes.

Adding a top-level key to the fixture is safe for both existing suites: Swift's `JSONDecoder` ignores keys absent from `CodingKeys`, and the Android suite constructs its decoder with `Json { ignoreUnknownKeys = true }`. Neither breaks if this task and Task 14 are deferred.

**Requires:** macOS with a Swift toolchain. If the executing engineer is on
Windows, skip this task and Task 14, hand them to someone with the toolchains,
and note the deferral in the pull request. No later task depends on them.

Both toolchains are available on the machine this plan was written for, so the
gzip vector can be verified across all three clients rather than two — which is
the whole point of adding it.

**Files:**
- Modify: `macos/Tests/HypoAppTests/CryptoServiceTests.swift`

- [ ] **Step 1: Add the vector type**

In `macos/Tests/HypoAppTests/CryptoServiceTests.swift`, find `private struct CryptoVectors: Decodable` (file scope, below the `CryptoServiceTests` struct). Add this nested type after the existing `KeyAgreement` struct, at the same indentation:

```swift
    struct GzipVector: Decodable {
        let plaintextBase64: String
        let compressedBase64: String

        var plaintext: Data { Data(base64Encoded: plaintextBase64) ?? Data() }
        var compressed: Data { Data(base64Encoded: compressedBase64) ?? Data() }

        private enum CodingKeys: String, CodingKey {
            case plaintextBase64 = "plaintext_base64"
            case compressedBase64 = "compressed_base64"
        }
    }
```

- [ ] **Step 2: Expose it on `CryptoVectors`**

In the same struct, the stored properties and coding keys currently read:

```swift
    let testCases: [TestCase]
    let keyAgreement: KeyAgreement

    enum CodingKeys: String, CodingKey {
        case testCases = "test_cases"
        case keyAgreement = "key_agreement"
    }
```

Change them to:

```swift
    let testCases: [TestCase]
    let keyAgreement: KeyAgreement
    let gzip: GzipVector?

    enum CodingKeys: String, CodingKey {
        case testCases = "test_cases"
        case keyAgreement = "key_agreement"
        case gzip
    }
```

`gzip` is optional so the suite still compiles and runs against a fixture that predates the vector.

- [ ] **Step 3: Write the failing test**

Add this test inside `struct CryptoServiceTests` (the type declared near the top of the file), alongside the existing `@Test` functions and at the same four-space indentation:

```swift
    @Test
    func testDecompressesSharedGzipVector() throws {
        let vectors = try loadCryptoVectors()
        let gzip = try #require(vectors.gzip)

        let decompressed = try CompressionUtils.decompress(gzip.compressed)
        #expect(decompressed == gzip.plaintext)

        let roundTripped = try CompressionUtils.decompress(CompressionUtils.compress(gzip.plaintext))
        #expect(roundTripped == gzip.plaintext)
    }
```

The entry points are `CompressionUtils.compress(_:)` and
`CompressionUtils.decompress(_:)`, both `throws`, both `Data` in and out. Note
the type is `CompressionUtils`, not `Compression`: the file is named
`Compression.swift`, but `Compression` is the Apple framework module it imports,
so writing `Compression.compress` resolves against the framework and fails.

- [ ] **Step 4: Run the test**

Run: `cd macos && swift test --filter testDecompressesSharedGzipVector`

Expected: PASS, 1 test.

If it fails at runtime with a decompression error, that is a genuine finding: the macOS compression path is not producing or accepting standard gzip containers, which means macOS and Android have been diverging silently. Stop and report it. Do not adjust the vector to match whatever macOS emits — the vector is the contract.

- [ ] **Step 5: Run the full crypto suite to confirm nothing regressed**

Run: `cd macos && swift test --filter CryptoServiceTests`

Expected: PASS, 6 tests (the 5 that existed plus the new one).

- [ ] **Step 6: Commit**

```bash
git add macos/Tests/HypoAppTests/CryptoServiceTests.swift
git commit -m "test(macos): verify the shared gzip interoperability vector"
```

---

## Task 14: Back-fill the gzip vector into the Android suite

**Requires:** a JDK and the Android SDK. Both are present on this machine but
not on the default paths, so export them first:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_SDK_ROOT=/Users/derek/Documents/Projects/hypo/.android-sdk
```

`/usr/libexec/java_home` does not find this JDK, which is why it can look absent.
The SDK is the repository-scoped one that `AGENTS.md` asks builds to prefer.

**Files:**
- Modify: `android/app/src/test/java/com/hypo/clipboard/crypto/CryptoServiceTest.kt`

- [ ] **Step 1: Add the vector type**

In `android/app/src/test/java/com/hypo/clipboard/crypto/CryptoServiceTest.kt`, find `private data class CryptoVectors`. Add this nested type after the existing `KeyAgreement` data class, at the same indentation:

```kotlin
        @Serializable
        data class GzipVector(
            @SerialName("plaintext_base64") val plaintextBase64: String,
            @SerialName("compressed_base64") val compressedBase64: String
        ) {
            val plaintext: ByteArray get() = decode(plaintextBase64)
            val compressed: ByteArray get() = decode(compressedBase64)
        }
```

`decode` is the same base64 helper the existing `TestCase` and `KeyAgreement` types already call.

- [ ] **Step 2: Expose it on `CryptoVectors`**

The constructor currently reads:

```kotlin
    private data class CryptoVectors(
        @SerialName("test_cases") val testCases: List<TestCase>,
        @SerialName("key_agreement") val keyAgreement: KeyAgreement
    ) {
```

Change it to:

```kotlin
    private data class CryptoVectors(
        @SerialName("test_cases") val testCases: List<TestCase>,
        @SerialName("key_agreement") val keyAgreement: KeyAgreement,
        @SerialName("gzip") val gzip: GzipVector? = null
    ) {
```

The default of `null` keeps the suite working against a fixture without the vector.

- [ ] **Step 3: Write the failing test**

Add this test to the same class as the existing crypto vector tests:

```kotlin
    @Test
    fun `decompresses shared gzip vector`() {
        val gzip = requireNotNull(loadVectors().gzip) { "crypto_test_vectors.json has no gzip section" }

        val decompressed = GZIPInputStream(gzip.compressed.inputStream()).use { it.readBytes() }
        assertContentEquals(gzip.plaintext, decompressed)

        val ownCompressed = ByteArrayOutputStream().use { out ->
            GZIPOutputStream(out).use { it.write(gzip.plaintext) }
            out.toByteArray()
        }
        val roundTripped = GZIPInputStream(ownCompressed.inputStream()).use { it.readBytes() }
        assertContentEquals(gzip.plaintext, roundTripped)
    }
```

Add these imports to the top of the file if they are not already present:

```kotlin
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import kotlin.test.assertContentEquals
```

The file already uses `kotlin.test` assertions such as `assertFailsWith`, so `assertContentEquals` fits the existing style. The loader is named `loadVectors()`, not `loadCryptoVectors()` — that name belongs to the macOS suite.

- [ ] **Step 4: Run the test**

Run: `cd android && ./gradlew testDebugUnitTest --tests "*CryptoServiceTest*"`

Expected: PASS, with the existing tests in the class still passing.

As in Task 13, a decompression failure here is a real finding about the Android compression path. Report it; do not weaken the vector.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/test/java/com/hypo/clipboard/crypto/CryptoServiceTest.kt
git commit -m "test(android): verify the shared gzip interoperability vector"
```

---

## Task 15: Secret store abstraction

`Hypo.Core` must be able to persist keys without knowing that DPAPI exists. Plan 3 adds the Windows implementation; this task defines the contract and an in-memory implementation that later plans use in tests.

**Files:**
- Create: `windows/src/Hypo.Core/Abstractions/ISecretStore.cs`
- Create: `windows/src/Hypo.Core/Abstractions/InMemorySecretStore.cs`
- Test: `windows/tests/Hypo.Core.Tests/InMemorySecretStoreTests.cs`

- [ ] **Step 1: Write the failing test**

Create `windows/tests/Hypo.Core.Tests/InMemorySecretStoreTests.cs`:

```csharp
using Hypo.Core.Abstractions;

namespace Hypo.Core.Tests;

public class InMemorySecretStoreTests
{
    [Fact]
    public void ReturnsNullForAnAbsentKey()
    {
        Assert.Null(new InMemorySecretStore().Read("missing"));
    }

    [Fact]
    public void ReadsBackWhatItWrote()
    {
        var store = new InMemorySecretStore();

        store.Write("device-key", [0x01, 0x02, 0x03]);

        Assert.Equal(new byte[] { 0x01, 0x02, 0x03 }, store.Read("device-key"));
    }

    [Fact]
    public void OverwritesAnExistingKey()
    {
        var store = new InMemorySecretStore();

        store.Write("device-key", [0x01]);
        store.Write("device-key", [0x02]);

        Assert.Equal(new byte[] { 0x02 }, store.Read("device-key"));
    }

    [Fact]
    public void DeleteRemovesAKeyAndReportsWhetherItExisted()
    {
        var store = new InMemorySecretStore();
        store.Write("device-key", [0x01]);

        Assert.True(store.Delete("device-key"));
        Assert.False(store.Delete("device-key"));
        Assert.Null(store.Read("device-key"));
    }

    [Fact]
    public void NormalisesKeysToLowercase()
    {
        var store = new InMemorySecretStore();

        store.Write("Device-KEY", [0x01]);

        Assert.Equal(new byte[] { 0x01 }, store.Read("device-key"));
    }

    [Fact]
    public void DoesNotAliasTheCallersArray()
    {
        var store = new InMemorySecretStore();
        var written = new byte[] { 0x01 };

        store.Write("device-key", written);
        written[0] = 0xFF;

        Assert.Equal(new byte[] { 0x01 }, store.Read("device-key"));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd windows && dotnet test --filter FullyQualifiedName~InMemorySecretStoreTests`

Expected: FAIL to compile with `CS0246: The type or namespace name 'Hypo.Core.Abstractions' could not be found`.

- [ ] **Step 3: Write the interface**

Create `windows/src/Hypo.Core/Abstractions/ISecretStore.cs`:

```csharp
namespace Hypo.Core.Abstractions;

/// <summary>
/// Persists secret material. Keys are normalised to lowercase, matching the
/// device-id normalisation the macOS key store performs.
/// The Windows DPAPI implementation arrives in Plan 3.
/// </summary>
public interface ISecretStore
{
    byte[]? Read(string key);

    void Write(string key, ReadOnlySpan<byte> value);

    bool Delete(string key);
}
```

- [ ] **Step 4: Write the in-memory implementation**

Create `windows/src/Hypo.Core/Abstractions/InMemorySecretStore.cs`:

```csharp
using System.Collections.Concurrent;

namespace Hypo.Core.Abstractions;

/// <summary>Non-persistent secret store for tests and development.</summary>
public sealed class InMemorySecretStore : ISecretStore
{
    private readonly ConcurrentDictionary<string, byte[]> _entries = new(StringComparer.Ordinal);

    public byte[]? Read(string key) =>
        _entries.TryGetValue(Normalise(key), out var value) ? (byte[])value.Clone() : null;

    public void Write(string key, ReadOnlySpan<byte> value) =>
        _entries[Normalise(key)] = value.ToArray();

    public bool Delete(string key) => _entries.TryRemove(Normalise(key), out _);

    private static string Normalise(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        return key.ToLowerInvariant();
    }
}
```

Both `Read` and `Write` copy, so a caller mutating its array cannot reach into
the store and vice versa.

Note for Plan 3: this implementation does not zero a replaced or deleted value,
so old key bytes linger in the managed heap until collection. That is acceptable
for a development and test store, but the DPAPI implementation should not
inherit it — `CryptoService.DeriveKey` already shows the pattern with
`CryptographicOperations.ZeroMemory`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd windows && dotnet test --filter FullyQualifiedName~InMemorySecretStoreTests`

Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
git add windows/src/Hypo.Core/Abstractions/ windows/tests/Hypo.Core.Tests/InMemorySecretStoreTests.cs
git commit -m "feat(windows): add secret store abstraction"
```

---

## Task 16: End-to-end pipeline test

Every stage now exists. This test wires them in the order the real client will: serialise, gzip, encrypt, frame — then reverse. It is the guard that catches a stage being reordered or dropped in Plan 2.

**Files:**
- Test: `windows/tests/Hypo.Core.Tests/PayloadPipelineTests.cs`

- [ ] **Step 1: Write the test**

Create `windows/tests/Hypo.Core.Tests/PayloadPipelineTests.cs`:

```csharp
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Hypo.Core.Crypto;
using Hypo.Core.Protocol;
using Hypo.Core.Utils;

namespace Hypo.Core.Tests;

public class PayloadPipelineTests
{
    private const string DeviceId = "550e8400-e29b-41d4-a716-446655440000";

    [Fact]
    public void SerialiseCompressEncryptFrameRoundTrips()
    {
        var key = new byte[CryptoService.KeySizeBytes];
        var nonce = new byte[CryptoService.NonceSizeBytes];
        Random.Shared.NextBytes(key);
        Random.Shared.NextBytes(nonce);

        var timestamp = DateTimeOffset.Parse("2026-08-28T12:00:00Z");
        var original = new ClipboardPayload
        {
            ContentType = ContentType.Text,
            Data = Encoding.UTF8.GetBytes("Copied on Windows, pasted on macOS."),
            Compressed = true,
        };

        // Outbound: serialise, gzip, encrypt, frame.
        var json = JsonSerializer.SerializeToUtf8Bytes(original, ProtocolJson.Options);
        var compressed = GzipCompressor.Compress(json);
        var aad = CryptoService.BuildAssociatedData(DeviceId);
        var (ciphertext, tag) = CryptoService.Encrypt(compressed, key, nonce, aad);

        var frame = new TransportFrameCodec().Encode(new SyncEnvelope
        {
            Id = Guid.NewGuid(),
            Timestamp = timestamp,
            Type = MessageType.Clipboard,
            Payload = new EnvelopePayload
            {
                ContentType = ContentType.Text,
                Ciphertext = ciphertext,
                DeviceId = DeviceId,
                DevicePlatform = "windows",
                DeviceName = "Test PC",
                Encryption = new EncryptionMetadata { Nonce = nonce, Tag = tag },
            },
        });

        // Inbound: unframe, decrypt, gunzip, deserialise.
        var envelope = new TransportFrameCodec().Decode(frame);
        var recoveredAad = CryptoService.BuildAssociatedData(envelope.Payload.DeviceId);
        var decrypted = CryptoService.Decrypt(
            envelope.Payload.Ciphertext,
            key,
            envelope.Payload.Encryption.Nonce,
            envelope.Payload.Encryption.Tag,
            recoveredAad);
        var decompressed = GzipCompressor.Decompress(decrypted);
        var recovered = JsonSerializer.Deserialize<ClipboardPayload>(decompressed, ProtocolJson.Options)!;

        Assert.Equal(original.Data, recovered.Data);
        Assert.Equal(original.ContentType, recovered.ContentType);
        Assert.True(recovered.Compressed);
        Assert.Equal("windows", envelope.Payload.DevicePlatform);
    }

    [Fact]
    public void AssociatedDataIgnoresDeviceIdCasing()
    {
        Assert.Equal(
            CryptoService.BuildAssociatedData(DeviceId),
            CryptoService.BuildAssociatedData(DeviceId.ToUpperInvariant()));
    }
}
```

The second test matters because associated data is the one input to AES-GCM
that is reconstructed independently on each side rather than carried on the
wire. If two clients derive it differently — a casing difference, a stray
timestamp — every message fails authentication with no useful error pointing at
the cause.

- [ ] **Step 2: Run the test**

Run: `cd windows && dotnet test --filter FullyQualifiedName~PayloadPipelineTests`

Expected: PASS, 2 tests.

- [ ] **Step 3: Run the whole suite**

Run: `cd windows && dotnet test`

Expected: PASS, 73 tests, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add windows/tests/Hypo.Core.Tests/PayloadPipelineTests.cs
git commit -m "test(windows): cover the full payload pipeline end to end"
```

---

## Task 17: Wire the Windows core build into CI

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Read the existing workflow**

Run: `cat .github/workflows/ci.yml`

Note the top-level `on:` triggers and the indentation style of the existing jobs. The new job must sit at the same level as the existing ones.

- [ ] **Step 2: Add the job**

Add this job under the workflow's `jobs:` key, matching the surrounding indentation:

```yaml
  windows-tests:
    name: Windows core
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '10.0.x'

      - name: Restore
        run: dotnet restore
        working-directory: windows

      - name: Build
        run: dotnet build --no-restore --configuration Release
        working-directory: windows

      - name: Test
        run: dotnet test --no-build --configuration Release --verbosity normal
        working-directory: windows
```

The job runs on `windows-latest` even though `Hypo.Core` targets `net10.0` and would build anywhere. Later plans add `net10.0-windows` projects to the same solution, and having the job already on the right runner avoids a second migration.

- [ ] **Step 3: Verify the workflow file parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('valid')"`

Expected: `valid`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build and test the Windows core library"
```

---

## Task 18: Document the Windows tree

**Files:**
- Create: `windows/README.md`

- [ ] **Step 1: Write the file**

Create `windows/README.md`:

```markdown
# Hypo Windows Client

Windows client for Hypo, at feature parity with the macOS menu-bar client.

**Design:** [`docs/superpowers/specs/2026-08-28-windows-client-design.md`](../docs/superpowers/specs/2026-08-28-windows-client-design.md)

## Status

| Layer | Plan | State |
|-------|------|-------|
| `Hypo.Core` — protocol, crypto, compression | Plan 1 | Implemented |
| Transport, discovery, pairing, storage | Plan 2 | Not started |
| Windows platform layer and tray app | Plan 3 | Not started |
| History panel and settings UI | Plan 4 | Not started |
| Shell extension, packaging, release | Plan 5 | Not started |

## Requirements

- .NET 10 SDK
- Windows 10 22H2 or later to run the app; `Hypo.Core` alone builds and tests on any platform the SDK supports

## Build and test

```bash
cd windows
dotnet build
dotnet test
```

## Layout

- `src/Hypo.Core` — protocol models, framing, cryptography, compression. Targets
  `net10.0` with no Windows APIs, which is what keeps the layer testable in
  isolation. Do not add a Windows-specific dependency here.
- `tests/Hypo.Core.Tests` — xUnit suite. The crypto, framing and gzip tests read
  `tests/crypto_test_vectors.json` and `tests/transport/frame_vectors.json` from
  the repository root, the same fixtures the macOS and Android suites use. If a
  change makes one of those tests fail, the Windows client has diverged from the
  other two clients — fix the client, not the fixture.

## Interoperability notes

- Android encodes base64 without padding. Decode through `Base64Compat`, never
  `Convert.FromBase64String` directly.
- Compression is a gzip container (RFC 1952), not raw deflate.
- Device IDs are bare lowercase UUIDs. Platform-prefixed IDs were removed in
  protocol v1.1.
```

- [ ] **Step 2: Verify the relative link resolves**

Run: `ls docs/superpowers/specs/2026-08-28-windows-client-design.md`

Expected: the path is listed, confirming the `../` link from `windows/README.md` is correct.

- [ ] **Step 3: Commit**

```bash
git add windows/README.md
git commit -m "docs(windows): document the Windows client tree"
```

---

## Done criteria

Plan 1 is complete when all of the following hold:

1. `cd windows && dotnet test` passes with zero failures.
2. `dotnet build` produces zero warnings — `TreatWarningsAsErrors` makes this automatic.
3. `tests/crypto_test_vectors.json` contains the `gzip` section and the macOS suite reads it (Task 13). The Android back-fill (Task 14) may be deferred with an explicit note.
4. `Hypo.Core.csproj` still targets `net10.0` and references no Windows-specific package.
5. The CI job `windows-tests` passes on a pull request.

## What Plan 2 picks up

`Hypo.Core` can now produce and consume protocol messages, but nothing sends them. Plan 2 adds `ISyncTransport`, the LAN WebSocket server and client, `CloudRelayTransport`, `DualSyncTransport`, `TransportManager`, mDNS publish and browse, `PairingSession`, `PairingRelayClient` and the SQLite `HistoryStore`, and delivers a console harness that pairs with a real macOS or Android device.

Spec section 11 flags mDNS interoperability with macOS Bonjour and Android NSD as the highest-risk dependency in the whole project. Plan 2 should spike it first, before building anything on top of it.
