using Hypo.Core.Sync;

namespace Hypo.Core.Tests;

/// <summary>
/// A clipboard the tests drive. <see cref="SetAsync"/> deliberately does not
/// raise <see cref="ContentChanged"/>, matching the contract a real
/// implementation must honour -- a fake that echoed writes would let an echo
/// loop pass its tests and only appear on a real machine, against a real peer.
/// Use <see cref="SimulateExternalCopy"/> for a change someone else made.
/// </summary>
internal sealed class FakeClipboard : IClipboard
{
    public event EventHandler<ClipboardContent>? ContentChanged;

    public ClipboardContent? Current { get; private set; }

    public List<ClipboardContent> Writes { get; } = [];

    public Task<ClipboardContent?> GetAsync(CancellationToken ct = default) => Task.FromResult(Current);

    public Task SetAsync(ClipboardContent content, CancellationToken ct = default)
    {
        Current = content;
        Writes.Add(content);
        return Task.CompletedTask;
    }

    public void SimulateExternalCopy(ClipboardContent content)
    {
        Current = content;
        ContentChanged?.Invoke(this, content);
    }
}
