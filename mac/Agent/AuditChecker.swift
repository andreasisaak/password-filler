import Foundation

/// Pure-function diagnostic that mirrors `mac/scripts/dev/pf-audit.py`.
///
/// Inputs come from the Agent's existing sync pipeline — split in two so the
/// audit can flag URL-less items (which the production sync drops before
/// `op item get`) without spending extra `op` calls:
///
/// * `urlLessSummaries` — items dropped by the `withHosts` filter; surface as
///   `noWebsite` only (no `fields` payload to inspect for credentials).
/// * `rawItems` — fully-fetched items with `fields` and `urls`; subjected to
///   the full credential analysis + collision detection.
///
/// Output is sorted alphabetically by title. Throws is reserved — current
/// implementation never throws but the contract leaves room for future
/// validation without breaking callers.
public enum AuditChecker {

    /// Mirrors `htaccess|basicauth|basic.?auth|htpasswd|webuser` from
    /// `ItemStore.swift`. Identical pattern + flags so audit and runtime agree
    /// on what counts as a credential section.
    private static let sectionRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(htaccess|basicauth|basic.?auth|htpasswd|webuser)"#,
            options: [.caseInsensitive]
        )
    }()

    public static func analyze(
        urlLessSummaries: [ItemSummary],
        rawItems: [FullItem],
        now: Date = Date()
    ) throws -> [Finding] {
        let intermediates = buildIntermediates(
            urlLessSummaries: urlLessSummaries,
            rawItems: rawItems
        )

        let groups = mergeGroups(intermediates)
        let hostnameIndex = buildHostnameIndex(groups)

        var findings: [Finding] = []

        for (key, members) in groups {
            guard let canonical = members.first else { continue }
            var defects: [Defect] = []

            if canonical.hostnames.isEmpty {
                defects.append(.noWebsite)
            }

            // Credential-shape defects need the item's `fields` payload — only
            // available for items we've fetched via `op item get`.
            if !canonical.summaryOnly {
                if canonical.sectionPresent && !(canonical.sectionUserOk && canonical.sectionPassOk) {
                    if !canonical.sectionUserOk {
                        defects.append(.sectionBrokenUsername)
                    }
                    if !canonical.sectionPassOk {
                        defects.append(.sectionBrokenPassword)
                    }
                } else {
                    if canonical.user == nil {
                        defects.append(.noUsername)
                    }
                    if canonical.password == nil {
                        defects.append(.noPassword)
                    }
                }
            }

            defects.append(contentsOf: collisionDefects(
                forGroup: key,
                canonical: canonical,
                groups: groups,
                hostnameIndex: hostnameIndex
            ))

            guard !defects.isEmpty else { continue }

            let vaults = Array(Set(members.map(\.vault))).sorted()
            findings.append(Finding(
                id: Finding.makeId(title: canonical.title, vaults: vaults),
                title: canonical.title,
                vaults: vaults,
                defects: defects,
                detectedAt: now
            ))
        }

        findings.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return findings
    }

    // MARK: - Building blocks

    /// Internal projection — flattens both summary and full-item inputs into the same
    /// merge-friendly shape. Matches `pf-audit.py::items_data` field-for-field.
    fileprivate struct Intermediate {
        let title: String
        let vault: String
        let hostnames: [String]
        let user: String?
        let password: String?
        let sectionPresent: Bool
        let sectionUserOk: Bool
        let sectionPassOk: Bool
        /// True when the source was an `ItemSummary` (no `fields` payload). Suppresses
        /// credential-shape defects — we can't know about user/pass/section integrity
        /// without `op item get`, and reporting `noUsername` would be a false claim.
        let summaryOnly: Bool
    }

    fileprivate struct MergeKey: Hashable {
        let title: String
        let hostnames: [String]   // sorted
        let user: String          // empty string for nil — matches Python tuple behaviour
        let password: String
    }

    private static func buildIntermediates(
        urlLessSummaries: [ItemSummary],
        rawItems: [FullItem]
    ) -> [Intermediate] {
        var out: [Intermediate] = []
        out.reserveCapacity(urlLessSummaries.count + rawItems.count)

        for summary in urlLessSummaries {
            out.append(Intermediate(
                title: summary.title,
                vault: summary.vault?.name ?? "?",
                hostnames: [],
                user: nil,
                password: nil,
                sectionPresent: false,
                sectionUserOk: false,
                sectionPassOk: false,
                summaryOnly: true
            ))
        }

        for raw in rawItems {
            let analysis = analyzeCredentials(item: raw)
            out.append(Intermediate(
                title: raw.title,
                vault: raw.vault?.name ?? "?",
                hostnames: ItemStore.extractHostnames(from: raw.urls),
                user: analysis.user,
                password: analysis.password,
                sectionPresent: analysis.sectionPresent,
                sectionUserOk: analysis.sectionUserOk,
                sectionPassOk: analysis.sectionPassOk,
                summaryOnly: false
            ))
        }

        return out
    }

    private static func mergeGroups(_ items: [Intermediate]) -> [MergeKey: [Intermediate]] {
        var groups: [MergeKey: [Intermediate]] = [:]
        for item in items {
            let key = MergeKey(
                title: item.title,
                hostnames: item.hostnames.sorted(),
                user: item.user ?? "",
                password: item.password ?? ""
            )
            groups[key, default: []].append(item)
        }
        return groups
    }

    private static func buildHostnameIndex(
        _ groups: [MergeKey: [Intermediate]]
    ) -> [String: Set<MergeKey>] {
        var index: [String: Set<MergeKey>] = [:]
        for (key, members) in groups {
            guard let canon = members.first else { continue }
            for host in canon.hostnames {
                index[host, default: []].insert(key)
            }
        }
        return index
    }

    private static func collisionDefects(
        forGroup key: MergeKey,
        canonical: Intermediate,
        groups: [MergeKey: [Intermediate]],
        hostnameIndex: [String: Set<MergeKey>]
    ) -> [Defect] {
        var collisionsByOther: [MergeKey: [String]] = [:]
        for host in canonical.hostnames {
            guard let owners = hostnameIndex[host] else { continue }
            for other in owners where other != key {
                collisionsByOther[other, default: []].append(host)
            }
        }

        let canonicalHostsSet = Set(canonical.hostnames)
        var defects: [Defect] = []

        // Sort by other-title first to keep output deterministic across runs
        // (Dictionary iteration order is undefined in Swift).
        let sortedCollisions = collisionsByOther.sorted { lhs, rhs in
            lhs.key.title.localizedCaseInsensitiveCompare(rhs.key.title) == .orderedAscending
        }

        for (otherKey, shared) in sortedCollisions {
            guard let otherMembers = groups[otherKey], let otherCanon = otherMembers.first else { continue }
            let otherVaults = Array(Set(otherMembers.map(\.vault))).sorted()
            let otherHostsSet = Set(otherCanon.hostnames)

            let isVaultDuplicate = (otherCanon.title == canonical.title)
                && (otherHostsSet == canonicalHostsSet)

            if isVaultDuplicate {
                defects.append(.vaultDuplicate(
                    otherTitle: otherCanon.title,
                    otherVaults: otherVaults,
                    hostnameCount: shared.count
                ))
            } else {
                defects.append(.hostnameCollision(
                    otherTitle: otherCanon.title,
                    otherVaults: otherVaults,
                    hostnames: shared.sorted()
                ))
            }
        }

        return defects
    }

    // MARK: - Credential analysis

    /// Field-level result of mirroring `ItemStore.extractCredentials` plus section-integrity
    /// flags the runtime extractor doesn't expose.
    fileprivate struct CredentialAnalysis {
        let user: String?
        let password: String?
        /// At least one field's section label matches the htaccess regex.
        let sectionPresent: Bool
        /// Section has a STRING field with a non-empty value.
        let sectionUserOk: Bool
        /// Section has a CONCEALED field with a non-empty value.
        let sectionPassOk: Bool
    }

    fileprivate static func analyzeCredentials(item: FullItem) -> CredentialAnalysis {
        let fields = item.fields ?? []

        let sectionFields = fields.filter { field in
            guard let label = field.section?.label else { return false }
            let range = NSRange(label.startIndex..<label.endIndex, in: label)
            return sectionRegex.firstMatch(in: label, range: range) != nil
        }

        let sectionUser = nilIfEmpty(sectionFields.first(where: { $0.type == "STRING" })?.value)
        let sectionPass = nilIfEmpty(sectionFields.first(where: { $0.type == "CONCEALED" })?.value)

        let topUser = nilIfEmpty(fields.first(where: { $0.id == "username" && $0.section == nil })?.value)
        let topPass = nilIfEmpty(fields.first(where: { $0.id == "password" && $0.section == nil })?.value)

        let user: String?
        let pwd: String?
        if let u = sectionUser, let p = sectionPass {
            user = u; pwd = p
        } else if let u = topUser, let p = topPass {
            user = u; pwd = p
        } else {
            user = sectionUser ?? topUser
            pwd = sectionPass ?? topPass
        }

        return CredentialAnalysis(
            user: user,
            password: pwd,
            sectionPresent: !sectionFields.isEmpty,
            sectionUserOk: sectionUser != nil,
            sectionPassOk: sectionPass != nil
        )
    }

    private static func nilIfEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
