using System.Net;
using System.Text;
using Hypo.Core.Relay;

namespace Hypo.Core.Tests;

/// <summary>
/// Asking the relay who is connected. Plain HTTP, so it answers whether or not
/// our own socket is up -- which is the whole point of not tying the two together.
/// </summary>
public class CloudPresenceClientTests
{
    [Fact]
    public async Task ReturnsTheDevicesTheRelayReports()
    {
        var handler = new StubHandler(HttpStatusCode.OK,
            """{"connected_devices":[{"device_id":"AAAA1111"},{"device_id":"bbbb2222"}]}""");
        var client = new CloudPresenceClient(new HttpClient(handler), new Uri("https://relay.example/"));

        var connected = await client.ConnectedAsync(["aaaa1111", "bbbb2222", "cccc3333"]);

        // Lowercased: ids arrive cased differently from different platforms.
        Assert.Equal(["aaaa1111", "bbbb2222"], connected.OrderBy(id => id));
        Assert.Contains("device_id=aaaa1111%2Cbbbb2222%2Ccccc3333", handler.LastUri!.ToString());
    }

    [Fact]
    public async Task AsksNothingWhenThereAreNoPeers()
    {
        var handler = new StubHandler(HttpStatusCode.OK, "{}");
        var client = new CloudPresenceClient(new HttpClient(handler), new Uri("https://relay.example/"));

        Assert.Empty(await client.ConnectedAsync([]));
        Assert.Null(handler.LastUri);
    }

    [Fact]
    public async Task TreatsAFailureAsNoOneSeenRatherThanThrowing()
    {
        var client = new CloudPresenceClient(
            new HttpClient(new StubHandler(HttpStatusCode.InternalServerError, "nope")),
            new Uri("https://relay.example/"));

        // A relay that cannot answer is not evidence a peer is offline, but it is
        // not evidence it is back either, and only a return is acted on.
        Assert.Empty(await client.ConnectedAsync(["aaaa1111"]));
    }

    [Fact]
    public async Task SurvivesAnUnreachableRelay()
    {
        var client = new CloudPresenceClient(
            new HttpClient(new ThrowingHandler()),
            new Uri("https://relay.example/"));

        Assert.Empty(await client.ConnectedAsync(["aaaa1111"]));
    }

    private sealed class StubHandler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        public Uri? LastUri { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            LastUri = request.RequestUri;

            return Task.FromResult(new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            });
        }
    }

    private sealed class ThrowingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            throw new HttpRequestException("no route to host");
    }
}
