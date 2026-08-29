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
