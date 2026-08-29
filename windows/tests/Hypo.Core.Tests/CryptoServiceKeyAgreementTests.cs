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
