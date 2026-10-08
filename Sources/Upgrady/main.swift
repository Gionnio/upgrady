import Foundation

if CommandLine.arguments.contains("--scan") {
    let done = DispatchSemaphore(value: 0)
    Task {
        await ScanCommand.run()
        done.signal()
    }
    done.wait()
    exit(0)
}

UpgradyApp.main()
