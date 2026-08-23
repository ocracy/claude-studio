import Foundation

/// The phones this Mac sends notifications to.
///
/// A push subscription outlives the app that created it. Deleting the web app from
/// a Home Screen does not tell this Mac anything — the browser usually keeps the
/// service worker registered, so the notifications keep arriving from a thing the
/// user believes they removed. And a phone that installs the app twice (once from
/// the address, once from the mesh name) is TWO subscriptions: every notification
/// arrives twice, and nothing on the phone can undo the half of it that belongs to
/// an app that is no longer there.
///
/// So the list lives here, on the machine that does the sending, and revoking is
/// one button. The file is `push-subscriptions.json`, written by the bridge — both
/// sides re-read immediately before writing, the `sessions.json` discipline.
struct PushDevice: Identifiable {
    var endpoint: String
    /// The origin it subscribed from: `mac.netbird.cloud:7443`, or an address.
    var host: String?
    var userAgent: String?
    var addedAt: Date?
    var seenAt: Date?
    var enabled: Bool
    var silent: Bool
    /// Projects it asked to hear about; empty means all of them.
    var projects: [String]

    var id: String { endpoint }

    /// Which push service holds the subscription — the closest thing to a device
    /// name a browser is willing to reveal.
    var service: String {
        guard let host = URL(string: endpoint)?.host else { return "unknown" }
        if host.contains("fcm.googleapis") || host.contains("android") { return "Android" }
        if host.contains("push.apple") { return "iPhone or iPad" }
        if host.contains("mozilla") { return "Firefox" }
        if host.contains("windows") || host.contains("notify.windows") { return "Windows" }
        return host
    }

    /// A one-line description of the browser, when it said.
    var browser: String? {
        guard let agent = userAgent else { return nil }
        for name in ["Chrome", "Safari", "Firefox", "Edge", "Samsung"] where agent.contains(name) {
            return name
        }
        return nil
    }

    /// The last eight characters of the endpoint: enough to tell two entries apart
    /// without printing a 200-character URL into a settings pane.
    var shortID: String { String(endpoint.suffix(8)) }
}

enum PushDevices {

    static var file: URL {
        Paths.appSupport.appendingPathComponent("push-subscriptions.json")
    }

    static func read() -> [PushDevice] {
        guard let data = try? Data(contentsOf: file),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }

        return array.compactMap { entry in
            guard let endpoint = entry["endpoint"] as? String, !endpoint.isEmpty else { return nil }
            let device = entry["device"] as? [String: Any]
            let preferences = entry["preferences"] as? [String: Any]
            return PushDevice(
                endpoint: endpoint,
                host: (device?["host"] as? String)?.nilIfEmpty,
                userAgent: (device?["userAgent"] as? String)?.nilIfEmpty,
                addedAt: (entry["addedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                seenAt: (entry["seenAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                enabled: preferences?["enabled"] as? Bool ?? true,
                silent: preferences?["silent"] as? Bool ?? false,
                projects: preferences?["projects"] as? [String] ?? [])
        }
        .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    }

    /// Drops one device. The bridge re-reads this file for every notification, so
    /// the next one is already not sent — no restart, nothing to reload.
    static func revoke(_ device: PushDevice) {
        guard let data = try? Data(contentsOf: file),
              var array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return }
        array.removeAll { ($0["endpoint"] as? String) == device.endpoint }
        write(array)
    }

    static func revokeAll() { write([]) }

    private static func write(_ array: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: array,
                                                     options: [.prettyPrinted]) else { return }
        Paths.writeAtomically(data, to: file)
    }
}
