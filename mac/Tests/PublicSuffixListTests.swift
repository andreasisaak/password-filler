import XCTest

final class PublicSuffixListTests: XCTestCase {

    func testExactDomainReturnsItself() {
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "example.com"), "example.com")
    }

    func testSubdomainStripsToETLDPlusOne() {
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "app.example.com"), "example.com")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "a.b.c.example.com"), "example.com")
    }

    func testGermanTLD() {
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "example.de"), "example.de")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "sub.example.de"), "example.de")
    }

    func testTwoPartCountryTLD() {
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "example.co.uk"), "example.co.uk")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "staging.example.co.uk"), "example.co.uk")
    }

    func testUppercaseHostIsNormalised() {
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "Example.COM"), "example.com")
    }

    func testLocalhostReturnsNil() {
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "localhost"))
    }

    func testIPv4ReturnsNil() {
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "127.0.0.1"))
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "192.168.1.1"))
    }

    func testUnknownTLDReturnsNil() {
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "weirdhost.zzzzunknown"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: ""))
    }

    func testHostnameExtraction() {
        XCTAssertEqual(PublicSuffixList.hostname(from: "https://Example.COM:8080/path"), "example.com")
        XCTAssertEqual(PublicSuffixList.hostname(from: "http://192.168.1.1/"), "192.168.1.1")
        XCTAssertNil(PublicSuffixList.hostname(from: "not a url"))
    }
}
