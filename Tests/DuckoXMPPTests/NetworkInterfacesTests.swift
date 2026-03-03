import Testing
@testable import DuckoXMPP

enum NetworkInterfacesTests {
    struct LocalAddresses {
        @Test
        func `Returns non-empty list on dev machine`() {
            let addresses = NetworkInterfaces.localAddresses()
            #expect(!addresses.isEmpty)
        }

        @Test
        func `No loopback addresses in results`() {
            let addresses = NetworkInterfaces.localAddresses()
            for address in addresses {
                #expect(address.ip != "127.0.0.1")
                #expect(address.ip != "::1")
            }
        }

        @Test
        func `No link-local IPv6 addresses in results`() {
            let addresses = NetworkInterfaces.localAddresses()
            for address in addresses {
                let hasPrefix = address.ip.hasPrefix("fe80")
                #expect(!hasPrefix)
            }
        }

        @Test
        func `All addresses have valid IP strings`() {
            let addresses = NetworkInterfaces.localAddresses()
            for address in addresses {
                #expect(!address.ip.isEmpty)
                if address.isIPv4 {
                    let parts = address.ip.split(separator: ".")
                    #expect(parts.count == 4)
                }
            }
        }

        @Test
        func `IPv4 flag is correct for known IPv4 patterns`() {
            let addresses = NetworkInterfaces.localAddresses()
            let ipv4 = addresses.filter(\.isIPv4)
            for address in ipv4 {
                let parts = address.ip.split(separator: ".")
                #expect(parts.count == 4)
            }
        }
    }
}
