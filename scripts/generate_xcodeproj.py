#!/usr/bin/env python3
"""esepad.xcodeproj を書き出す。

XcodeGen などの外部ツールは使わない（追加の依存を入れない）。
フォルダ同期のグループ（objectVersion 77）を使うので、Swift ファイルやリソースを足してもこのスクリプトを回し直す必要はない。
ターゲットやビルド設定を変える時だけ、ここを直して `python3 scripts/generate_xcodeproj.py` を回す。

ターゲット: esepad（iPhone）/ EsepadMac（Mac のメニューバー）。どちらも Packages/EsepadCore を使う。
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "esepad.xcodeproj")

DEPLOY_IOS = "17.0"
DEPLOY_MAC = "14.0"
VERSION = "0.2.0"
BUILD = "1"
PRODUCT = "EsepadCore"


def oid(name: str) -> str:
    return hashlib.md5(("esepad:" + name).encode()).hexdigest()[:24].upper()


TARGETS = ["ios", "mac"]
NAME = {"ios": "esepad", "mac": "EsepadMac"}
PRODUCT_FILE = {"ios": "esepad.app", "mac": "EsepadMac.app"}
GROUP_DIR = {"ios": "iOS", "mac": "Mac"}

PROJECT = oid("project")
MAIN_GROUP = oid("mainGroup")
PRODUCTS_GROUP = oid("productsGroup")
PKG_REF = oid("pkgRef")
BASE_XCCONFIG = oid("baseXcconfig")
CONFIG_GROUP = oid("configGroup")
PACKAGES_GROUP = oid("packagesGroup")

T = {t: oid("target" + t) for t in TARGETS}
SYNC = {t: oid("sync" + t) for t in TARGETS}
PRODUCT_REF = {t: oid("product" + t) for t in TARGETS}
INFO_REF = {t: oid("info" + t) for t in TARGETS}
GROUP = {t: oid("group" + t) for t in TARGETS}
DEP = {t: oid("dep" + t) for t in TARGETS}
BLD = {t: oid("bld" + t) for t in TARGETS}
PH = {(t, k): oid("phase" + t + k) for t in TARGETS for k in ("Sources", "Frameworks", "Resources")}
CFG_LIST = {t: oid("cfgList" + t) for t in TARGETS}
CFG_LIST_PROJECT = oid("cfgListProject")
CFG = {k: oid("cfg" + k) for k in ["ProjectDebug", "ProjectRelease", "iosDebug", "iosRelease", "macDebug", "macRelease"]}


def settings(d: dict, indent: int = 4) -> str:
    pad = "\t" * indent
    lines = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            lines.append(f"{pad}{k} = (")
            for item in v:
                lines.append(f'{pad}\t"{item}",')
            lines.append(f"{pad});")
        else:
            s = str(v)
            if not s or any(c in s for c in ' $()"@<>=,;-:+*/'):
                s = '"' + s.replace('"', '\\"') + '"'
            lines.append(f"{pad}{k} = {s};")
    return "\n".join(lines)


project_common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_COMMA": "YES",
    "CLANG_WARN_CONSTANT_CONVERSION": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_ENUM_CONVERSION": "YES",
    "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_INT_CONVERSION": "YES",
    "CLANG_WARN_STRICT_PROTOTYPES": "YES",
    "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
    "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "SWIFT_VERSION": "5.0",
}
project_debug = dict(project_common, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})
project_release = dict(project_common, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
})

target_common = {
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": BUILD,
    "DEVELOPMENT_TEAM": "$(DEVELOPMENT_TEAM)",
    "GENERATE_INFOPLIST_FILE": "NO",
    "MARKETING_VERSION": VERSION,
    "PRODUCT_NAME": "$(TARGET_NAME)",
}
ios_settings = dict(target_common, **{
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "INFOPLIST_FILE": "iOS/Info.plist",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOY_IOS,
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX).esepad",
    "SDKROOT": "iphoneos",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO",
    "TARGETED_DEVICE_FAMILY": "1",
})
mac_settings = dict(target_common, **{
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ENABLE_HARDENED_RUNTIME": "NO",
    "INFOPLIST_FILE": "Mac/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    "MACOSX_DEPLOYMENT_TARGET": DEPLOY_MAC,
    "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX).esepad.mac",
    "SDKROOT": "macosx",
    "SUPPORTED_PLATFORMS": "macosx",
})
TARGET_SETTINGS = {"ios": ios_settings, "mac": mac_settings}

build_files = "\n".join(
    f"\t\t{BLD[t]} /* {PRODUCT} in Frameworks */ = {{isa = PBXBuildFile; productRef = {DEP[t]} /* {PRODUCT} */; }};"
    for t in TARGETS)
dep_section = "\n".join(
    f"\t\t{DEP[t]} /* {PRODUCT} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = {PRODUCT};\n\t\t}};"
    for t in TARGETS)

file_refs = []
for t in TARGETS:
    ptype = "wrapper.application"
    file_refs.append(f"\t\t{PRODUCT_REF[t]} /* {PRODUCT_FILE[t]} */ = {{isa = PBXFileReference; explicitFileType = {ptype}; includeInIndex = 0; path = {PRODUCT_FILE[t]}; sourceTree = BUILT_PRODUCTS_DIR; }};")
    file_refs.append(f"\t\t{INFO_REF[t]} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
file_refs.append(f"\t\t{BASE_XCCONFIG} /* Base.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Base.xcconfig; sourceTree = \"<group>\"; }};")

sync_groups = "\n".join(
    f"\t\t{SYNC[t]} /* Sources */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = Sources;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};"
    for t in TARGETS)

frameworks_phases = "\n".join(
    f"""\t\t{PH[(t, 'Frameworks')]} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{BLD[t]} /* {PRODUCT} in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};"""
    for t in TARGETS)

groups = f"""\t\t{MAIN_GROUP} = {{
			isa = PBXGroup;
			children = (
				{GROUP['ios']} /* iOS */,
				{GROUP['mac']} /* Mac */,
				{PACKAGES_GROUP} /* Packages */,
				{CONFIG_GROUP} /* Config */,
				{PRODUCTS_GROUP} /* Products */,
			);
			sourceTree = "<group>";
		}};
""" + "".join(
    f"""\t\t{GROUP[t]} /* {GROUP_DIR[t]} */ = {{
			isa = PBXGroup;
			children = (
				{SYNC[t]} /* Sources */,
				{INFO_REF[t]} /* Info.plist */,
			);
			path = {GROUP_DIR[t]};
			sourceTree = "<group>";
		}};
""" for t in TARGETS) + f"""\t\t{PACKAGES_GROUP} /* Packages */ = {{
			isa = PBXGroup;
			children = (
			);
			path = Packages;
			sourceTree = "<group>";
		}};
		{CONFIG_GROUP} /* Config */ = {{
			isa = PBXGroup;
			children = (
				{BASE_XCCONFIG} /* Base.xcconfig */,
			);
			path = Config;
			sourceTree = "<group>";
		}};
		{PRODUCTS_GROUP} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{PRODUCT_REF['ios']} /* {PRODUCT_FILE['ios']} */,
				{PRODUCT_REF['mac']} /* {PRODUCT_FILE['mac']} */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
"""

native_targets = "\n".join(
    f"""\t\t{T[t]} /* {NAME[t]} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {CFG_LIST[t]} /* Build configuration list for PBXNativeTarget "{NAME[t]}" */;
			buildPhases = (
				{PH[(t, 'Sources')]} /* Sources */,
				{PH[(t, 'Frameworks')]} /* Frameworks */,
				{PH[(t, 'Resources')]} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{SYNC[t]} /* Sources */,
			);
			name = {NAME[t]};
			packageProductDependencies = (
				{DEP[t]} /* {PRODUCT} */,
			);
			productName = {NAME[t]};
			productReference = {PRODUCT_REF[t]} /* {PRODUCT_FILE[t]} */;
			productType = "com.apple.product-type.application";
		}};"""
    for t in TARGETS)

simple_phases = "\n".join(
    f"""\t\t{PH[(t, 'Sources')]} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};"""
    for t in TARGETS)
resource_phases = "\n".join(
    f"""\t\t{PH[(t, 'Resources')]} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};"""
    for t in TARGETS)

cfgs = (
    f"""\t\t{CFG['ProjectDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			baseConfigurationReference = {BASE_XCCONFIG} /* Base.xcconfig */;
			buildSettings = {{
{settings(project_debug)}
			}};
			name = Debug;
		}};
		{CFG['ProjectRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			baseConfigurationReference = {BASE_XCCONFIG} /* Base.xcconfig */;
			buildSettings = {{
{settings(project_release)}
			}};
			name = Release;
		}};
"""
    + "".join(
        f"""\t\t{CFG[t + c]} /* {c} */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(TARGET_SETTINGS[t])}
			}};
			name = {c};
		}};
""" for t in TARGETS for c in ("Debug", "Release"))
)

cfg_lists = f"""\t\t{CFG_LIST_PROJECT} /* Build configuration list for PBXProject "esepad" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{CFG['ProjectDebug']} /* Debug */,
				{CFG['ProjectRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
""" + "".join(
    f"""\t\t{CFG_LIST[t]} /* Build configuration list for PBXNativeTarget "{NAME[t]}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{CFG[t + 'Debug']} /* Debug */,
				{CFG[t + 'Release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
""" for t in TARGETS)

target_attrs = "\n".join(f"\t\t\t\t\t{T[t]} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.0;\n\t\t\t\t\t}};" for t in TARGETS)

pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
{build_files}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_refs)}
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
{sync_groups}
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
{frameworks_phases}
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
{groups}/* End PBXGroup section */

/* Begin PBXNativeTarget section */
{native_targets}
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{PROJECT} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
				TargetAttributes = {{
{target_attrs}
				}};
			}};
			buildConfigurationList = {CFG_LIST_PROJECT} /* Build configuration list for PBXProject "esepad" */;
			developmentRegion = ja;
			hasScannedForEncodings = 0;
			knownRegions = (
				ja,
				en,
				Base,
			);
			mainGroup = {MAIN_GROUP};
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				{PKG_REF} /* XCLocalSwiftPackageReference "Packages/EsepadCore" */,
			);
			productRefGroup = {PRODUCTS_GROUP} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{T['ios']} /* {NAME['ios']} */,
				{T['mac']} /* {NAME['mac']} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
{resource_phases}
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
{simple_phases}
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
{cfgs}/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
{cfg_lists}/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{PKG_REF} /* XCLocalSwiftPackageReference "Packages/EsepadCore" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/EsepadCore;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
{dep_section}
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {PROJECT} /* Project object */;
}}
"""


def scheme(t: str) -> str:
    ref = f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{T[t]}" BuildableName = "{PRODUCT_FILE[t]}" BlueprintName = "{NAME[t]}" ReferencedContainer = "container:esepad.xcodeproj">\n         </BuildableReference>'
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


schemes_dir = os.path.join(OUT, "xcshareddata", "xcschemes")
os.makedirs(schemes_dir, exist_ok=True)
with open(os.path.join(OUT, "project.pbxproj"), "w") as f:
    f.write(pbx)
for t in TARGETS:
    with open(os.path.join(schemes_dir, NAME[t] + ".xcscheme"), "w") as f:
        f.write(scheme(t))
print("wrote", OUT)
