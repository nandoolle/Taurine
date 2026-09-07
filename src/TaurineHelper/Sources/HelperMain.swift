import Foundation
import TaurineShared

@main
enum HelperMain {
    static func main() async {
        let sleep = SleepControl()
        let outcome = await Bootstrap.run(sleep: sleep, environment: .live)
        guard outcome == .serving else { exit(0) }
        let service = HelperService(sleep: sleep)
        let listener = NSXPCListener(machServiceName: HelperPaths.machService)
        // NSXPCListener.delegate é weak: sem isto o ARC pode liberar o service
        // antes do dispatchMain e o daemon rejeita toda conexão.
        listener.delegate = service
        listener.resume()
        withExtendedLifetime(service) { dispatchMain() }
    }
}
