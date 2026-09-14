import Darwin

/// Readable text for a POSIX `errno` value, e.g. "Connection refused" for `ECONNREFUSED`.
func posixErrorText(_ code: Int32) -> String {
    String(cString: strerror(code))
}

/// Readable text for a `getaddrinfo` error code. Call it right after the failing call: `EAI_SYSTEM` reads `errno`.
func addressInfoErrorText(_ code: Int32) -> String {
    code == EAI_SYSTEM ? posixErrorText(errno) : String(cString: gai_strerror(code))
}
