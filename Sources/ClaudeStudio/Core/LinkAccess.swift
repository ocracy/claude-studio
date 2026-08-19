import Foundation

/// How a writable link reaches Claude: file access to the linked project, and
/// nothing else.
///
/// The obvious way to grant that is `--add-dir`, and it is the wrong one. Claude
/// Code loads an added directory's *skills* along with its files, so linking a
/// project puts its `deploy` in the session's skill list next to this project's own
/// — two entries, identical names, and the tool call that picks between them
/// carries only a name, never a path. Nothing downstream can tell which one ran:
/// not the permission dialog, not a hook, not the transcript. For a deploy skill
/// that is a production server reached by accident.
///
/// `permissions.additionalDirectories` grants exactly the same file access — read
/// and write, measured, not assumed — and loads no skills at all. The linked
/// project's skills never enter the list, so they cannot be picked by mistake. That
/// is the whole guarantee, and it is structural: there is no rule to obey and no
/// prompt to get wrong. Invoking one deliberately is Claude Studio's job, from its
/// own interface, in the project that owns it.
///
/// Delivered as a `--settings` layer, which is MERGED with the project's own
/// `.claude/settings.json` — hooks and permissions defined there survive untouched.
@MainActor
enum LinkAccess {
    /// Written fresh at every session start, so a link added since the last one
    /// takes effect on the next open — what the UI's reopen hint refers to.
    /// Nil when the project has no writable links.
    static func settingsFile(project: Project, links: [ProjectLink]) -> String? {
        let dirs = links.map(\.path)
        guard !dirs.isEmpty else { return nil }
        let payload = ["permissions": ["additionalDirectories": dirs]]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let file = Paths.linkAccess(project)
        Paths.writeAtomically(data, to: file)
        return FileManager.default.fileExists(atPath: file.path) ? file.path : nil
    }
}
