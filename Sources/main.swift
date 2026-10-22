import Foundation
import AppKit

#if CAMERA_CONTROL_PLUGIN
// Link a distinct helper executable. Copying the app's executable into the
// plugin shares its Mach-O UUIDs and can confuse macOS Local Network privacy.
let plugin=CameraPlugin()
plugin.start(arguments:CommandLine.arguments)
RunLoop.main.run()
#else
let args = CommandLine.arguments
func argument(after flag:String)->String? { guard let i=args.firstIndex(of:flag), args.indices.contains(i+1) else{return nil}; return args[i+1] }
func report(_ error:Error)->Never { fputs("\(error.localizedDescription)\n",stderr); exit(1) }

if let path=argument(after:"--finish-app-update") {
    exit(UpdateInstaller.finishUpdate(planAt:URL(fileURLWithPath:path)))
} else if args.contains("-port") {
    let plugin=CameraPlugin(); plugin.start(arguments:args); RunLoop.main.run()
} else if let address=argument(after:"--probe") {
    do {
        let snapshot=try CameraClient(address:address).read()
        let values=Dictionary(uniqueKeysWithValues:["wb","tint","shutter","ei","nd","fps","playback"].map { ($0,snapshot.description(for:$0)) })
        let data=try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]); print(String(decoding:data,as:UTF8.self))
    } catch { report(error) }
} else if let directory=argument(after:"--generate") {
    do { for profile in try Installer.export(ConfigStore.load(),to:URL(fileURLWithPath:directory)) { print(profile.path) } } catch { report(error) }
} else if args.contains("--install") {
    _=NSApplication.shared
    do { for profile in try Installer.install(ConfigStore.load()) { print(profile.path) }; RunLoop.current.run(until:Date().addingTimeInterval(1)) } catch { report(error) }
} else if let address=argument(after:"--verify-white-balance") {
    // Explicit diagnostic: reads original WB, steps once, checks readback, restores and verifies.
    do {
        let client=CameraClient(address:address), original=try client.read()
        guard let kelvin=original.number("WBCurrentKelvin") else { throw BuilderError.message("Camera has no white balance readback.") }
        let next=try original.steppedValue(parameter:"wb",ticks:kelvin >= 11000 ? -1:1)
        do {
            let changed=try client.set(["WBCurrentKelvin":next]); print("Changed readback: \(changed.description(for:"wb"))")
            guard changed.number("WBCurrentKelvin") == next else { throw BuilderError.message("White balance readback did not match the requested value.") }
        } catch {
            _=try? client.set(["WBCurrentKelvin":kelvin]); throw error
        }
        let restored=try client.set(["WBCurrentKelvin":kelvin])
        guard restored.number("WBCurrentKelvin") == kelvin else { throw BuilderError.message("Could not verify original white balance restoration.") }
        print("Restored readback: \(restored.description(for:"wb"))")
    } catch { report(error) }
} else {
    let app=NSApplication.shared; let delegate=BuilderDelegate(); app.delegate=delegate; app.setActivationPolicy(.regular); app.run()
}
#endif
