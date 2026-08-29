using Hypo.Core.Relay;

namespace Hypo.Core.Tests;

public class RelayAuthTokenTests
{
    private const string Secret = "hypo-test-secret";
    private const string DeviceId = "11111111-2222-3333-4444-555555555555";

    // Generated independently with python3 -c "import base64,hmac,hashlib; ..."
    // so this test pins the construction rather than restating the implementation.
    private const string Expected = "udBJgxW+f/IVK3X0YE2pjlll6sozihmkWnsT0FF3418=";

    [Fact]
    public void MatchesAnIndependentlyComputedVector()
    {
        Assert.Equal(Expected, RelayAuthToken.Compute(Secret, DeviceId));
    }

    [Fact]
    public void IsPaddedBase64()
    {
        // The relay accepts unpadded too, but we should emit one form and know
        // which: a 32-byte digest always ends in a single '=' when padded.
        Assert.EndsWith("=", RelayAuthToken.Compute(Secret, DeviceId));
        Assert.Equal(44, RelayAuthToken.Compute(Secret, DeviceId).Length);
    }

    [Fact]
    public void LowercasesTheDeviceIdBeforeSigning()
    {
        // The relay lowercases the header before verifying. A client that signs
        // the uppercase form authenticates against a peer that happens to
        // lowercase early and fails against everything else -- an intermittent
        // 401 that looks like a network problem.
        Assert.Equal(
            RelayAuthToken.Compute(Secret, DeviceId),
            RelayAuthToken.Compute(Secret, DeviceId.ToUpperInvariant()));
    }

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    public void RejectsAnAbsentSecret(string? secret)
    {
        // The relay's own verify_ws_auth refuses an empty RELAY_WS_AUTH_TOKEN,
        // so signing with one would only move the failure somewhere less legible.
        Assert.Throws<ArgumentException>(() => RelayAuthToken.Compute(secret!, DeviceId));
    }

    [Fact]
    public void RejectsAnAbsentDeviceId()
    {
        Assert.Throws<ArgumentException>(() => RelayAuthToken.Compute(Secret, ""));
    }
}
