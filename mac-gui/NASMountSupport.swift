import Foundation

enum NASMountSupport {
    static func prepareAndTestPath(_ path: String) -> Bool {
        let destinationURL = URL(fileURLWithPath: path, isDirectory: true)
        let components = destinationURL.standardizedFileURL.pathComponents
        if let volumesIndex = components.firstIndex(of: "Volumes"), components.indices.contains(volumesIndex + 1) {
            let mountURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
                .appendingPathComponent(components[volumesIndex + 1], isDirectory: true)
            var isMountDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: mountURL.path, isDirectory: &isMountDirectory),
                  isMountDirectory.boolValue else { return false }
            if !FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let probeURL = destinationURL.appendingPathComponent(".jable-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probeURL, options: .atomic)
            try FileManager.default.removeItem(at: probeURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: probeURL)
            return false
        }
    }

    static func reconnectURL(serverURL: String, destinationPath: String) -> URL? {
        var value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.lowercased().hasPrefix("smb://") {
            value = "smb://" + value
        }
        guard var url = URL(string: value), url.scheme?.lowercased() == "smb" else { return nil }
        if url.path.isEmpty || url.path == "/" {
            let components = URL(fileURLWithPath: destinationPath).standardizedFileURL.pathComponents
            guard let volumesIndex = components.firstIndex(of: "Volumes"),
                  components.indices.contains(volumesIndex + 1) else { return nil }
            url.appendPathComponent(components[volumesIndex + 1])
        }
        return url
    }
}
