#!/usr/bin/env python3
"""Generate ios/SpotifyDisplay.xcodeproj/project.pbxproj for SpotifyDisplay iOS app.

Every *.swift file in SpotifyDisplay.swiftpm/Sources/SpotifyDisplay is compiled (found by listing
the folder, sorted), plus the shared C++ transition core in
SpotifyDisplay.swiftpm/Sources/TransitionsCore (the same file the ESP32 firmware builds). Swift sees
the core's C API through ios/SpotifyDisplay-Bridging-Header.h, which this script also writes.
Object ids are derived from names, so re-running it gives the same project.
"""
import hashlib
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(HERE, "..", "SpotifyDisplay.swiftpm", "Sources", "SpotifyDisplay")
CORE_REL = "../SpotifyDisplay.swiftpm/Sources/TransitionsCore"
CORE_CPP = "transitions_core.cpp"
CORE_H = "transitions_core.h"
BRIDGING_HEADER = "SpotifyDisplay-Bridging-Header.h"


def uid(key):
    return hashlib.md5(("SpotifyDisplay:" + key).encode("utf-8")).hexdigest()[:24].upper()


PROJECT = uid("project")
TARGET = uid("target")
MAIN_GROUP = uid("group.main")
PRODUCTS_GROUP = uid("group.products")
SOURCES_PHASE = uid("phase.sources")
FRAMEWORKS_PHASE = uid("phase.frameworks")
RESOURCES_PHASE = uid("phase.resources")
APP_REF = uid("ref.app")
SPOTIFY_GROUP = uid("group.spotify")
CORE_GROUP = uid("group.core")
CORE_INCLUDE_GROUP = uid("group.core.include")
CORE_CPP_REF = uid("ref.core.cpp")
CORE_CPP_BUILD = uid("build.core.cpp")
CORE_H_REF = uid("ref.core.h")
BRIDGING_REF = uid("ref.bridging")
PROJECT_CONF_LIST = uid("conflist.project")
TARGET_CONF_LIST = uid("conflist.target")
PROJ_DEBUG = uid("conf.project.debug")
PROJ_REL = uid("conf.project.release")
TGT_DEBUG = uid("conf.target.debug")
TGT_REL = uid("conf.target.release")
# Unit tests (ios/SpotifyDisplayTests), hosted in the app so `@testable import SpotifyDisplay` works.
TEST_DIR = os.path.join(HERE, "SpotifyDisplayTests")
TEST_TARGET = uid("target.tests")
TEST_SOURCES_PHASE = uid("phase.tests.sources")
TEST_FRAMEWORKS_PHASE = uid("phase.tests.frameworks")
TEST_PRODUCT_REF = uid("ref.tests.xctest")
TEST_GROUP = uid("group.tests")
TEST_CONF_LIST = uid("conflist.tests")
TEST_DEBUG = uid("conf.tests.debug")
TEST_REL = uid("conf.tests.release")
TEST_PROXY = uid("proxy.tests")
TEST_DEPENDENCY = uid("dependency.tests")

swift_files = sorted(f for f in os.listdir(SRC_DIR) if f.endswith(".swift"))
if not swift_files:
    raise SystemExit("no Swift files found in " + SRC_DIR)

file_refs = {}
build_files = {}
for name in swift_files:
    file_refs[name] = uid("ref.swift." + name)
    build_files[name] = uid("build.swift." + name)

test_files = sorted(f for f in os.listdir(TEST_DIR) if f.endswith(".swift"))
for name in test_files:
    file_refs[name] = uid("ref.test." + name)
    build_files[name] = uid("build.test." + name)

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
for name in swift_files + test_files:
    p(f"\t\t{build_files[name]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[name]} /* {name} */; }};")
# -O2 even in Debug: the app renders every transition with the core, frame by frame.
p(f"\t\t{CORE_CPP_BUILD} /* {CORE_CPP} in Sources */ = {{isa = PBXBuildFile; fileRef = {CORE_CPP_REF} /* {CORE_CPP} */; settings = {{COMPILER_FLAGS = \"-O2\"; }}; }};")
p("/* End PBXBuildFile section */")
p("")

p("/* Begin PBXFileReference section */")
p(f"\t\t{APP_REF} /* SpotifyDisplay.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SpotifyDisplay.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
for name in swift_files:
    p(f"\t\t{file_refs[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};")
p(f"\t\t{CORE_CPP_REF} /* {CORE_CPP} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.cpp.cpp; path = {CORE_CPP}; sourceTree = \"<group>\"; }};")
p(f"\t\t{CORE_H_REF} /* {CORE_H} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = {CORE_H}; sourceTree = \"<group>\"; }};")
p(f"\t\t{BRIDGING_REF} /* {BRIDGING_HEADER} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = \"{BRIDGING_HEADER}\"; sourceTree = \"<group>\"; }};")
p(f"\t\t{TEST_PRODUCT_REF} /* SpotifyDisplayTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = SpotifyDisplayTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};")
for name in test_files:
    p(f"\t\t{file_refs[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};")
p("/* End PBXFileReference section */")
p("")

p("/* Begin PBXContainerItemProxy section */")
p(f"\t\t{TEST_PROXY} /* PBXContainerItemProxy */ = {{")
p("\t\t\tisa = PBXContainerItemProxy;")
p(f"\t\t\tcontainerPortal = {PROJECT} /* Project object */;")
p("\t\t\tproxyType = 1;")
p(f"\t\t\tremoteGlobalIDString = {TARGET};")
p("\t\t\tremoteInfo = SpotifyDisplay;")
p("\t\t};")
p("/* End PBXContainerItemProxy section */")
p("")

p("/* Begin PBXFrameworksBuildPhase section */")
p(f"\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{")
p("\t\t\tisa = PBXFrameworksBuildPhase;")
p("\t\t\tbuildActionMask = 2147483647;")
p("\t\t\tfiles = (")
p("\t\t\t);")
p("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
p("\t\t};")
p(f"\t\t{TEST_FRAMEWORKS_PHASE} /* Frameworks */ = {{")
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
p(f"\t\t{CORE_GROUP} /* TransitionsCore */ = {{")
p("\t\t\tisa = PBXGroup;")
p(f"\t\t\tchildren = ({CORE_CPP_REF} /* {CORE_CPP} */, {CORE_INCLUDE_GROUP} /* include */);")
p("\t\t\tname = TransitionsCore;")
p(f'\t\t\tpath = "{CORE_REL}";')
p('\t\t\tsourceTree = "<group>";')
p("\t\t};")
p(f"\t\t{CORE_INCLUDE_GROUP} /* include */ = {{")
p("\t\t\tisa = PBXGroup;")
p(f"\t\t\tchildren = ({CORE_H_REF} /* {CORE_H} */);")
p("\t\t\tpath = include;")
p('\t\t\tsourceTree = "<group>";')
p("\t\t};")
ch_test = ", ".join([f"{file_refs[n]} /* {n} */" for n in test_files])
p(f"\t\t{TEST_GROUP} /* SpotifyDisplayTests */ = {{")
p("\t\t\tisa = PBXGroup;")
p(f"\t\t\tchildren = ({ch_test});")
p("\t\t\tpath = SpotifyDisplayTests;")
p('\t\t\tsourceTree = "<group>";')
p("\t\t};")
p(f"\t\t{PRODUCTS_GROUP} /* Products */ = {{")
p("\t\t\tisa = PBXGroup;")
p(f"\t\t\tchildren = ({APP_REF} /* SpotifyDisplay.app */, {TEST_PRODUCT_REF} /* SpotifyDisplayTests.xctest */);")
p("\t\t\tname = Products;")
p('\t\t\tsourceTree = "<group>";')
p("\t\t};")
p(f"\t\t{MAIN_GROUP} = {{")
p("\t\t\tisa = PBXGroup;")
p(f"\t\t\tchildren = ({SPOTIFY_GROUP} /* SpotifyDisplay */, {CORE_GROUP} /* TransitionsCore */, {BRIDGING_REF} /* {BRIDGING_HEADER} */, {TEST_GROUP} /* SpotifyDisplayTests */, {PRODUCTS_GROUP} /* Products */);")
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
p(f"\t\t{TEST_TARGET} /* SpotifyDisplayTests */ = {{")
p("\t\t\tisa = PBXNativeTarget;")
p(f"\t\t\tbuildConfigurationList = {TEST_CONF_LIST} /* Build configuration list for PBXNativeTarget \"SpotifyDisplayTests\" */;")
p("\t\t\tbuildPhases = (")
p(f"\t\t\t\t{TEST_SOURCES_PHASE} /* Sources */,")
p(f"\t\t\t\t{TEST_FRAMEWORKS_PHASE} /* Frameworks */,")
p("\t\t\t);")
p("\t\t\tbuildRules = (")
p("\t\t\t);")
p("\t\t\tdependencies = (")
p(f"\t\t\t\t{TEST_DEPENDENCY} /* PBXTargetDependency */,")
p("\t\t\t);")
p("\t\t\tname = SpotifyDisplayTests;")
p("\t\t\tproductName = SpotifyDisplayTests;")
p(f"\t\t\tproductReference = {TEST_PRODUCT_REF} /* SpotifyDisplayTests.xctest */;")
p("\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";")
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
p(f"\t\t\t\t\t{TEST_TARGET} = {{")
p("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
p(f"\t\t\t\t\t\tTestTargetID = {TARGET};")
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
p(f"\t\t\t\t{TEST_TARGET} /* SpotifyDisplayTests */,")
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
p(f"\t\t\t\t{CORE_CPP_BUILD} /* {CORE_CPP} in Sources */,")
p("\t\t\t);")
p("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
p("\t\t};")
p(f"\t\t{TEST_SOURCES_PHASE} /* Sources */ = {{")
p("\t\t\tisa = PBXSourcesBuildPhase;")
p("\t\t\tbuildActionMask = 2147483647;")
p("\t\t\tfiles = (")
for name in test_files:
    p(f"\t\t\t\t{build_files[name]} /* {name} in Sources */,")
p("\t\t\t);")
p("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
p("\t\t};")
p("/* End PBXSourcesBuildPhase section */")
p("")

p("/* Begin PBXTargetDependency section */")
p(f"\t\t{TEST_DEPENDENCY} /* PBXTargetDependency */ = {{")
p("\t\t\tisa = PBXTargetDependency;")
p(f"\t\t\ttarget = {TARGET} /* SpotifyDisplay */;")
p(f"\t\t\ttargetProxy = {TEST_PROXY} /* PBXContainerItemProxy */;")
p("\t\t};")
p("/* End PBXTargetDependency section */")
p("")

INFOPLIST_PATH = "../SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/Resources/Info.plist"

common_target_lines = [
    "CLANG_CXX_LANGUAGE_STANDARD = \"gnu++17\";",
    "CLANG_CXX_LIBRARY = \"libc++\";",
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
    "GCC_C_LANGUAGE_STANDARD = gnu11;",
    f'HEADER_SEARCH_PATHS = ("$(inherited)", "$(SRCROOT)/{CORE_REL}/include");',
    "SWIFT_EMIT_LOC_STRINGS = YES;",
    f'SWIFT_OBJC_BRIDGING_HEADER = "{BRIDGING_HEADER}";',
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
# Same bridging header and C++ include path as the app: `@testable import SpotifyDisplay` pulls in the
# module's C++ core types, and the test compile must be able to resolve them too.
test_target_lines = [
    'BUNDLE_LOADER = "$(TEST_HOST)";',
    "CLANG_CXX_LANGUAGE_STANDARD = \"gnu++17\";",
    "CLANG_CXX_LIBRARY = \"libc++\";",
    "CODE_SIGN_STYLE = Automatic;",
    'DEVELOPMENT_TEAM = "";',
    "GENERATE_INFOPLIST_FILE = YES;",
    f'HEADER_SEARCH_PATHS = ("$(inherited)", "$(SRCROOT)/{CORE_REL}/include");',
    "IPHONEOS_DEPLOYMENT_TARGET = 16.0;",
    "PRODUCT_BUNDLE_IDENTIFIER = com.example.spotifydisplay.tests;",
    'PRODUCT_NAME = "$(TARGET_NAME)";',
    f'SWIFT_OBJC_BRIDGING_HEADER = "{BRIDGING_HEADER}";',
    "SWIFT_VERSION = 5.0;",
    "TARGETED_DEVICE_FAMILY = 1;",
    'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/SpotifyDisplay.app/SpotifyDisplay";',
]
for conf_id, conf_name, extra in [
    (TEST_DEBUG, "Debug", ["SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;", 'SWIFT_OPTIMIZATION_LEVEL = "-Onone";']),
    (TEST_REL, "Release", ["SWIFT_COMPILATION_MODE = wholemodule;"]),
]:
    p(f"\t\t{conf_id} /* {conf_name} */ = {{")
    p("\t\t\tisa = XCBuildConfiguration;")
    p("\t\t\tbuildSettings = {")
    for line in test_target_lines + extra:
        p("\t\t\t\t" + line)
    p("\t\t\t};")
    p(f"\t\t\tname = {conf_name};")
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
p(f"\t\t{TEST_CONF_LIST} /* Build configuration list for PBXNativeTarget \"SpotifyDisplayTests\" */ = {{")
p("\t\t\tisa = XCConfigurationList;")
p("\t\t\tbuildConfigurations = (")
p(f"\t\t\t\t{TEST_DEBUG} /* Debug */,")
p(f"\t\t\t\t{TEST_REL} /* Release */,")
p("\t\t\t);")
p("\t\t\tdefaultConfigurationIsVisible = 0;")
p("\t\t\tdefaultConfigurationName = Release;")
p("\t\t};")
p("/* End XCConfigurationList section */")

p("\t};")
p(f"\trootObject = {PROJECT} /* Project object */;")
p("}")

text = "\n".join(lines) + "\n"

# Bridging header (Xcode project only; SwiftPM imports the TransitionsCore module instead).
# The quoted include resolves relative to this header's own folder (ios/).
bridging_path = os.path.join(HERE, BRIDGING_HEADER)
with open(bridging_path, "w", encoding="utf-8", newline="\n") as f:
    f.write("// Generated by ios/gen_xcodeproj.py. Lets Swift call the shared C++ transition core.\n")
    f.write(f'#include "{CORE_REL}/include/{CORE_H}"\n')
print("Wrote", bridging_path)

proj_dir = os.path.join(HERE, "SpotifyDisplay.xcodeproj")
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
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TEST_TARGET}"
               BuildableName = "SpotifyDisplayTests.xctest"
               BlueprintName = "SpotifyDisplayTests"
               ReferencedContainer = "container:SpotifyDisplay.xcodeproj">
            </BuildableReference>
         </TestableReference>
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
