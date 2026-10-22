#!/usr/bin/env python3
"""Build a dependency-free universal macOS app, native plugin, and DMG."""
import argparse, hashlib, json, pathlib, plistlib, re, shutil, subprocess
ROOT=pathlib.Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--package-only',action='store_true')
parser.add_argument('--sign-updates',action='store_true',help='Sign checksums using the maintainer Keychain key')
args=parser.parse_args()
VERSION=(ROOT/'VERSION').read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+',VERSION): raise SystemExit('VERSION must contain a stable major.minor.patch version')
parts=list(map(int,VERSION.split('.')))
BUILD_NUMBER=str(parts[0]*10000+parts[1]*100+parts[2])
BUILD=ROOT/'build'; DIST=ROOT/'dist'; BUILD.mkdir(exist_ok=True); DIST.mkdir(exist_ok=True)
def run(*args): subprocess.run([str(a) for a in args],check=True,cwd=ROOT)
def macho_uuids(binary):
    output=subprocess.check_output(['/usr/bin/dwarfdump','--uuid',str(binary)],text=True,cwd=ROOT)
    identifiers={arch:identifier.upper() for identifier,arch in re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)',output)}
    if set(identifiers) != {'arm64','x86_64'}:
        raise SystemExit(f'{binary.name} must contain UUIDs for both arm64 and x86_64')
    return identifiers
APP=BUILD/'Camera Profile Builder.app'; CONTENTS=APP/'Contents'; RES=CONTENTS/'Resources'; MAC=CONTENTS/'MacOS'
PLUGIN_BINARY=BUILD/'CameraControlPlugin'
RES.mkdir(parents=True,exist_ok=True); MAC.mkdir(exist_ok=True)
SNAPSHOT=BUILD/'sources'
if SNAPSHOT.exists(): shutil.rmtree(SNAPSHOT)
SNAPSHOT.mkdir()
for source in (ROOT/'Sources').glob('*.swift'): shutil.copy(source,SNAPSHOT/source.name)
sources=sorted(SNAPSHOT.glob('*.swift'))
if not args.package_only:
    for arch in ['arm64','x86_64']:
        run('/usr/bin/swiftc','-swift-version','5','-O','-target',f'{arch}-apple-macos13.0',*sources,'-o',BUILD/f'CameraBuilder-{arch}')
        run('/usr/bin/swiftc','-swift-version','5','-O','-target',f'{arch}-apple-macos13.0','-D','CAMERA_CONTROL_PLUGIN',*sources,'-o',BUILD/f'CameraPlugin-{arch}')
    run('/usr/bin/lipo','-create',BUILD/'CameraBuilder-arm64',BUILD/'CameraBuilder-x86_64','-output',MAC/'CameraProfileBuilder')
    run('/usr/bin/lipo','-create',BUILD/'CameraPlugin-arm64',BUILD/'CameraPlugin-x86_64','-output',PLUGIN_BINARY)
if not PLUGIN_BINARY.is_file():
    raise SystemExit('The separately linked plugin is missing. Run a full build without --package-only.')
app_uuids=macho_uuids(MAC/'CameraProfileBuilder')
plugin_uuids=macho_uuids(PLUGIN_BINARY)
for arch in ['arm64','x86_64']:
    if app_uuids[arch] == plugin_uuids[arch]:
        raise SystemExit(f'The app and plugin share the {arch} Mach-O UUID. Rebuild the plugin separately.')
print('Verified distinct app and plugin Mach-O UUIDs for arm64 and x86_64.')
info={'CFBundleDevelopmentRegion':'en','CFBundleDisplayName':'Camera Profile Builder','CFBundleExecutable':'CameraProfileBuilder','CFBundleIdentifier':'com.atomfilmlab.camera-profile-builder','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'Camera Profile Builder','CFBundlePackageType':'APPL','CFBundleShortVersionString':VERSION,'CFBundleVersion':BUILD_NUMBER,'LSApplicationCategoryType':'public.app-category.video','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'CFBundleIconFile':'AppIcon','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},'CFBundleURLTypes':[{'CFBundleURLName':'Camera Builder','CFBundleURLSchemes':['cameraprofilebuilder']}],'NSLocalNetworkUsageDescription':'Connect to your ARRI cameras to read settings and control them from Stream Deck.'}
(CONTENTS/'Info.plist').write_bytes(plistlib.dumps(info))
run('/usr/bin/swift',ROOT/'scripts/make_icon.swift',BUILD/'icon-png')
ICONSET=BUILD/'AppIcon.iconset'; ICONSET.mkdir(exist_ok=True)
for size in [16,32,128,256,512]:
    shutil.copy(BUILD/'icon-png'/f'{size}.png',ICONSET/f'icon_{size}x{size}.png')
    shutil.copy(BUILD/'icon-png'/f'{size*2}.png',ICONSET/f'icon_{size}x{size}@2x.png')
run('/usr/bin/iconutil','-c','icns',ICONSET,'-o',RES/'AppIcon.icns')
PLUGIN=RES/'com.atomfilmlab.camera-control.sdPlugin'; (PLUGIN/'Images').mkdir(parents=True,exist_ok=True); (PLUGIN/'layouts').mkdir(exist_ok=True)
shutil.copy(PLUGIN_BINARY,PLUGIN/'CameraControlPlugin'); (PLUGIN/'CameraControlPlugin').chmod(0o755)
for image in (ROOT/'assets/reference-icons').glob('*.png'): shutil.copy(image,PLUGIN/'Images'/image.name)
run('/usr/bin/swift',ROOT/'scripts/make_plugin_icons.swift',PLUGIN/'Images')
manifest={'$schema':'https://schemas.elgato.com/streamdeck/plugins/manifest.json','Actions':[{'UUID':'com.atomfilmlab.camera-control.dial','Name':'Camera Setting','Icon':'Images/dial','Controllers':['Encoder'],'States':[{'Image':'Images/wb','ShowTitle':False}],'Encoder':{'layout':'layouts/camera.json','TriggerDescription':{'Rotate':'Adjust camera setting','Push':'Reset setting / play or pause','Touch':'Reset setting / play or pause'}}},{'UUID':'com.atomfilmlab.camera-control.button','Name':'Camera Button','Icon':'Images/button','Controllers':['Keypad'],'States':[{'Image':'Images/settings'}],'Tooltip':'Camera command or camera/gang setup'}],'Author':'Atom Film Lab','Category':'Camera Control','CategoryIcon':'Images/category','CodePath':'CameraControlPlugin','CodePathMac':'CameraControlPlugin','Description':'ARRI camera controls with live readback and multi-camera ganging. Configure cameras in Camera Profile Builder.','Icon':'Images/plugin','Name':'Camera Control','OS':[{'Platform':'mac','MinimumVersion':'13.0'}],'PropertyInspectorPath':'inspector.html','SDKVersion':2,'Software':{'MinimumVersion':'6.6'},'UUID':'com.atomfilmlab.camera-control','Version':'2.0.0.0'}
manifest['Version']=VERSION+'.0'
(PLUGIN/'manifest.json').write_text(json.dumps(manifest,indent=2))
layout={'$schema':'https://schemas.elgato.com/streamdeck/plugins/layout.json','id':'camera-feedback','items':[{'key':'title','type':'text','rect':[8,3,184,18],'font':{'size':12,'weight':600},'alignment':'left'},{'key':'icon','type':'pixmap','rect':[8,28,34,34]},{'key':'value','type':'text','rect':[47,23,145,37],'font':{'size':27,'weight':700},'alignment':'right'},{'key':'target','type':'text','rect':[8,64,184,15],'font':{'size':11,'weight':600},'alignment':'left'},{'key':'hint','type':'text','rect':[8,82,184,14],'font':{'size':9},'alignment':'left'}]}
(PLUGIN/'layouts/camera.json').write_text(json.dumps(layout,indent=2))
shutil.copy(ROOT/'assets/inspector.html',PLUGIN/'inspector.html')
run('/usr/bin/codesign','--force','--sign','-','--identifier','com.atomfilmlab.camera-control',PLUGIN/'CameraControlPlugin')
run('/usr/bin/codesign','--verify','--strict','--all-architectures',PLUGIN/'CameraControlPlugin')
run('/usr/bin/codesign','--force','--deep','--sign','-',APP)
run('/usr/bin/codesign','--verify','--deep','--strict',APP)
STAGE=BUILD/'dmg'; STAGE.mkdir(exist_ok=True)
target=STAGE/APP.name
if target.exists(): shutil.rmtree(target)
shutil.copytree(APP,target)
if not (STAGE/'Applications').exists(): (STAGE/'Applications').symlink_to('/Applications')
shutil.copy(ROOT/'README.md',STAGE/'Read Me.txt')
shutil.copy(RES/'AppIcon.icns',STAGE/'.VolumeIcon.icns')
run('/usr/bin/swift',ROOT/'scripts/set_icon.swift',BUILD/'icon-png/512.png',STAGE)
DMG=DIST/f'Camera_Profile_Builder_{VERSION}.dmg'
if DMG.exists(): DMG.unlink()
run('/usr/bin/hdiutil','create','-volname','Camera Profile Builder','-srcfolder',STAGE,'-ov','-format','UDZO',DMG)
run('/usr/bin/swift',ROOT/'scripts/set_icon.swift',BUILD/'icon-png/512.png',DMG)
shutil.rmtree(STAGE)
ZIP=DIST/f'Camera_Profile_Builder_{VERSION}.zip'
if ZIP.exists(): ZIP.unlink()
run('/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',APP,ZIP)
SUMS=DIST/'SHA256SUMS.txt'
SUMS.write_text(''.join(f'{hashlib.sha256(asset.read_bytes()).hexdigest()}  {asset.name}\n' for asset in [DMG,ZIP]))
if args.sign_updates:
    run('/usr/bin/swift',ROOT/'scripts/update_signing.swift','sign',SUMS)
    key=re.search(r'base64\s*=\s*"([^"]+)"',(ROOT/'Sources/UpdatePublicKey.swift').read_text())
    if not key: raise SystemExit('Embedded update public key is missing')
    run('/usr/bin/swift',ROOT/'scripts/update_signing.swift','verify',SUMS,str(SUMS)+'.sig',key.group(1))
elif (DIST/'SHA256SUMS.txt.sig').exists():
    (DIST/'SHA256SUMS.txt.sig').unlink()
print(DMG)
print(ZIP)
