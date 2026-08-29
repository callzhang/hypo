using Hypo.Core.Sync;

namespace Hypo.Harness;

/// <summary>
/// A clipboard that only remembers. There is no OS clipboard behind the
/// harness -- it runs headless, and on a Mac -- so this stands in for one.
///
/// It honours the contract that matters: a write never raises
/// <see cref="ContentChanged"/>. Echoing writes here would put the harness and
/// a real phone into an unbounded loop, which is a worse way to discover the
/// rule than reading it.
/// </summary>
public sealed class ConsoleClipboard : IClipboard
{
    public event EventHandler<ClipboardContent>? ContentChanged;

    public ClipboardContent? Current { get; private set; }

    public Task<ClipboardContent?> GetAsync(CancellationToken ct = default) => Task.FromResult(Current);

    public Task SetAsync(ClipboardContent content, CancellationToken ct = default)
    {
        Current = content;
        return Task.CompletedTask;
    }

    /// <summary>Simulates a local copy, for driving the outbound direction by hand.</summary>
    public void Copy(ClipboardContent content)
    {
        Current = content;
        ContentChanged?.Invoke(this, content);
    }
}
