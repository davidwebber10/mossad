import Foundation
import MossadCore

/// The entry of a worker process: no `AppController`, no `NSApplication`, no window, no Dock icon. It never returns.
enum WorkerEntry {
    static func run(_ identity: AppIdentity) -> Never {
        let arguments = CommandLine.arguments
        if let refusal = WorkerLaunch.refusal(identity, arguments: arguments) {
            FileHandle.standardError.write(Data((refusal + "\n").utf8))
            exit(WorkerLaunch.Exit.refused.rawValue)
        }
        #if DEBUG
        // `--probe`: what this process, and one child of it, see of the calendar permission. Only the status is
        // read: nothing asks. It touches no data folder.
        if arguments.contains("--probe") {
            print("calendar \(EventKitCalendarSource.permissionName) pid \(ProcessInfo.processInfo.processIdentifier)")
            fflush(stdout)
            if !arguments.contains("--probe-child"), let executable = Bundle.main.executableURL {
                let child = WorkerLaunch.process(executable: executable, profile: identity.profile, environment: ProcessInfo.processInfo.environment)
                child.arguments = (child.arguments ?? []) + ["--probe", "--probe-child"]
                child.standardOutput = FileHandle.standardOutput
                do {
                    try child.run()
                    child.waitUntilExit()
                } catch {
                    FileHandle.standardError.write(Data("Mossad: the probe's child did not start: \(error)\n".utf8))
                }
            }
            exit(WorkerLaunch.Exit.stopped.rawValue)
        }
        #endif
        FileHandle.standardError.write(Data("Mossad: no foreground app; the worker does not start.\n".utf8))
        exit(WorkerLaunch.Exit.noForeground.rawValue)
    }
}
