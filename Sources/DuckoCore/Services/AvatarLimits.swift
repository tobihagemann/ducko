import Foundation

/// Shared bounds for avatar image payloads (vCard photos, PEP avatars). These
/// arrive from peer/server data and are therefore untrusted, so payloads over
/// the cap are dropped at ingestion (before persisting) and rejected at decode.
public enum AvatarLimits {
    public static let maxBytes = 8 * 1024 * 1024
}
