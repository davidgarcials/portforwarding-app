import Foundation

public protocol CredentialRefreshing {
    func refresh() async -> Bool
}

public final class KubectlCredentialRefresher: CredentialRefreshing {
    public init() {}

    public func refresh() async -> Bool {
        let kubectlPath = KubectlResolver.resolve()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: kubectlPath)
        proc.arguments = ["cluster-info"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { cont in
            proc.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus == 0)
            }

            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                cont.resume(returning: false)
            }
        }
    }
}
