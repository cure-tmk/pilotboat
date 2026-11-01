import Core
import Foundation
import Testing
@testable import Persistence

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func config(_ interval: Int) -> Config {
    var c = Config()
    c.general.pollIntervalSeconds = interval
    c.general.monitoringOffUntil = Date(timeIntervalSince1970: 1_700_000_000)
    return c
}

@Test func missingFileGivesDefault() throws {
    #expect(try FileConfigStore(directory: tempDir()).load() == Config())
}

@Test func saveLoadAndBackup() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = FileConfigStore(directory: dir)
    try s.save(config(10))
    #expect(try s.load() == config(10))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json.bak").path))
    try s.save(config(20))
    try s.save(config(30))
    #expect(try s.load() == config(30))
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    let bak = try d.decode(Config.self, from: Data(contentsOf: dir.appendingPathComponent("config.json.bak")))
    #expect(bak.general.pollIntervalSeconds == 20)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json.tmp").path))
}

@Test func corruptThenRestore() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = FileConfigStore(directory: dir)
    try s.save(config(10))
    try s.save(config(20))
    let url = dir.appendingPathComponent("config.json")
    try Data("{oops".utf8).write(to: url)
    #expect(throws: ConfigStoreError.corrupt(path: url.path, backupAvailable: true)) { try s.load() }
    #expect(try s.restoreFromBackup() == config(10))
    #expect(try s.load() == config(10))
}

@Test func corruptWithoutBackup() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    try Data("[]".utf8).write(to: url)
    let s = FileConfigStore(directory: dir)
    #expect(throws: ConfigStoreError.corrupt(path: url.path, backupAvailable: false)) { try s.load() }
    #expect(throws: ConfigStoreError.noBackup) { try s.restoreFromBackup() }
}

@Test func savingOverCorruptKeepsGoodBackup() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = FileConfigStore(directory: dir)
    try s.save(config(10))
    try s.save(config(20))
    try Data("{oops".utf8).write(to: dir.appendingPathComponent("config.json"))
    try s.save(config(30))
    #expect(try s.restoreFromBackup() == config(10))
}

@Test func schemaV1WithUnknownFieldLoads() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = #"{"schemaVersion":1,"futureField":{"a":1},"general":{"pollIntervalSeconds":77,"extra":true}}"#
    try Data(json.utf8).write(to: dir.appendingPathComponent("config.json"))
    let c = try FileConfigStore(directory: dir).load()
    #expect(c.general.pollIntervalSeconds == 77)
    #expect(c.schemaVersion == 1)
}

@Test func migrationHookRunsOnSchemaVersionOnly() throws {
    var json: [String: Any] = ["schemaVersion": Config.currentSchemaVersion, "x": 1]
    try ConfigMigrations.migrate(json: &json)
    #expect(json["x"] as? Int == 1)
}
