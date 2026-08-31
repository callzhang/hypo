namespace Hypo.Core.Sync;

/// <summary>What to do with an image before sending it.</summary>
public sealed record ImagePlan
{
    /// <summary>Send the bytes unchanged.</summary>
    public static ImagePlan AsIs { get; } = new() { Action = ImageAction.SendAsIs };

    public required ImageAction Action { get; init; }

    /// <summary>The longest side to scale to, when scaling.</summary>
    public int? LongestSide { get; init; }

    /// <summary>JPEG quality to try, in order, when re-encoding.</summary>
    public IReadOnlyList<int> Qualities { get; init; } = [];

    /// <summary>Why, in a sentence, for the case where nothing worked.</summary>
    public string? Reason { get; init; }
}

public enum ImageAction
{
    SendAsIs,

    /// <summary>Scale down, re-encode, and stop at the first size that fits.</summary>
    Compress,

    /// <summary>Too large to be worth trying. Say so rather than sending something broken.</summary>
    Refuse,
}

/// <summary>
/// Decides whether an image needs shrinking before it goes on the wire, and how
/// hard to try.
///
/// <para>The numbers are the protocol's (§3.2.3), and they are here rather than
/// beside the encoder so they can be tested on any machine: the encoder needs
/// Windows imaging, the policy needs arithmetic.</para>
/// </summary>
public static class ImageBudget
{
    /// <summary>The protocol's ceiling on raw image bytes.</summary>
    public const int MaxBytes = 10 * 1024 * 1024;

    /// <summary>Above this, compress. Below it, leave the image alone.</summary>
    public const int CompressAboveBytes = 7_500 * 1024;

    /// <summary>Scale only when the image is bigger than this on its longest side.</summary>
    public const int MaxLongestSide = 2560;

    /// <summary>
    /// The quality ladder, in order. 85 first because it is visually close to
    /// lossless for a screenshot; the rest are what the protocol allows before
    /// giving up.
    /// </summary>
    public static IReadOnlyList<int> QualityLadder { get; } = [85, 75, 60, 40];

    /// <summary>
    /// Beyond this there is no point decoding the image to find out: a hundred
    /// megabytes of bitmap is a mistake somewhere, not a clipboard item, and
    /// trying costs the memory before it costs the failure.
    /// </summary>
    public const int RefuseAboveBytes = 100 * 1024 * 1024;

    public static ImagePlan Plan(int byteLength, int width, int height)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(byteLength);

        if (byteLength > RefuseAboveBytes)
        {
            return new ImagePlan
            {
                Action = ImageAction.Refuse,
                Reason = $"The image is {byteLength / (1024 * 1024)} MB, which is past anything worth sending.",
            };
        }

        if (byteLength <= CompressAboveBytes)
        {
            return ImagePlan.AsIs;
        }

        var longest = Math.Max(width, height);

        return new ImagePlan
        {
            Action = ImageAction.Compress,

            // Only scale when there is something to gain. A long thin image can
            // be over the size budget without exceeding the side limit, and
            // scaling it anyway would lose detail for nothing.
            LongestSide = longest > MaxLongestSide ? MaxLongestSide : null,
            Qualities = QualityLadder,
        };
    }

    /// <summary>Whether an encoded result is small enough to stop trying.</summary>
    public static bool Fits(int byteLength) => byteLength <= MaxBytes;
}
