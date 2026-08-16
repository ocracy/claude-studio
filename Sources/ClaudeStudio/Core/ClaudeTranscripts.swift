import Foundation

/// Claude Code'un konuşma dosyaları: `~/.claude/projects/<kodlanmış yol>/<sid>.jsonl`.
///
/// Kapatılmış bir oturumu `claude --resume <sid>` ile geri açmadan ÖNCE burada
/// konuşmanın gerçekten durup durmadığına bakılır. Yoksa Claude "No session
/// found" deyip anında çıkar ve kullanıcı boş, ölü bir terminalle kalır.
enum ClaudeTranscripts {

    private static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/projects", isDirectory: true)

    /// Yol kodlaması: `/Users/ali/www/proje` → `-Users-ali-www-proje`.
    /// Noktalı yollarda Claude'un tam şemasından emin olmadığımız için iki
    /// aday da denenir — yanlış tahmin yüzünden sürdürülebilir bir konuşmayı
    /// kaçırmaktansa iki dosya yolu kontrol etmek ucuz.
    static func directories(for projectPath: String) -> [URL] {
        let slashOnly = projectPath.replacingOccurrences(of: "/", with: "-")
        let slashAndDot = slashOnly.replacingOccurrences(of: ".", with: "-")
        return Set([slashOnly, slashAndDot]).map {
            root.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Bu projede sürdürülebilir bir konuşma var mı?
    static func exists(projectPath: String, sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        for directory in directories(for: projectPath) {
            let file = directory.appendingPathComponent("\(sessionID).jsonl")
            let size = (try? FileManager.default
                .attributesOfItem(atPath: file.path))?[.size] as? NSNumber
            // Boş dosya = hiç mesaj yazılmamış; resume yine "No session found" der.
            if let size, size.intValue > 0 { return true }
        }
        return false
    }
}
