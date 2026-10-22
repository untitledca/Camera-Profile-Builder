import AppKit
import SwiftUI

final class BuilderModel: ObservableObject {
    @Published var config = ConfigStore.empty()
    @Published var name = "A CAM"
    @Published var address = ""
    @Published var model = "ALEXA Mini LF"
    @Published var editingID = ""
    @Published var status = "Add a camera, test the connection, then build your profiles."
    @Published var cameraStatus: [String:String] = [:]
    @Published var values: [String:String] = [:]
    @Published var working = false
    @Published var showGang = false
    @Published var showUpdates = false
    @Published var gangDraftIDs: [String] = []
    @Published var error = ""
    let models = ["ALEXA Mini LF", "ALEXA Mini", "AMIRA", "ALEXA 35", "ALEXA 35 Xtreme", "ALEXA LF", "ALEXA SXT", "ALEXA 65"]
    init() { reload() }
    func reload() {
        do { config = try ConfigStore.load(); if let camera = config.cameras.first(where: { $0.id == config.selectedCameraID }) ?? config.cameras.first { select(camera) } }
        catch { self.error = "Your saved camera configuration could not be read: \(error.localizedDescription)" }
    }
    func refreshInstalledPlugin() {
        guard !working else { return }
        working=true
        DispatchQueue.global(qos:.utility).async {
            let result=Result { try Installer.refreshPluginIfNeeded() }
            DispatchQueue.main.async {
                self.working=false
                switch result {
                case .success(true): self.status="Camera Control updated. Your copied camera folders are ready to use."
                case .success(false): break
                case .failure(let error): self.error="Camera Control could not be updated: \(error.localizedDescription)"
                }
            }
        }
    }
    func select(_ camera: CameraConfig) {
        editingID=camera.id; name=camera.name; model=camera.model; address=camera.address; values=[:]
        config.selectedCameraID=camera.id
    }
    func newCamera() { editingID=""; name="\(String(UnicodeScalar(65+min(config.cameras.count,25))!)) CAM"; address=""; model="ALEXA Mini LF"; values=[:] }
    @discardableResult func saveCamera() -> Bool {
        do {
            let cleanName = name.trimmingCharacters(in:.whitespacesAndNewlines)
            let cleanAddress = address.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            guard !cleanName.isEmpty else { throw BuilderError.message("Enter a camera name.") }
            guard cleanName.count <= 40 else { throw BuilderError.message("Use a camera name of 40 characters or fewer.") }
            _ = try CameraClient.validateAddress(cleanAddress)
            guard !config.cameras.contains(where: { $0.id != editingID && $0.address == cleanAddress }) else { throw BuilderError.message("That camera address is already saved.") }
            let id = editingID.isEmpty ? UUID().uuidString : editingID
            let camera = CameraConfig(id:id,name:cleanName,model:model,address:cleanAddress)
            if let index = config.cameras.firstIndex(where: { $0.id == id }) { config.cameras[index]=camera } else { config.cameras.append(camera) }
            config.selectedCameraID=id; editingID=id; address=cleanAddress; name=cleanName
            try ConfigStore.save(config)
            status="Saved \(cleanName). Its IP can be changed here without rebuilding the dial actions."
            return true
        } catch { self.error=error.localizedDescription; return false }
    }
    func removeCamera() {
        guard !editingID.isEmpty else { return }
        config.cameras.removeAll { $0.id == editingID }; config.gangIDs.removeAll { $0 == editingID }
        if config.gangIDs.isEmpty { config.gangEnabled=false }
        config.selectedCameraID=config.cameras.first?.id ?? ""
        do { try ConfigStore.save(config); if let first=config.cameras.first { select(first) } else { newCamera() } }
        catch { self.error=error.localizedDescription }
    }
    func testCamera() {
        guard saveCamera() else { return }
        let camera = config.cameras.first { $0.id == editingID }!
        working=true; status="Reading \(camera.name) at \(camera.address)…"
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result { try CameraClient(address:camera.address).read() }
            DispatchQueue.main.async {
                self.working=false
                switch result {
                case .success(let snapshot):
                    self.cameraStatus[camera.id]="Connected"
                    if self.editingID == camera.id && self.address == camera.address {
                        self.values=Dictionary(uniqueKeysWithValues:["wb","playback","tint","shutter","ei","nd","fps"].map { ($0,snapshot.description(for:$0)) })
                    }
                    self.status="Connected to \(camera.name). Values below are read from the camera."
                case .failure(let error): self.cameraStatus[camera.id]="Offline"; if self.editingID == camera.id { self.values=[:] }; self.error=error.localizedDescription; self.status="\(camera.name) connection failed. Check the camera IP and network."
                }
            }
        }
    }
    func refreshCameras() {
        for camera in config.cameras {
            cameraStatus[camera.id]="Checking…"
            DispatchQueue.global(qos:.utility).async {
                let result=Result { try CameraClient(address:camera.address).read() }
                DispatchQueue.main.async { self.cameraStatus[camera.id] = (try? result.get()) != nil ? "Connected" : "Offline" }
            }
        }
    }
    func gangBinding(_ id:String) -> Binding<Bool> {
        Binding(get:{self.gangDraftIDs.contains(id)},set:{ checked in
            if checked { if !self.gangDraftIDs.contains(id) { self.gangDraftIDs.append(id) } }
            else { self.gangDraftIDs.removeAll { $0 == id } }
        })
    }
    func beginGang() { gangDraftIDs=config.gangIDs; showGang=true; refreshCameras() }
    func applyGang(_ enabled:Bool) {
        guard !enabled || !gangDraftIDs.isEmpty else { error="Check at least one camera to enable gang control."; return }
        config.gangIDs=gangDraftIDs; config.gangEnabled=enabled; config.gangMode="absolute"
        do { try ConfigStore.save(config); status=enabled ? "Gang is ON. Every profile controls the checked cameras at the same value." : "Gang is OFF. Each camera profile controls its own camera."; showGang=false }
        catch { self.error=error.localizedDescription }
    }
    func install() {
        guard saveCamera() else { return }
        working=true; status="Building profiles and installing the camera plugin…"
        let copy=config
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result { try Installer.install(copy) }
            DispatchQueue.main.async {
                self.working=false
                switch result {
                case .success(let urls):
                    let selected=copy.cameras.first(where:{$0.id == copy.selectedCameraID}) ?? copy.cameras.first
                    self.status="Installed \(urls.count) profiles. ‘\(selected?.name ?? "Camera Setup") • Camera’ is active in Stream Deck."
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                case .failure(let error): self.error=error.localizedDescription; self.status="Installation did not finish. Your existing profiles are backed up."
                }
            }
        }
    }
    func export() {
        guard saveCamera() else { return }
        let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.canCreateDirectories=true; panel.prompt="Export Here"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do { let profiles=try Installer.export(config,to:url); status="Exported \(profiles.count) profiles. Install the Camera Control plugin before importing them on another Mac."; NSWorkspace.shared.activateFileViewerSelecting(profiles) }
        catch { self.error=error.localizedDescription }
    }
}

@MainActor
struct BuilderView: View {
    @ObservedObject var data: BuilderModel
    @StateObject private var updates=AppUpdater()
    private let accent=Color(red:0.30,green:0.86,blue:0.77)
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:14) {
                Image(systemName:"camera.aperture").font(.system(size:34)).foregroundStyle(accent)
                VStack(alignment:.leading,spacing:4) {
                    Text("Camera Profile Builder").font(.system(size:24,weight:.semibold))
                    Text("ARRI camera control for Stream Deck +").foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment:.trailing,spacing:6) {
                    Text(updates.currentVersion).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
                    Button("Updates…") { data.showUpdates=true }
                }
            }.padding(24)
            Divider()
            HStack(alignment:.top,spacing:0) {
                VStack(alignment:.leading,spacing:14) {
                    HStack { Text("CAMERAS").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button(action:data.newCamera) { Image(systemName:"plus") }.help("Add another camera") }
                    ScrollView {
                        VStack(spacing:8) {
                            ForEach(data.config.cameras) { camera in
                                Button { data.select(camera) } label: {
                                    HStack {
                                        Image(systemName:"video.fill").foregroundStyle(accent)
                                        VStack(alignment:.leading,spacing:4) { Text(camera.name).fontWeight(.semibold); Text(camera.address).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary) }
                                        Spacer()
                                    }.padding(12).background(data.editingID == camera.id ? accent.opacity(0.14) : .white.opacity(0.03)).cornerRadius(8)
                                }.buttonStyle(.plain)
                            }
                            if data.config.cameras.isEmpty { Text("Your saved cameras\nappear here.").font(.callout).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical) }
                        }
                    }
                    Button(action:data.beginGang) { Label(data.config.gangEnabled ? "Gang is ON" : "Gang Cameras",systemImage:"link") }.controlSize(.large)
                    Text("Choose the IP addresses that one knob should control together.").font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(width:220)
                Divider()
                VStack(alignment:.leading,spacing:18) {
                    Text(data.editingID.isEmpty ? "Add a camera" : "Camera setup").font(.title2.weight(.semibold))
                    Text("Build one camera folder, then copy and paste it into your other Stream Deck + profiles.").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment:.top,spacing:18) {
                        VStack(alignment:.leading,spacing:6) { Text("Profile name").font(.caption).foregroundStyle(.secondary); TextField("A CAM",text:$data.name) }
                        VStack(alignment:.leading,spacing:6) { Text("Camera type").font(.caption).foregroundStyle(.secondary); Picker("Camera type",selection:$data.model) { ForEach(data.models,id:\.self) { Text("ARRI \($0)").tag($0) } }.labelsHidden() }
                    }
                    VStack(alignment:.leading,spacing:6) { Text("Camera IP address").font(.caption).foregroundStyle(.secondary); TextField("10.10.1.41",text:$data.address).font(.system(.body,design:.monospaced)); Text("Uses the camera’s Web Remote. Available settings are read from each camera.").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Test Connection",action:data.testCamera).disabled(data.working)
                        Button("Save Camera") { data.saveCamera() }.disabled(data.working)
                        Spacer()
                        if !data.editingID.isEmpty { Button("Remove",action:data.removeCamera).foregroundStyle(.secondary).disabled(data.working) }
                    }
                    Divider()
                    Text("YOUR DIALS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing:10) { dial("wb","White balance","sun.max","100 K per step"); dial("playback","Playback","playpause","Speed / play / pause"); dial("tint","CC tint","slider.horizontal.3","0.5 per step"); dial("shutter","Shutter","camera.aperture","0.1° per step") }
                    HStack(spacing:10) { dial("ei","Exposure index","plusminus.circle","Camera EI choices"); dial("nd","ND filter","circle.lefthalf.filled","Camera ND choices"); dial("fps","Sensor FPS","film","1 fps per step") }
                    Text("The touch strip shows camera readback. Mixed gang values and lost connections are shown explicitly. Press a dial to reset; press playback to play or pause.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:0)
                }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:.infinity)
            Divider()
            HStack(spacing:16) {
                if data.working { ProgressView().controlSize(.small) }
                VStack(alignment:.leading,spacing:4) {
                    Text(data.status).font(.callout).fixedSize(horizontal:false,vertical:true)
                    Text("Installation restarts Stream Deck and backs up your existing profiles.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength:10)
                Button("Export…",action:data.export).disabled(data.working)
                Button("Build & Install",action:data.install).buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black).controlSize(.large).disabled(data.working)
            }.padding(20)
        }.background(Color(red:0.065,green:0.085,blue:0.11)).preferredColorScheme(.dark)
        .textFieldStyle(.roundedBorder)
        .sheet(isPresented:$data.showGang) { gangSheet }
        .sheet(isPresented:$data.showUpdates,onDismiss:{ updates.completeRelaunch() }) { updateSheet }
        .onChange(of:updates.relaunchReady) { ready in
            guard ready else { return }
            if data.showUpdates { data.showUpdates=false }
            else { updates.completeRelaunch() }
        }
        .onAppear { updates.checkOnLaunch() }
        .alert("Camera Profile Builder",isPresented:Binding(get:{!data.error.isEmpty},set:{if !$0 {data.error=""}})) { Button("OK"){data.error=""} } message:{Text(data.error)}
    }
    private func dial(_ key:String,_ name:String,_ symbol:String,_ hint:String)->some View {
        VStack(alignment:.leading,spacing:8) {
            Image(systemName:symbol).font(.title3).foregroundStyle(accent)
            Text(name).font(.caption.weight(.semibold))
            Text(data.values[key] ?? "—").font(.system(size:18,weight:.medium,design:.monospaced)).lineLimit(1).minimumScaleFactor(0.6)
            Text(hint).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.045)).cornerRadius(10)
    }
    private var updateSheet: some View {
        VStack(alignment:.leading,spacing:18) {
            Label("Camera Profile Builder Updates",systemImage:"arrow.down.circle").font(.title2.weight(.semibold))
            Text("Installed version: \(updates.currentVersion)").foregroundStyle(.secondary)
            Toggle("Automatically check for updates",isOn:$updates.automaticChecks)
            Text(updates.status).fixedSize(horizontal:false,vertical:true)
            if !updates.error.isEmpty { Text(updates.error).foregroundStyle(.red).font(.callout).fixedSize(horizontal:false,vertical:true) }
            if let release=updates.availableRelease {
                Text("Version \(release.version.description) is available.").fontWeight(.semibold)
                Link("Read release notes on GitHub",destination:release.pageURL)
                Text("Install downloads the signed update, replaces the app, and relaunches it. Camera settings and copied Stream Deck folders are preserved.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            HStack {
                Button("Check Now") { updates.checkForUpdates(manual:true) }.disabled(updates.checking || updates.installing)
                if updates.checking || updates.installing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { data.showUpdates=false }.disabled(updates.installing)
                if updates.availableRelease != nil { Button("Install & Relaunch") { updates.installAvailableUpdate() }.buttonStyle(.borderedProminent).disabled(updates.installing || data.working) }
            }
        }.padding(26).frame(width:530).preferredColorScheme(.dark)
        .onAppear { updates.checkForUpdates(manual:true) }
    }
    private var gangSheet: some View {
        VStack(alignment:.leading,spacing:18) {
            Label("Gang Cameras",systemImage:"link").font(.title2.weight(.semibold))
            Text("Check the cameras to control together. Turning a knob sets all checked cameras to the same setting, based on the first checked camera in this list.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    ForEach(data.config.cameras) { camera in
                        Toggle(isOn:data.gangBinding(camera.id)) {
                            HStack { VStack(alignment:.leading,spacing:4) { Text(camera.name).fontWeight(.semibold); Text("\(camera.model) · \(camera.address)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(data.cameraStatus[camera.id] ?? "Not checked").font(.caption).foregroundStyle(data.cameraStatus[camera.id] == "Connected" ? Color.green : Color.secondary) }
                        }
                    }
                }.padding(4)
            }.frame(minHeight:100,maxHeight:260)
            Text("Gang ON applies to every generated camera profile. The GANG profile always targets the checked cameras. An offline camera reports a failure; other cameras may still change.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Refresh",action:data.refreshCameras); Spacer(); Button("Turn Gang Off"){data.applyGang(false)}; Button("Enable Gang"){data.applyGang(true)}.buttonStyle(.borderedProminent).disabled(data.gangDraftIDs.isEmpty) }
            Button("Cancel"){data.showGang=false}.keyboardShortcut(.cancelAction)
        }.padding(26).frame(width:530).preferredColorScheme(.dark)
    }
}

final class BuilderDelegate: NSObject, NSApplicationDelegate {
    var window:NSWindow!
    var data:BuilderModel!
    private var pendingURL:String?
    func applicationWillFinishLaunching(_ notification:Notification) {
        NSAppleEventManager.shared().setEventHandler(self,andSelector:#selector(openURL(_:reply:)),forEventClass:AEEventClass(kInternetEventClass),andEventID:AEEventID(kAEGetURL))
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        data=BuilderModel()
        let root=BuilderView(data:data)
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1050,height:790),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Camera Profile Builder"; window.contentMinSize=NSSize(width:960,height:760)
        let host=NSHostingView(rootView:root)
        host.sizingOptions=[]
        host.frame=NSRect(x:0,y:0,width:1050,height:790)
        host.autoresizingMask=[.width,.height]
        window.contentView=host
        window.setContentSize(NSSize(width:1050,height:790))
        window.center(); window.makeKeyAndOrderFront(nil)
        let menu=NSMenu(); let appItem=NSMenuItem(); let appMenu=NSMenu(); appMenu.addItem(withTitle:"About Camera Profile Builder",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:""); appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Quit Camera Profile Builder",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); appItem.submenu=appMenu; menu.addItem(appItem)
        let editItem=NSMenuItem(); let edit=NSMenu(title:"Edit"); for (title,key,selector) in [("Cut","x",#selector(NSText.cut(_:))),("Copy","c",#selector(NSText.copy(_:))),("Paste","v",#selector(NSText.paste(_:))),("Select All","a",#selector(NSText.selectAll(_:)))] { edit.addItem(withTitle:title,action:selector,keyEquivalent:key) }; editItem.submenu=edit; menu.addItem(editItem); NSApp.mainMenu=menu
        NSApp.activate(ignoringOtherApps:true)
        data.refreshInstalledPlugin()
        if CommandLine.arguments.contains("--gang") || pendingURL?.contains("gang") == true { data.beginGang() }
    }
    @objc func openURL(_ event:NSAppleEventDescriptor, reply:NSAppleEventDescriptor) {
        let url=event.paramDescriptor(forKeyword:keyDirectObject)?.stringValue ?? ""
        guard data != nil else { pendingURL=url; return }
        data.reload(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if url.contains("gang") { data.beginGang() }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { window.makeKeyAndOrderFront(nil); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
