#!/usr/bin/env python3
"""Generate ios/SpotifyDisplay.xcodeproj/project.pbxproj for SpotifyDisplay iOS app."""
import os
import uuid

def uid():
    return uuid.uuid4().hex[:24].upper()

PROJECT = uid()
TARGET = uid()
MAIN_GROUP = uid()
PRODUCTS_GROUP = uid()
SOURCES_PHASE = uid()
FRAMEWORKS_PHASE = uid()
RESOURCES_PHASE = uid()
APP_REF = uid()
SPOTIFY_GROUP = uid()
PROJECT_CONF_LIST = uid()
TARGET_CONF_LIST = uid()
PROJ_DEBUG = uid()
PROJ_REL = uid()
TGT_DEBUG = uid()
TGT_REL = uid()

swift_files = [
    "AppDelegate.swift",
    "BLEManager.swift",
    "ContentView.swift",
    "Extensions.swift",
    "ImageProcessor.swift",
    "KeychainHelper.swift",
    "Models.swift",
    "SpotifyAuthPresenter.swift",
    "SpotifyDisplayApp.swift",
    "SpotifyManager.swift",
]

file_refs = {}
build_files = {}
for name in swift_files:
    file_refs[name] = uid()
    build_files[name] = uid()

lines = []

def p(s=""):
    lines.append(s)

p("// !$*UTF8*$!")
p("{")
p("\tarchiveVersion = 1;")
p("\tclasses = {")
p("\t};")
p("\tobjectVersion = 56;")
p("\tobjects = {")

p("/* Begin PBXBuildFile section */")
for name in swift_files:
    p(f"\t\t{build_files[name]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[name]} /* {name} */; }};")
p("/* End PBXBuildFile section */")
p("")

p("/* Begin PBXFileReference section */")
p(f"\t\t{APP_REF} /* SpotifyDisplay.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SpotifyDisplay.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
for name in swift_files:
    p(f"\t\t{file_refs[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};")
p("/* End PBXFileReference section */")
p("")

p("/* Begin PBXFrameworksBuildPhase section */")
p(f"\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{")
p("\t\t\tisa = PBXFrameworksBuildPhase;")
p("\t\t\tbuildActionMask = 2147483647;")
p("\t\t\tfiles = (")
p("\t\t\t);")
p("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
p("\t\t};")
p("/* End PBXFrameworksBuildPhase section */")
p("")

p("/* Begin PBXGroup section */")
ch_sp = ", ".join([f"{file_refs[n]} /* {n} */" for n in swift_files])
p(f"\t\t{SPOTIFY_GROUP} /* SpotifyDisplay */ = {{")
p("\t\t\tisa = PBXGroup;")
p(f"\t\t\tchildren = ({ch_sp});")
p("\t\t\tname = SpotifyDisplay;")
p('\t\t\tpath = "../SpotifyDisplay.swiftpm/Sources/SpotifyDisplay";')
p('\t\t\tsourceTree = "<group>";')
p("\t\t};")
p(f"\t\t{PRODUCTS_GROUP} /* Products */ = {{")
p("\t\t\tisa = PBXGroup;")
p(f"\t\t\tchildren = ({APP_REF} /* SpotifyDisplay.app */);")
p("\t\t\tname = Products;")
p('\t\t\tsourceTree = "<group>";')
p("\t\t};")
p(f"\t\t{MAIN_GROUP} = {{")
p("\t\t\tisa = PBXGroup;")
p(f"\t\t\tchildren = ({SPOTIFY_GROUP} /* SpotifyDisplay */, {PRODUCTS_GROUP} /* Products */);")
p('\t\t\tsourceTree = "<group>";')
p("\t\t};")
p("/* End PBXGroup section */")
p("")

p("/* Begin PBXNativeTarget section */")
p(f"\t\t{TARGET} /* SpotifyDisplay */ = {{")
p("\t\t\tisa = PBXNativeTarget;")
p(f"\t\t\tbuildConfigurationList = {TARGET_CONF_LIST} /* Build configuration list for PBXNativeTarget \"SpotifyDisplay\" */;")
p("\t\t\tbuildPhases = (")
p(f"\t\t\t\t{SOURCES_PHASE} /* Sources */,")
p(f"\t\t\t\t{FRAMEWORKS_PHASE} /* Frameworks */,")
p(f"\t\t\t\t{RESOURCES_PHASE} /* Resources */,")
p("\t\t\t);")
p("\t\t\tbuildRules = (")
p("\t\t\t);")
p("\t\t\tdependencies = (")
p("\t\t\t);")
p("\t\t\tname = SpotifyDisplay;")
p("\t\t\tproductName = SpotifyDisplay;")
p(f"\t\t\tproductReference = {APP_REF} /* SpotifyDisplay.app */;")
p("\t\t\tproductType = \"com.apple.product-type.application\";")
p("\t\t};")
p("/* End PBXNativeTarget section */")
p("")

p("/* Begin PBXProject section */")
p(f"\t\t{PROJECT} /* Project object */ = {{")
p("\t\t\tisa = PBXProject;")
p("\t\t\tattributes = {")
p("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
p("\t\t\t\tLastSwiftUpdateCheck = 1500;")
p("\t\t\t\tLastUpgradeCheck = 1500;")
p("\t\t\t\tTargetAttributes = {")
p(f"\t\t\t\t\t{TARGET} = {{")
p("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
p("\t\t\t\t\t};")
p("\t\t\t\t};")
p("\t\t\t};")
p(f"\t\t\tbuildConfigurationList = {PROJECT_CONF_LIST} /* Build configuration list for PBXProject \"SpotifyDisplay\" */;")
p('\t\t\tcompatibilityVersion = "Xcode 14.0";')
p("\t\t\tdevelopmentRegion = en;")
p("\t\t\thasScannedForEncodings = 0;")
p("\t\t\tknownRegions = (")
p("\t\t\t\ten,")
p("\t\t\t\tBase,")
p("\t\t\t);")
p(f"\t\t\tmainGroup = {MAIN_GROUP};")
p(f"\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;")
p('\t\t\tprojectDirPath = "";')
p('\t\t\tprojectRoot = "";')
p("\t\t\ttargets = (")
p(f"\t\t\t\t{TARGET} /* SpotifyDisplay */,")
p("\t\t\t);")
p("\t\t};")
p("/* End PBXProject section */")
p("")

p("/* Begin PBXResourcesBuildPhase section */")
p(f"\t\t{RESOURCES_PHASE} /* Resources */ = {{")
p("\t\t\tisa = PBXResourcesBuildPhase;")
p("\t\t\tbuildActionMask = 2147483647;")
p("\t\t\tfiles = (")
p("\t\t\t);")
p("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
p("\t\t};")
p("/* End PBXResourcesBuildPhase section */")
p("")

p("/* Begin PBXSourcesBuildPhase section */")
p(f"\t\t{SOURCES_PHASE} /* Sources */ = {{")
p("\t\t\tisa = PBXSourcesBuildPhase;")
p("\t\t\tbuildActionMask = 2147483647;")
p("\t\t\tfiles = (")
for name in swift_files:
    p(f"\t\t\t\t{build_files[name]} /* {name} in Sources */,")
p("\t\t\t);")
p("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
p("\t\t};")
p("/* End PBXSourcesBuildPhase section */")
p("")

INFOPLIST_PATH = "../SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/Resources/Info.plist"

common_target_lines = [
    "CODE_SIGN_STYLE = Automatic;",
    "CURRENT_PROJECT_VERSION = 1;",
    'DEVELOPMENT_TEAM = "";',
    "ENABLE_PREVIEWS = YES;",
    "GENERATE_INFOPLIST_FILE = NO;",
    f'INFOPLIST_FILE = "{INFOPLIST_PATH}";',
    "IPHONEOS_DEPLOYMENT_TARGET = 16.0;",
    "MARKETING_VERSION = 1.0;",
    "PRODUCT_BUNDLE_IDENTIFIER = com.example.spotifydisplay;",
    'PRODUCT_NAME = "$(TARGET_NAME)";',
    "SWIFT_EMIT_LOC_STRINGS = YES;",
    "SWIFT_VERSION = 5.0;",
    "TARGETED_DEVICE_FAMILY = 1;",
]

p("/* Begin XCBuildConfiguration section */")
p(f"\t\t{PROJ_DEBUG} /* Debug */ = {{")
p("\t\t\tisa = XCBuildConfiguration;")
p("\t\t\tbuildSettings = {")
p("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
p("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
p("\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";")
p("\t\t\t\tCOPY_PHASE_STRIP = NO;")
p("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
p("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
p("\t\t\t\tENABLE_TESTABILITY = YES;")
p("\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;")
p("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
p("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (")
p('\t\t\t\t\t"DEBUG=1",')
p("\t\t\t\t\t\"$(inherited)\",")
p("\t\t\t\t);")
p("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
p("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
p("\t\t\t\tSDKROOT = iphoneos;")
p("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
p("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
p("\t\t\t};")
p("\t\t\tname = Debug;")
p("\t\t};")
p(f"\t\t{PROJ_REL} /* Release */ = {{")
p("\t\t\tisa = XCBuildConfiguration;")
p("\t\t\tbuildSettings = {")
p("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
p("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
p("\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";")
p("\t\t\t\tCOPY_PHASE_STRIP = NO;")
p("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
p("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
p("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
p("\t\t\t\tGCC_OPTIMIZATION_LEVEL = s;")
p("\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;")
p("\t\t\t\tSDKROOT = iphoneos;")
p("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
p("\t\t\t\tVALIDATE_PRODUCT = YES;")
p("\t\t\t};")
p("\t\t\tname = Release;")
p("\t\t};")

p(f"\t\t{TGT_DEBUG} /* Debug */ = {{")
p("\t\t\tisa = XCBuildConfiguration;")
p("\t\t\tbuildSettings = {")
for line in common_target_lines:
    p("\t\t\t\t" + line)
p("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
p('\t\t\t\t\t"$(inherited)",')
p('\t\t\t\t\t"@executable_path/Frameworks",')
p("\t\t\t\t);")
p("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
p("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
p("\t\t\t};")
p("\t\t\tname = Debug;")
p("\t\t};")

p(f"\t\t{TGT_REL} /* Release */ = {{")
p("\t\t\tisa = XCBuildConfiguration;")
p("\t\t\tbuildSettings = {")
for line in common_target_lines:
    p("\t\t\t\t" + line)
p("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
p('\t\t\t\t\t"$(inherited)",')
p('\t\t\t\t\t"@executable_path/Frameworks",')
p("\t\t\t\t);")
p("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
p("\t\t\t};")
p("\t\t\tname = Release;")
p("\t\t};")
p("/* End XCBuildConfiguration section */")
p("")

p("/* Begin XCConfigurationList section */")
p(f"\t\t{PROJECT_CONF_LIST} /* Build configuration list for PBXProject \"SpotifyDisplay\" */ = {{")
p("\t\t\tisa = XCConfigurationList;")
p("\t\t\tbuildConfigurations = (")
p(f"\t\t\t\t{PROJ_DEBUG} /* Debug */,")
p(f"\t\t\t\t{PROJ_REL} /* Release */,")
p("\t\t\t);")
p("\t\t\tdefaultConfigurationIsVisible = 0;")
p("\t\t\tdefaultConfigurationName = Release;")
p("\t\t};")
p(f"\t\t{TARGET_CONF_LIST} /* Build configuration list for PBXNativeTarget \"SpotifyDisplay\" */ = {{")
p("\t\t\tisa = XCConfigurationList;")
p("\t\t\tbuildConfigurations = (")
p(f"\t\t\t\t{TGT_DEBUG} /* Debug */,")
p(f"\t\t\t\t{TGT_REL} /* Release */,")
p("\t\t\t);")
p("\t\t\tdefaultConfigurationIsVisible = 0;")
p("\t\t\tdefaultConfigurationName = Release;")
p("\t\t};")
p("/* End XCConfigurationList section */")

p("\t};")
p(f"\trootObject = {PROJECT} /* Project object */;")
p("}")

text = "\n".join(lines) + "\n"

proj_dir = os.path.join(os.path.dirname(__file__), "SpotifyDisplay.xcodeproj")
out = os.path.join(proj_dir, "project.pbxproj")
os.makedirs(proj_dir, exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    f.write(text)
print("Wrote", out)

scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
scheme_path = os.path.join(scheme_dir, "SpotifyDisplay.xcscheme")
scheme_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TARGET}"
               BuildableName = "SpotifyDisplay.app"
               BlueprintName = "SpotifyDisplay"
               ReferencedContainer = "container:SpotifyDisplay.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{TARGET}"
            BuildableName = "SpotifyDisplay.app"
            BlueprintName = "SpotifyDisplay"
            ReferencedContainer = "container:SpotifyDisplay.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{TARGET}"
            BuildableName = "SpotifyDisplay.app"
            BlueprintName = "SpotifyDisplay"
            ReferencedContainer = "container:SpotifyDisplay.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
with open(scheme_path, "w", encoding="utf-8") as f:
    f.write(scheme_xml)
print("Wrote", scheme_path)
