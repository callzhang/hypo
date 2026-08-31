using Hypo.Core.Protocol;
using Hypo.Core.Sync;
using Hypo.Windows.Clipboard;

namespace Hypo.Windows.App;

/// <summary>
/// What to hand another application when a history entry is dragged into it.
///
/// <para>Dragging is how you get a clipboard entry into something without
/// disturbing the clipboard at all, which matters when the thing you are
/// currently copying is the thing you want to keep.</para>
///
/// <para>The formats a drag carries are a decision, and so is where a file's
/// bytes are written before anything can be dropped. Both are here rather than
/// in the window so they can be tested on any machine; turning this into a WPF
/// <c>DataObject</c> is three lines in the window.</para>
/// </summary>
public sealed record DragContent
{
    /// <summary>Text, for <c>CF_UNICODETEXT</c>. Null when there is none.</summary>
    public string? Text { get; init; }

    /// <summary>PNG bytes, for the registered "PNG" format.</summary>
    public byte[]? Png { get; init; }

    /// <summary>Paths on disk, for <c>FileDrop</c>.</summary>
    public IReadOnlyList<string>? Files { get; init; }

    /// <summary>False when there is nothing worth starting a drag for.</summary>
    public bool HasAnything => Text is not null || Png is not null || Files is { Count: > 0 };

    /// <summary>
    /// Builds the payload, writing a file's bytes to disk first.
    ///
    /// <para>A drop target receives a path, not bytes, so the file has to exist
    /// before the drag begins. It goes to <paramref name="temporaryDirectory"/>
    /// rather than the received-files folder: this is a copy made for the drop,
    /// not something a peer sent, and it should not accumulate somewhere the
    /// user thinks of as theirs.</para>
    /// </summary>
    public static DragContent For(ClipboardContent content, string temporaryDirectory)
    {
        ArgumentNullException.ThrowIfNull(content);
        ArgumentException.ThrowIfNullOrWhiteSpace(temporaryDirectory);

        return content.ContentType switch
        {
            ContentType.Text or ContentType.Link => new DragContent
            {
                Text = System.Text.Encoding.UTF8.GetString(content.Data),
            },

            // Text alongside the image: a target that cannot take a picture --
            // a text editor, a terminal -- otherwise refuses the drop entirely,
            // and the file name is more use than nothing.
            ContentType.Image => new DragContent { Png = content.Data },

            ContentType.File => new DragContent
            {
                Files = [ClipboardFiles.Materialise(temporaryDirectory, content.FileName, content.Data)],
                Text = content.FileName,
            },

            _ => new DragContent(),
        };
    }

    /// <summary>Where dragged files are written: <c>%TEMP%\Hypo</c>.</summary>
    public static string DefaultTemporaryDirectory =>
        Path.Combine(Path.GetTempPath(), "Hypo");
}
