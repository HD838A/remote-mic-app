import Darwin
import Foundation

private let schemaVersion = 1
private let qianwenBundleURL = URL(fileURLWithPath: "/Library/Input Methods/QianwenIME.app")
private let runtimeLibraryURL = qianwenBundleURL
    .appendingPathComponent("Contents/Frameworks/libqianwen_unet_runtime.dylib")
private let historyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/QianwenIME/VoiceUsage/voice_usage.json")

private typealias InitializeRuntime = @convention(c) (
    UnsafePointer<CChar>,
    UnsafePointer<CChar>
) -> Int32
private typealias DecryptPayload = @convention(c) (
    UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?
private typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

private struct ReaderOutput: Codable {
    let schemaVersion: Int
    let id: String
    let timestampMs: Int64
    let text: String
}

private func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1)
    else { return nil }
    return CommandLine.arguments[index + 1]
}

private func int64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
}

private func fail(_ code: Int32) -> Never {
    fflush(stdout)
    fflush(stderr)
    _exit(code)
}

guard let afterMs = argument("--after-ms").flatMap(Int64.init),
      let beforeMs = argument("--before-ms").flatMap(Int64.init),
      afterMs <= beforeMs,
      FileManager.default.fileExists(atPath: runtimeLibraryURL.path),
      FileManager.default.fileExists(atPath: historyURL.path),
      let handle = dlopen(runtimeLibraryURL.path, RTLD_NOW | RTLD_LOCAL),
      let initializeSymbol = dlsym(handle, "qianwen_unet_initialize_for_process"),
      let decryptSymbol = dlsym(handle, "qianwen_unet_decrypt_base64_with_internal_wsg"),
      let freeSymbol = dlsym(handle, "qianwen_unet_string_free")
else { fail(2) }

private let initialize = unsafeBitCast(initializeSymbol, to: InitializeRuntime.self)
private let decrypt = unsafeBitCast(decryptSymbol, to: DecryptPayload.self)
private let freeString = unsafeBitCast(freeSymbol, to: FreeString.self)
let version = Bundle(url: qianwenBundleURL)?
    .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
_ = "QianwenIMEService".withCString { processName in
    version.withCString { buildVersion in
        initialize(processName, buildVersion)
    }
}

guard let envelopeData = try? Data(contentsOf: historyURL),
      let envelope = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
      envelope["schemaVersion"] as? Int == schemaVersion,
      envelope["encryption"] as? String == "unet_internal_wsg_base64",
      let payload = envelope["payload"] as? String,
      let decrypted = payload.withCString({ decrypt($0) })
else { fail(3) }

let plaintext = Data(bytes: decrypted, count: strlen(decrypted))
freeString(decrypted)
guard !plaintext.isEmpty,
      let root = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
      let records = root["records"] as? [[String: Any]]
else { fail(4) }

let match = records.compactMap { record -> (Int64, String, String)? in
    guard let timestampMs = int64(record["timestampMs"]),
          timestampMs >= afterMs,
          timestampMs <= beforeMs,
          record["status"] as? String == "success",
          record["source"] as? String == "shell_embedded_voice_usage",
          record["triggerType"] as? String == "long_press",
          let id = record["id"] as? String
    else { return nil }
    let polished = (record["polishedText"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let original = (record["asrOriginalText"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let text = polished.isEmpty ? original : polished
    guard !text.isEmpty, text.count <= 8_000 else { return nil }
    return (timestampMs, id, text)
}.max { $0.0 < $1.0 }

guard let match,
      let output = try? JSONEncoder().encode(ReaderOutput(
          schemaVersion: schemaVersion,
          id: match.1,
          timestampMs: match.0,
          text: match.2
      ))
else { fail(5) }

FileHandle.standardOutput.write(output)
FileHandle.standardOutput.write(Data("\n".utf8))
fail(0)
