import XCTest
@testable import HomeCore

final class HomeEndpointTests: XCTestCase {
    func testUPnPUsesRootUDNInsteadOfEmbeddedServiceIdentity() throws {
        let location = URL(string: "http://192.168.0.1/root.xml")!
        let xml = "<root><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType><friendlyName>EX511</friendlyName><UDN>uuid:ROOT-ROUTER</UDN><deviceList><device><UDN>uuid:embedded-wan</UDN></device></deviceList></device></root>"
        let description = try XCTUnwrap(UPnPDescription.parse(Data(xml.utf8), location: location))
        XCTAssertEqual(description.rootDeviceID, "ssdp:uuid:root-router")
    }

    func testDIALReceiverIsAMediaDevice() throws {
        let location = URL(string: "http://192.168.0.5:7678/nservice/")!
        let xml = "<root><device><deviceType>urn:dial-multiscreen-org:device:dialreceiver:1</deviceType><friendlyName>Samsung AU7000 50 TV</friendlyName><UDN>uuid:samsung-dial</UDN></device></root>"
        XCTAssertEqual(try XCTUnwrap(UPnPDescription.parse(Data(xml.utf8), location: location)).kind, .television)
    }

    func testLocalManagementAddressesAndRemoteHTTPS() throws {
        for address in ["http://192.168.1.1", "http://10.0.0.1:8123", "http://172.16.1.1", "http://homeassistant.local:8123", "http://[fd12::1]", "https://hub.example.com/ha"] {
            XCTAssertNoThrow(try HomeEndpointPolicy.address(address))
        }
        for address in ["http://example.com", "http://172.32.0.1", "http://192.168.01.1", "javascript:alert(1)", "file:///tmp/test", "https://name:password@192.168.1.1", "http://192.168.1.1?token=secret", "http://192.168.1.1:0", "http://192.168.1.1:99999"] {
            XCTAssertThrowsError(try HomeEndpointPolicy.address(address), address)
        }
        XCTAssertThrowsError(try HomeEndpointPolicy.address("https://example.com", localOnly: true))
    }

    func testSSDPRejectsExternalURLsAndDeduplicatesServiceSuffixes() throws {
        let packet = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1:5000/root.xml\r\nUSN: uuid:router-one::urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\nCACHE-CONTROL: max-age=1800\r\n\r\n"
        let ad = try XCTUnwrap(SSDPAdvertisement.parse(Data(packet.utf8)))
        XCTAssertEqual(ad.id, "ssdp:uuid:router-one")
        XCTAssertEqual(ad.maxAge, 120)
        XCTAssertNil(SSDPAdvertisement.parse(Data(packet.replacingOccurrences(of: "192.168.1.1:5000", with: "evil.example.com").utf8)))
        XCTAssertNil(SSDPAdvertisement.parse(Data(packet.replacingOccurrences(of: "200 OK", with: "404 Not Found").utf8)))
        XCTAssertNil(SSDPAdvertisement.parse(Data(repeating: 65, count: 20_000)))
    }

    func testUPnPRootDescriptionDoesNotTrustNestedDevicesOrExternalAdminURL() throws {
        let location = URL(string: "http://192.168.1.1:5000/root.xml")!
        let xml = "<root><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType><friendlyName>Home router</friendlyName><manufacturer>Vendor</manufacturer><modelName>AX</modelName><presentationURL>http://evil.example.com/admin</presentationURL><deviceList><device><friendlyName>Fake nested name</friendlyName></device></deviceList></device></root>"
        let description = try XCTUnwrap(UPnPDescription.parse(Data(xml.utf8), location: location))
        XCTAssertEqual(description.name, "Home router")
        XCTAssertEqual(description.kind, .router)
        XCTAssertNil(description.presentationURL)
        let local = try XCTUnwrap(UPnPDescription.parse(Data(xml.replacingOccurrences(of: "http://evil.example.com/admin", with: "/admin").utf8), location: location))
        XCTAssertEqual(local.presentationURL?.absoluteString, "http://192.168.1.1:5000/admin")
    }
}
