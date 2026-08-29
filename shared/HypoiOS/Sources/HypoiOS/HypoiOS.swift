import Foundation
import HypoCore

/// Marker confirming HypoiOS can see HypoCore's public API.
/// Deleted once the real platform implementations land.
public enum HypoiOS {
    public static let maxAttachmentBytes = SizeConstants.maxAttachmentBytes
}
