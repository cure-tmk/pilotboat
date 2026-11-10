import Core
import Foundation

public enum SetupHook: String, Codable, CaseIterable, Sendable { case skip, inherit, run }

public struct OrcaSettings: Codable, Hashable, Sendable {
    public var orcaPath: String?
    public var agent: String
    public var model: String?
    public var effort: String?
    public var setupForReview: SetupHook
    public var setupForOwnPR: SetupHook
    public var activate: Bool

    public init(orcaPath: String? = nil, agent: String, model: String? = nil, effort: String? = nil, setupForReview: SetupHook = .skip, setupForOwnPR: SetupHook = .inherit, activate: Bool = false) {
        self.orcaPath = orcaPath; self.agent = agent; self.model = model; self.effort = effort
        self.setupForReview = setupForReview; self.setupForOwnPR = setupForOwnPR; self.activate = activate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orcaPath = try c.decodeIfPresent(String.self, forKey: .orcaPath)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        setupForReview = try c.decodeIfPresent(SetupHook.self, forKey: .setupForReview) ?? .skip
        setupForOwnPR = try c.decodeIfPresent(SetupHook.self, forKey: .setupForOwnPR) ?? .inherit
        activate = try c.decodeIfPresent(Bool.self, forKey: .activate) ?? false
    }

    /// Throws `OrcaLauncherError.invalidSettings` naming the offending key.
    public init(json: JSONValue) throws {
        do { self = try json.decode(OrcaSettings.self) }
        catch let error as DecodingError { throw OrcaLauncherError.invalidSettings(Self.path(of: error)) }
        catch { throw OrcaLauncherError.invalidSettings(String(describing: error)) }
    }

    public func json() throws -> JSONValue { try JSONValue(encoding: self) }

    var executable: String { orcaPath ?? "orca" }
    var modelArgs: [String] { (model.map { ["--model", $0] } ?? []) + (effort.map { ["--effort", $0] } ?? []) }

    private static func path(of error: DecodingError) -> String {
        let keys: [any CodingKey]
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): keys = c.codingPath
        case .keyNotFound(let key, let c): keys = c.codingPath + [key]
        @unknown default: keys = []
        }
        return keys.isEmpty ? "settings" : keys.map(\.stringValue).joined(separator: ".")
    }
}

public struct OrcaRepo: Hashable, Sendable {
    public var id: String
    public var path: String
    public var displayName: String
    public var canonicalKey: String?
}

public extension OrcaRepo {
    /// "owner/name" when `canonicalKey` is "<host>/owner/name" for `host` (case-insensitive).
    func fullName(host: String) -> String? {
        guard let key = canonicalKey else { return nil }
        let prefix = host.lowercased() + "/"
        guard key.lowercased().hasPrefix(prefix) else { return nil }
        let name = key.dropFirst(prefix.count)
        return name.isEmpty ? nil : String(name)
    }
}
