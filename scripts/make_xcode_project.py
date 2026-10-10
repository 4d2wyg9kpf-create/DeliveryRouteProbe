"""Generate a standalone Xcode iOS app from the same Swift sources, without dependencies."""
from pathlib import Path
import hashlib, json, plistlib
from xml.sax.saxutils import escape
ROOT=Path(__file__).resolve().parent.parent
PROJECT=ROOT/'DeliveryRouteProbe.xcodeproj'
PROJECT.mkdir(exist_ok=True)
def uid(name):return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def q(value):return json.dumps(value,ensure_ascii=False)
files=sorted((ROOT/'DeliveryRouteProbe.swiftpm').glob('*.swift'))
files=[f for f in files if f.name!='Package.swift']
objects=[]
def add(name,body):objects.append(f'{uid(name)} = {{ {body} }};')
for f in files:
    add('ref:'+f.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(str(f.relative_to(ROOT)))}; sourceTree = "<group>";')
    add('build:'+f.name, f'isa = PBXBuildFile; fileRef = {uid("ref:"+f.name)};')
add('ref:Assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = DeliveryRouteProbe.swiftpm/Assets.xcassets; sourceTree = "<group>";')
add('build:Assets', f'isa = PBXBuildFile; fileRef = {uid("ref:Assets")};')
add('product','isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = DeliveryRouteProbe.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('main', 'isa = PBXGroup; children = ('+','.join(uid('ref:'+f.name) for f in files)+','+uid('ref:Assets')+','+uid('products')+'); sourceTree = "<group>";')
add('products', f'isa = PBXGroup; children = ({uid("product")}); name = Products; sourceTree = "<group>";')
add('sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(uid('build:'+f.name) for f in files)+'); runOnlyForDeploymentPostprocessing = 0;')
add('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
add('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid("build:Assets")}); runOnlyForDeploymentPostprocessing = 0;')
for level in ['project','target']:
    for config in ['Debug','Release']:
        settings={'IPHONEOS_DEPLOYMENT_TARGET':'18.0','SDKROOT':'iphoneos'}
        if level=='project':settings.update({'CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES'})
        else:
            settings.update({'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'kr.deliverytools.routeprobe','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'minimal','TARGETED_DEVICE_FAMILY':'1,2','INFOPLIST_FILE':'native/Info.plist','GENERATE_INFOPLIST_FILE':'NO','CODE_SIGN_STYLE':'Automatic','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','MARKETING_VERSION':'0.15.1','CURRENT_PROJECT_VERSION':'29','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'})
            if config=='Debug':settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG'})
            else:settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-O','SWIFT_COMPILATION_MODE':'wholemodule','DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym'})
        add(level+config, 'isa = XCBuildConfiguration; buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+f'}}; name = {config};')
    add(level+'Config', 'isa = XCConfigurationList; buildConfigurations = ('+','.join(uid(level+c) for c in ['Debug','Release'])+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('target',f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetConfig")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")}); buildRules = (); dependencies = (); name = DeliveryRouteProbe; productName = DeliveryRouteProbe; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
add('project',f'isa = PBXProject; attributes = {{ LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; }}; buildConfigurationList = {uid("projectConfig")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ko; hasScannedForEncodings = 0; knownRegions = (ko,en,Base); mainGroup = {uid("main")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")});')
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+uid('project')+'; }\n')
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="DeliveryRouteProbe.app" BlueprintName="DeliveryRouteProbe" ReferencedContainer="container:DeliveryRouteProbe.xcodeproj"/>'
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
sdir=PROJECT/'xcshareddata/xcschemes';sdir.mkdir(parents=True,exist_ok=True)
(sdir/'DeliveryRouteProbe.xcscheme').write_text(scheme)
info={'CFBundleDevelopmentRegion':'ko','CFBundleDisplayName':'DeliveryRoute','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'DeliveryRoute','CFBundlePackageType':'APPL','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','LSRequiresIPhoneOS':True,'UIFileSharingEnabled':True,'LSSupportsOpeningDocumentsInPlace':True,'UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':True},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'UISupportedInterfaceOrientations~ipad':['UIInterfaceOrientationPortrait','UIInterfaceOrientationPortraitUpsideDown','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']}
(ROOT/'native').mkdir(exist_ok=True);(ROOT/'native/Info.plist').write_bytes(plistlib.dumps(info,sort_keys=False))
print(f'Generated standalone project: {len(files)} Swift sources')
