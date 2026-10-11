import Foundation
import Network
import NaturalLanguage
import Observation
import Security
import LyricsCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Keychain (SIR-11, LOS-10)

/// Keychain-backed `SecureStore`. Items are device-only and never synced or backed up.
struct KeychainSecureStore: SecureStore {
    private let service = "com.team9.lyricstranslator"

    func set(_ value: String, for key: SecretKey) throws {
        try delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func value(for key: SecretKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: SecretKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    struct KeychainError: Error { let status: OSStatus }
}

// MARK: - Network (ONRQ-11)

@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            Task { @MainActor in self.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "network.monitor"))
    }
}

// MARK: - Device capability (RQ-1, ONRQ-7)

struct DeviceCapability {
    let physicalMemoryGB: Double
    let freeDiskBytes: Int64

    /// llama.cpp needs 6 GB RAM or more (SSRD 4.2). Re-baseline after spike S1.
    static let onDeviceMinimumGB = 6.0

    var canRunOnDevice: Bool { physicalMemoryGB >= Self.onDeviceMinimumGB - 0.5 || FoundationModelsEngine.isSupported }

    var onDeviceUnavailableReason: String? {
        canRunOnDevice ? nil : "이 기기는 메모리가 부족해 온디바이스 번역을 쓸 수 없어요."
    }

    static var current: DeviceCapability {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return DeviceCapability(physicalMemoryGB: ram, freeDiskBytes: free)
    }
}

// MARK: - Language identification (RQ-15)

struct LanguageDetector {
    /// Returns a BCP-47 code when confidence ≥ 0.5, else nil (the song's majority language is used).
    func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (lang, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.5 else { return nil }
        return lang.rawValue
    }
}

// MARK: - Lyrics provider with offline demo content

/// LRCLIB, plus the bundled demo song so the prototype is usable offline and in review.
struct DemoAwareLyricsProvider: LyricsProvider {
    let remote: LyricsProvider = LRCLIBClient()
    let demo = StaticLyricsProvider(candidates: DemoContent.candidates)

    func search(_ query: String) async throws -> [LyricsCandidate] {
        let local = (try? await demo.search(query)) ?? []
        do {
            return local + (try await remote.search(query))
        } catch {
            if !local.isEmpty { return local }
            throw error
        }
    }

    func lyrics(for track: TrackKey) async throws -> LyricsCandidate? {
        if let hit = try await demo.lyrics(for: track) { return hit }
        if let exact = try await remote.lyrics(for: track) { return exact }
        let ranked = TrackMatcher.rank(try await remote.search("\(track.title) \(track.artist)"), for: track)
        return ranked.first
    }
}

// MARK: - Covers (RQ-6: ≤1024×1024, stored only on device)

enum CoverStore {
    static func save(_ data: Data, for songID: UUID) -> String? {
        let dir = AppModel.coversURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("\(songID.uuidString).jpg")
        let output = downscaled(data) ?? data
        do {
            try output.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return url.lastPathComponent
        } catch {
            return nil
        }
    }

    static func url(for path: String) -> URL {
        AppModel.coversURL.appendingPathComponent(path)
    }

    static func delete(_ path: String) {
        try? FileManager.default.removeItem(at: url(for: path))
    }

    private static func downscaled(_ data: Data) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let side = min(image.size.width, image.size.height)
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let target = CGSize(width: min(side, 1024), height: min(side, 1024))
        let renderer = UIGraphicsImageRenderer(size: target)
        let result = renderer.image { _ in
            guard let cg = image.cgImage?.cropping(to: crop.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))) else {
                image.draw(in: CGRect(origin: .zero, size: target))
                return
            }
            UIImage(cgImage: cg, scale: 1, orientation: image.imageOrientation).draw(in: CGRect(origin: .zero, size: target))
        }
        return result.jpegData(compressionQuality: 0.85)
        #else
        return nil
        #endif
    }
}

// MARK: - Storage meter (RQ-14)

enum StorageMeter {
    static func bytes(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total + ModelManager.modelBytes
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Haptics

enum Haptics {
    @MainActor
    static func light() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    @MainActor
    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
