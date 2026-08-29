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
        Random.Shared.NextBytes(key);
        Random.Shared.NextBytes(nonce);
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
