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

    /// <summary>Makes SetAsync refuse, the way a text-only clipboard refuses an image.</summary>
    public bool RefuseWrites { get; set; }

    public Task<ClipboardContent?> GetAsync(CancellationToken ct = default) => Task.FromResult(Current);

    public Task SetAsync(ClipboardContent content, CancellationToken ct = default)
    {
        if (RefuseWrites)
        {
            throw new NotSupportedException($"{content.ContentType} cannot be written.");
        }

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
