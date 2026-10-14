import Foundation

/// eTLD+1 extraction against the official Public Suffix List — Swift
/// equivalent of `tldts.getDomain()`.
///
/// The rules (ICANN + PRIVATE sections) live in the generated
/// `PublicSuffixListRules.swift`; refresh them with `node scripts/update-psl.js`.
/// The PRIVATE section is load-bearing: it makes shared hosting platforms
/// (`cloudfront.net`, `herokuapp.com`, `github.io`, …) public suffixes, so two
/// tenants of the same platform never share an eTLD+1 and the suffix stage of
/// `ItemStore.lookup` cannot fill one tenant's credentials into another's site.
///
/// Fail-closed: a host that no rule covers (`localhost`, `nas.local`, IPs,
/// unknown TLDs) has no eTLD+1, so only an exact hostname match can fill it.
/// This deviates from the PSL's implicit `*` default rule on purpose.
public enum PublicSuffixList {

    /// Plain rules, e.g. `com`, `co.uk`, `cloudfront.net`.
    private static let suffixes = ruleSet(PublicSuffixListRules.suffixes)
    /// Parents of wildcard rules: `*.ck` is stored as `ck`.
    private static let wildcardParents = ruleSet(PublicSuffixListRules.wildcardParents)
    /// Exception rules without the `!`: `!www.ck` is stored as `www.ck`.
    private static let exceptions = ruleSet(PublicSuffixListRules.exceptions)

    /// Returns the effective-TLD+1 for a hostname, or `nil` if the hostname is
    /// itself a public suffix or no rule covers it.
    ///
    /// Examples:
    ///   `sub.example.com`          → `example.com`
    ///   `sub.example.co.uk`        → `example.co.uk`
    ///   `a.tenant.herokuapp.com`   → `tenant.herokuapp.com`
    ///   `herokuapp.com`            → nil (public suffix)
    ///   `localhost`, `127.0.0.1`   → nil
    ///
    /// Expects a lowercase host with IDN labels in Punycode — what browsers
    /// send and what `hostname(from:)` returns.
    public static func eTLDPlusOne(host: String) -> String? {
        // Empty strings and IP addresses need no guard: no rule is numeric or
        // contains a colon, so they fall through to the fail-closed `nil`.
        let labels = host.split(separator: ".").map(String.init)
        // `tails[i]` is the host without its first `i` labels, longest first.
        let tails = labels.indices.map { labels[$0...].joined(separator: ".") }

        // An exception rule wins over every other matching rule; the exception
        // itself is the registrable domain.
        if let exception = tails.first(where: { exceptions.contains($0) }) {
            return exception
        }

        // Otherwise the longest matching rule is the public suffix.
        for index in tails.indices {
            let isPublicSuffix = suffixes.contains(tails[index])
                || (index + 1 < tails.count && wildcardParents.contains(tails[index + 1]))
            if isPublicSuffix {
                return index > 0 ? tails[index - 1] : nil
            }
        }

        return nil
    }

    /// Extracts the hostname component of a URL, lowercasing it.
    public static func hostname(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        return host.lowercased()
    }

    private static func ruleSet(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").lazy.map(String.init))
    }
}
