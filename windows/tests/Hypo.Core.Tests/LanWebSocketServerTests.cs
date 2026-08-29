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
