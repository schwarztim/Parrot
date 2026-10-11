import Foundation

/// Picks the mode for a dictation from the app and website it goes into. [LLM]
///
/// Order: a mode whose sites match the browser address, then a mode that
/// claims the frontmost app, then the user's last selected mode.
///
/// Site rule (the spec leaves it open): a site matches its own host and
/// every subdomain, so `example.com` matches `docs.example.com` but not
/// `notexample.com`. A leading `www.` is ignored on both sides. A site with
/// a path (`docs.google.com/document`) also needs the address path to start
/// with it. When several sites match, the longest (most specific) one wins;
/// a tie goes to the mode earlier in the user's order.
enum ModeActivation {

    /// The mode for a dictation into `context`; `fallback` when nothing matches.
    static func resolve(modes: [Mode], context: DictationContext?, fallback: Mode) -> Mode {
        if let match = mode(forURL: context?.browserURL, in: modes) { return match }
        if let match = mode(forBundleID: context?.bundleID, in: modes) { return match }
        return fallback
    }

    /// First mode (in list order) that claims `bundleID`, case-insensitively.
    static func mode(forBundleID bundleID: String?, in modes: [Mode]) -> Mode? {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return nil }
        return modes.first { $0.appBundleIDs?.contains { $0.lowercased() == id } == true }
    }

    /// The mode with the most specific site matching `url`.
    static func mode(forURL url: String?, in modes: [Mode]) -> Mode? {
        guard let url, let target = parse(url) else { return nil }
        var best: (mode: Mode, strength: Int)?
        for mode in modes {
            for site in mode.activationSites {
                guard let strength = matchStrength(site: site, target: target) else { continue }
                if best == nil || strength > best!.strength {
                    best = (mode, strength)
                }
            }
        }
        return best?.mode
    }

    /// Whether `site` matches `url` (for tests and the activation sheet).
    static func siteMatches(_ site: String, url: String) -> Bool {
        guard let target = parse(url) else { return false }
        return matchStrength(site: site, target: target) != nil
    }

    /// A site entry as stored: lowercased host plus optional path, with no
    /// scheme, `www.`, port, query or trailing slash. Nil when it has no host.
    static func normalizedSite(_ raw: String) -> String? {
        guard let parsed = parse(raw) else { return nil }
        return parsed.path.isEmpty ? parsed.host : parsed.host + parsed.path
    }

    /// Just the scheme and host of an address ("https://mail.google.com").
    static func siteOnly(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty else {
            return nil
        }
        return "\(components.scheme ?? "https")://\(host.lowercased())"
    }

    /// The lowercased host of an address, without `www.`.
    static func host(of url: String) -> String? {
        parse(url)?.host
    }

    // MARK: - Private

    private struct Target {
        let host: String
        /// Lowercased path without a trailing slash; empty for the root.
        let path: String
    }

    private static func parse(_ raw: String) -> Target? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
              var host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = components.path.lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return Target(host: host, path: path)
    }

    private static func matchStrength(site: String, target: Target) -> Int? {
        guard let entry = parse(site) else { return nil }
        let hostMatches = target.host == entry.host || target.host.hasSuffix("." + entry.host)
        guard hostMatches else { return nil }
        if !entry.path.isEmpty {
            guard target.path == entry.path || target.path.hasPrefix(entry.path + "/") else { return nil }
        }
        return entry.host.count + entry.path.count
    }
}
