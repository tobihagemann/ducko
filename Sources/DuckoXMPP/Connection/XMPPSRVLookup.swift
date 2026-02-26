import CDnssd
import Darwin

/// A DNS SRV record per RFC 2782.
struct SRVRecord: Sendable, Comparable {
    let priority: UInt16
    let weight: UInt16
    let port: UInt16
    let target: String

    static func < (lhs: SRVRecord, rhs: SRVRecord) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        // Higher weight = more preferred within same priority
        return lhs.weight > rhs.weight
    }
}

/// DNS SRV resolution per RFC 6120 §3.2.
///
/// Resolves `_xmpp-client._tcp.{domain}` to get host/port records.
/// Falls back to `domain:5222` on any failure.
enum XMPPSRVLookup {
    static func resolve(domain: String, timeout: Duration = .seconds(5)) async -> [SRVRecord] {
        do {
            return try await withThrowingTaskGroup(of: [SRVRecord].self) { group in
                group.addTask {
                    try await querySRV(domain: domain)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CancellationError()
                }
                if let result = try await group.next(), !result.isEmpty {
                    group.cancelAll()
                    return result.sorted()
                }
                group.cancelAll()
                return fallback(domain: domain)
            }
        } catch {
            return fallback(domain: domain)
        }
    }

    private static func fallback(domain: String) -> [SRVRecord] {
        [SRVRecord(priority: 0, weight: 0, port: 5222, target: domain)]
    }

    private static func querySRV(domain: String) async throws -> [SRVRecord] {
        try await Task.detached {
            try srvQuery(domain: domain)
        }.value
    }
}

// MARK: - DNS SRV Query

private struct SRVQueryData {
    var records: [SRVRecord] = []
    var isDone = false
}

/// Synchronous DNS SRV query using `poll()` + `DNSServiceProcessResult`.
///
/// Runs entirely on the calling thread — no async/callback nesting needed.
/// The DNS-SD callback fires synchronously during `DNSServiceProcessResult`.
private func srvQuery(domain: String) throws -> [SRVRecord] { // swiftlint:disable:this cyclomatic_complexity function_body_length
    let name = "_xmpp-client._tcp.\(domain)"
    var sdRef: DNSServiceRef?

    let dataPtr = UnsafeMutablePointer<SRVQueryData>.allocate(capacity: 1)
    dataPtr.initialize(to: SRVQueryData())
    defer {
        dataPtr.deinitialize(count: 1)
        dataPtr.deallocate()
    }

    let callback: DNSServiceQueryRecordReply = {
        _, flags, _, errorCode, _, _, _, rdlen, rdata, _, ctx in
        guard let ctx else { return }
        let data = ctx.assumingMemoryBound(to: SRVQueryData.self)

        guard errorCode == kDNSServiceErr_NoError else {
            data.pointee.isDone = true
            return
        }

        if let rdata, rdlen >= 7 {
            let ptr = rdata.assumingMemoryBound(to: UInt8.self)
            let priority = UInt16(ptr[0]) << 8 | UInt16(ptr[1])
            let weight = UInt16(ptr[2]) << 8 | UInt16(ptr[3])
            let port = UInt16(ptr[4]) << 8 | UInt16(ptr[5])
            let target = srvParseDNSName(ptr + 6, length: Int(rdlen) - 6)

            if !target.isEmpty, target != "." {
                data.pointee.records.append(
                    SRVRecord(priority: priority, weight: weight, port: port, target: target)
                )
            }
        }

        if flags & kDNSServiceFlagsMoreComing == 0 {
            data.pointee.isDone = true
        }
    }

    let err = DNSServiceQueryRecord(
        &sdRef,
        kDNSServiceFlagsReturnIntermediates,
        0,
        name,
        UInt16(kDNSServiceType_SRV),
        UInt16(kDNSServiceClass_IN),
        callback,
        dataPtr
    )

    guard err == kDNSServiceErr_NoError, let sdRef else {
        throw XMPPConnectionError.connectionFailed("DNSServiceQueryRecord failed: \(err)")
    }
    defer { DNSServiceRefDeallocate(sdRef) }

    let fd = DNSServiceRefSockFD(sdRef)
    guard fd >= 0 else {
        throw XMPPConnectionError.connectionFailed("Invalid DNS-SD socket")
    }

    // Process results synchronously with poll(), 100ms per iteration, 5s max
    var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    for _ in 0 ..< 50 {
        if dataPtr.pointee.isDone { break }
        let result = Darwin.poll(&pollFd, 1, 100)
        if result < 0 { break }
        if result > 0 {
            DNSServiceProcessResult(sdRef)
        }
    }

    return dataPtr.pointee.records
}

/// Parses a DNS wire-format name (sequence of length-prefixed labels) into a dotted string.
private func srvParseDNSName(_ ptr: UnsafePointer<UInt8>, length: Int) -> String {
    var labels: [String] = []
    var offset = 0
    while offset < length {
        let labelLength = Int(ptr[offset])
        if labelLength == 0 { break }
        offset += 1
        guard offset + labelLength <= length else { break }
        let label = String(
            decoding: UnsafeBufferPointer(start: ptr + offset, count: labelLength),
            as: UTF8.self
        )
        labels.append(label)
        offset += labelLength
    }
    return labels.joined(separator: ".")
}
