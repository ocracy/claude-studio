import Foundation

enum PullRequests {

    struct Status: Equatable {
        enum Checks: Equatable { case none, pending, passed, failed }
        enum State: Equatable { case open, draft, merged, closed }

        var number: Int
        var title: String
        var url: URL
        var state: State
        var checks: Checks
        var failing: Int
        var total: Int
    }

    private static let gh: String? = Shell.findExecutable(["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"])

    static func status(at path: String) -> Status? {
        guard let gh else { return nil }
        let result = Shell.run(gh, ["pr", "view", "--json", "number,title,url,state,isDraft,statusCheckRollup"],
                               cwd: path, env: ["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"])
        guard result.status == 0 else { return nil }
        return parse(Data(result.output.utf8))
    }

    static func parse(_ json: Data) -> Status? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let number = object["number"] as? Int,
              let link = (object["url"] as? String).flatMap(URL.init(string:))
        else { return nil }

        let state: Status.State
        switch object["state"] as? String {
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default:       state = object["isDraft"] as? Bool == true ? .draft : .open
        }

        let rollup = object["statusCheckRollup"] as? [[String: Any]] ?? []
        var failing = 0, pending = 0
        for check in rollup {
            let conclusion = (check["conclusion"] as? String ?? check["state"] as? String ?? "").uppercased()
            let progress = (check["status"] as? String ?? "").uppercased()
            if ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"].contains(conclusion) {
                failing += 1
            } else if conclusion.isEmpty || conclusion == "PENDING" || conclusion == "EXPECTED"
                        || (!progress.isEmpty && progress != "COMPLETED") {
                pending += 1
            }
        }
        let checks: Status.Checks = rollup.isEmpty ? .none
            : failing > 0 ? .failed : pending > 0 ? .pending : .passed

        return Status(number: number, title: object["title"] as? String ?? "", url: link,
                      state: state, checks: checks, failing: failing, total: rollup.count)
    }
}
