import Foundation

/// eTLD+1 extraction — Swift equivalent of `tldts.getDomain()`.
///
/// Current implementation uses a curated in-memory rule set covering the TLDs
/// commonly seen in 1Password htaccess items plus common two-part effective
/// TLDs. This intentionally avoids a ~280 KB bundled PSL file for the first
/// implementation pass.
///
/// TODO (Phase 2 follow-up): replace `curatedSuffixes` with a bundled
/// `public_suffix_list.dat` parser if we encounter a hostname whose TLD is not
/// covered here. The API (`eTLDPlusOne(host:)`) stays stable.
public enum PublicSuffixList {

    /// Multi-label effective TLDs we recognise. Single-label TLDs (`.com`, `.de`,
    /// `.org`, …) are handled by a simpler fallback rule: any host with ≥2 labels
    /// where the final label is in `knownSingleLabelTLDs` returns the last two labels.
    ///
    /// If you add entries, keep them lowercase and dot-prefixed for readable matching.
    private static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "gov.uk", "ac.uk",
        "com.au", "net.au", "org.au", "edu.au",
        "co.jp", "ne.jp", "or.jp",
        "com.br", "com.mx", "com.ar",
        "co.nz", "co.za", "co.kr",
        "or.at", "ac.at", "gv.at",
        "co.il", "ac.il",
    ]

    private static let knownSingleLabelTLDs: Set<String> = [
        // Generic
        "com", "org", "net", "info", "biz", "io", "app", "dev", "xyz",
        "tech", "cloud", "email", "online", "site", "store", "shop",
        "agency", "studio", "media", "design", "consulting",
        // Country — focused on DACH + EU + common
        "de", "at", "ch", "li",
        "fr", "it", "es", "pt", "nl", "be", "lu", "dk", "se", "no", "fi", "pl",
        "cz", "sk", "hu", "si", "hr", "ro", "bg", "gr",
        "uk", "ie", "us", "ca", "au", "nz", "jp", "br", "mx", "ar",
        "ru", "ua", "tr",
        // Short / branded common
        "co", "me", "tv",
    ]

    /// Returns the effective-TLD+1 for a hostname, or `nil` if the hostname has no
    /// recognisable public suffix (e.g. `localhost`, IP addresses, unknown TLD).
    ///
    /// Examples:
    ///   `example.com`          → `example.com`
    ///   `sub.example.com`      → `example.com`
    ///   `deep.sub.example.com` → `example.com`
    ///   `example.co.uk`        → `example.co.uk`
    ///   `sub.example.co.uk`    → `example.co.uk`
    ///   `localhost`            → nil
    ///   `127.0.0.1`            → nil
    public static func eTLDPlusOne(host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        // Reject IPs (rudimentary — works for IPv4/IPv6 well enough for our inputs).
        if trimmed.contains(":") { return nil }
        if trimmed.split(separator: ".").allSatisfy({ Int($0) != nil }) { return nil }

        let labels = trimmed.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }

        // Try longest multi-label match first.
        if labels.count >= 3 {
            let lastTwo = labels.suffix(2).joined(separator: ".")
            if multiLabelSuffixes.contains(lastTwo) {
                return labels.suffix(3).joined(separator: ".")
            }
        }

        // Fall back to single-label TLD.
        guard let tld = labels.last, knownSingleLabelTLDs.contains(tld) else {
            return nil
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Extracts the hostname component of a URL, lowercasing it.
    public static func hostname(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        return host.lowercased()
    }
}
