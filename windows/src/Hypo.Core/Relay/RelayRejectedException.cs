using System.Net;

namespace Hypo.Core.Relay;

/// <summary>
/// The relay refused the handshake rather than being unreachable. The
/// distinction decides whether retrying is diligence or abuse: a 401 means the
/// shared secret is wrong, and no amount of waiting turns that into a 101.
/// </summary>
public sealed class RelayRejectedException(HttpStatusCode status, Exception inner)
    : Exception($"The relay refused the connection with {(int)status} {status}.", inner)
{
    public HttpStatusCode Status { get; } = status;
}
