import DuckoXMPP

/// Pure JID validation for text-field entry, wrapping `BareJID.parse` so DuckoUI
/// can gate JID input without naming `BareJID` (which DuckoCore does not re-export).
public enum JIDValidation {
    /// Whether a string is a syntactically valid bare JID that addresses a user or
    /// room (`localPart@domainPart`).
    ///
    /// The input must already be trimmed by the caller; this helper does not trim.
    /// A resource part (`/…`) is rejected, since a bare JID cannot carry one, as is a
    /// domain-only JID such as `example.com` (valid for a server/service, but not a
    /// chat target, contact, invitee, or room).
    public static func isValidUserOrRoomJID(_ jidString: String) -> Bool {
        BareJID.parse(jidString)?.localPart != nil
    }
}
