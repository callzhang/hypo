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
}
