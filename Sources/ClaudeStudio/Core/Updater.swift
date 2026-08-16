import Foundation
import SwiftUI
import AppKit

/// GitHub sürümlerinden kendini güncelleyen basit güncelleyici.
///
/// Sözleşme: her sürüm `v<sürüm>` etiketiyle yayınlanır ve içinde
/// `ClaudeStudio.zip` adlı bir varlık bulunur (bkz. `dist.sh`). Uygulama
/// kurulu sürümü etiketle kıyaslar; yenisi varsa indirir, paketi değiştirir ve
/// kendini yeniden başlatır.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repository = "ocracy/claude-studio"
    static let assetName = "ClaudeStudio.zip"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL, notes: String)
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Kurulu sürüm (`CFBundleShortVersionString`).
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var availableVersion: String? {
        if case let .available(version, _, _) = state { return version }
        return nil
    }

    private init() {}

    // MARK: - Denetleme

    /// Açılışta sessizce, menüden ise sonucu göstererek çalışır.
    func check(silent: Bool = false) {
        if case .downloading = state { return }
        if case .installing = state { return }
        if !silent { state = .checking }

        Task {
            do {
                let release = try await fetchLatest()
                let newer = Self.isNewer(release.version, than: currentVersion)
                if newer {
                    state = .available(version: release.version, url: release.asset, notes: release.notes)
                } else if !silent {
                    state = .upToDate
                } else {
                    state = .idle
                }
            } catch {
                if !silent { state = .failed(Self.describe(error)) }
            }
        }
    }

    private struct Release {
        let version: String
        let asset: URL
        let notes: String
    }

    private func fetchLatest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.message("GitHub yanıt vermedi.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { throw UpdateError.message("Sürüm bilgisi çözümlenemedi.") }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String) == Self.assetName }),
              let link = asset["browser_download_url"] as? String,
              let assetURL = URL(string: link)
        else { throw UpdateError.message("Sürümde \(Self.assetName) yok.") }

        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       asset: assetURL,
                       notes: (json["body"] as? String)?.nilIfEmpty ?? "")
    }

    // MARK: - Kurulum

    /// İndirir, paketi değiştirir ve uygulamayı yeniden başlatır.
    func install() {
        guard case let .available(version, url, _) = state else { return }
        state = .downloading(progress: 0)

        Task {
            do {
                let zip = try await download(url)
                state = .installing
                try replaceBundle(with: zip, version: version)
            } catch {
                state = .failed(Self.describe(error))
            }
        }
    }

    private func download(_ url: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.message("İndirme başarısız.")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeStudio-update.zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Çalışan paketi kendi üzerine yazamayız; işi bir kabuk script'ine
    /// devrederiz: uygulama çıkar, script paketi değiştirir ve yeniden açar.
    private func replaceBundle(with zip: URL, version: String) throws {
        let unpacked = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeStudio-update", isDirectory: true)
        try? FileManager.default.removeItem(at: unpacked)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)

        let extract = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard extract.status == 0 else { throw UpdateError.message("Arşiv açılamadı.") }

        guard let newApp = try FileManager.default
            .contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError.message("Arşivde uygulama bulunamadı.") }

        let destination = Bundle.main.bundleURL
        let script = """
        sleep 1
        rm -rf \(Shell.quoted(destination.path))
        /usr/bin/ditto \(Shell.quoted(newApp.path)) \(Shell.quoted(destination.path))
        /usr/bin/xattr -cr \(Shell.quoted(destination.path))
        rm -rf \(Shell.quoted(unpacked.path)) \(Shell.quoted(zip.path))
        open \(Shell.quoted(destination.path))
        """
        Shell.runDetached(script)
        NSApp.terminate(nil)
    }

    // MARK: - Yardımcılar

    enum UpdateError: Error { case message(String) }

    private static func describe(_ error: Error) -> String {
        if case let UpdateError.message(text) = error { return text }
        return (error as NSError).localizedDescription
    }

    /// Noktalı sürüm karşılaştırması: 1.10.0 > 1.9.3.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
