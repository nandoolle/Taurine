import Foundation
import TaurineShared

@main
enum HelperMain {
    // Kept alive for the process lifetime: NSXPCListener.delegate is weak.
    nonisolated(unsafe) private static var service: HelperService?
    nonisolated(unsafe) private static var listener: NSXPCListener?

    // dispatchMain() must run from a synchronous main: calling it from an async
    // main (a block on the main queue) traps in libdispatch.
    static func main() {
        let sleep = SleepControl()
        Task.detached {
            await Bootstrap.run(sleep: sleep)
            let service = HelperService(sleep: sleep)
            Task.detached { await BundleWatchdog.run(sleep: sleep, tracker: service.tracker, bundlePath: BundleWatchdog.bundlePath()) }
            let listener = NSXPCListener(machServiceName: HelperPaths.machService)
            listener.delegate = service
            listener.resume()
            Self.service = service
            Self.listener = listener
        }
        dispatchMain()
    }
}
