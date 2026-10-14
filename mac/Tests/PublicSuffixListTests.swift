import XCTest

final class PublicSuffixListTests: XCTestCase {

    func testExactDomainReturnsItself() {
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "example.com"), "example.com")
    }

    func testSubdomainStripsToETLDPlusOne() {
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "app.example.com"), "example.com")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "a.b.c.example.com"), "example.com")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "staging.example.berlin"), "example.berlin")
    }

    func testGermanTLD() {
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "example.de"), "example.de")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "sub.example.de"), "example.de")
    }

    func testTwoPartCountryTLD() {
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "example.co.uk"), "example.co.uk")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "staging.example.co.uk"), "example.co.uk")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "www.shop.com.tr"), "shop.com.tr")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "staging.firma.co.at"), "firma.co.at")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "a.b.example.com.pl"), "example.com.pl")
    }

    func testLocalhostReturnsNil() {
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "localhost"))
    }

    func testIPAddressesReturnNil() {
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "127.0.0.1"))
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "192.168.1.1"))
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "::1"))
    }

    func testHostOutsideEveryRuleReturnsNil() {
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "weirdhost.zzzzunknown"))
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "nas.local"))
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "app.internal"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: ""))
    }

    func testPrivateSectionPlatformSuffixesSeparateTenants() {
        // Shared hosting platforms from the PSL PRIVATE section: every customer
        // subdomain is its own registrable domain, so two tenants never share
        // an eTLD+1 and the suffix stage cannot hand one tenant's credentials
        // to another.
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "d111111abcdef8.cloudfront.net"), "d111111abcdef8.cloudfront.net")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "kunde-staging.herokuapp.com"), "kunde-staging.herokuapp.com")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "docs.someone.github.io"), "someone.github.io")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "preview.vercel.app"), "preview.vercel.app")
    }

    func testPublicSuffixItselfReturnsNil() {
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "herokuapp.com"))
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "co.uk"))
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "com"))
    }

    func testWildcardRuleAddsOneLabel() {
        // PSL: `*.ck` — every second-level label under `ck` is itself a suffix.
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "a.foo.ck"), "a.foo.ck")
        XCTAssertNil(PublicSuffixList.eTLDPlusOne(host: "foo.ck"))
    }

    func testExceptionRuleOverridesWildcard() {
        // PSL: `!www.ck` — `www.ck` is registrable despite `*.ck`.
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "www.ck"), "www.ck")
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "a.www.ck"), "www.ck")
    }

    func testInternationalizedSuffixMatchesPunycodeHost() {
        // Browsers send hosts in Punycode; `公司.cn` is a public suffix, so
        // `a.公司.cn` is registrable on its own.
        XCTAssertEqual(PublicSuffixList.eTLDPlusOne(host: "a.xn--55qx5d.cn"), "a.xn--55qx5d.cn")
    }

    func testHostnameExtraction() {
        XCTAssertEqual(PublicSuffixList.hostname(from: "https://Example.COM:8080/path"), "example.com")
        XCTAssertEqual(PublicSuffixList.hostname(from: "http://192.168.1.1/"), "192.168.1.1")
        XCTAssertNil(PublicSuffixList.hostname(from: "not a url"))
    }
}
