import Foundation

/// 查 GitHub 上本仓库的最新 Release 用于版本检查。走 v3 REST API，无需 token。
enum UpdateChecker {

    /// 仓库路径。发布 Releases 时打 tag（如 `v1.7.0`），本 API 就会返回它。
    /// 【修改说明】：这里已改为你自己的仓库地址。
    static let repository = "XiePolice/BaiyunKeys-iOS"

    struct Release {
        /// 例如 `v1.7.0` 或 `1.7.0`。
        let tag: String
        /// Release 标题（GitHub 页面上显示的那个名字，为空则取 tag）。
        let title: String
        /// Release 正文（Markdown）。
        let notes: String
        /// 在 GitHub 上的 Release 页面链接。
        let webURL: URL
    }

    enum Failure: LocalizedError {
        case network(String)
        case rateLimited
        case noRelease
        case decode

        var errorDescription: String? {
            switch self {
            case .network(let msg): return "检查更新失败：\(msg)"
            case .rateLimited:      return "GitHub 请求过于频繁，请稍后重试"
            case .noRelease:        return "还没有发布任何版本"
            case .decode:           return "返回数据解析失败"
            }
        }
    }

    /// 取仓库的 latest release。GitHub 里 draft / prerelease 不算在 latest 里。
    static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 403:       throw Failure.rateLimited
            case 404:       throw Failure.noRelease
            default:        throw Failure.network("HTTP \(http.statusCode)")
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.decode
        }
        let tag = (json["tag_name"] as? String) ?? ""
        let urlString = (json["html_url"] as? String) ?? ""
        guard !tag.isEmpty, let url = URL(string: urlString) else {
            throw Failure.decode
        }
        return Release(
            tag: tag,
            title: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            notes: (json["body"] as? String) ?? "",
            webURL: url
        )
    }

    /// 语义化版本号比较：`latest > current` 返回 true。允许带 `v` 前缀。
    /// 不完全遵守 SemVer 的 pre-release 规则（只按数字段比大小，够本 App 用了）。
    static func isNewer(latest: String, current: String) -> Bool {
        let l = parseVersion(latest)
        let c = parseVersion(current)
        for i in 0..<max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv > cv { return true }
            if lv < cv { return false }
        }
        return false
    }

    private static func parseVersion(_ raw: String) -> [Int] {
        raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .compactMap { Int($0.prefix(while: { $0.isNumber })) }
    }
}
