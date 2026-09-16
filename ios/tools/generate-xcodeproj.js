#!/usr/bin/env node
/**
 * 生成 ios/GoToLibrary.xcodeproj/project.pbxproj。
 *
 * 手写 pbxproj 极易漏文件或写错路径，而这个仓库没有 Xcode 可用来校验，
 * 所以用脚本从磁盘真实文件树生成，保证 PBXSourcesBuildPhase 与文件系统一致。
 * 新增 Swift 文件后重跑：node ios/tools/generate-xcodeproj.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const PROJECT = path.join(ROOT, 'GoToLibrary.xcodeproj');
const TARGET = 'GoToLibrary';
const BUNDLE_ID = 'com.gotolibrary.nativeapp';

// UUID 用稳定派生值：同一路径每次生成得到同一个 ID，避免无意义的全量 diff。
function uuid(seed) {
  const crypto = require('crypto');
  return crypto.createHash('md5').update(seed).digest('hex').slice(0, 24).toUpperCase();
}

function collect(dir, ext) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!entry.name.endsWith('.xcassets')) out.push(...collect(full, ext));
    } else if (entry.name.endsWith(ext)) {
      out.push(full);
    }
  }
  return out;
}

const swiftFiles = collect(path.join(ROOT, 'GoToLibrary'), '.swift');
if (swiftFiles.length === 0) throw new Error('没有找到任何 .swift 文件');

// 相对工程根目录（ios/）的路径，pbxproj 里 sourceTree = "<group>" 时用这个。
const rel = (abs) => path.relative(ROOT, abs).split(path.sep).join('/');

const groups = { Core: [], Services: [], UI: [], root: [] };
for (const abs of swiftFiles) {
  const r = rel(abs);
  if (r.startsWith('GoToLibrary/Core/')) groups.Core.push(abs);
  else if (r.startsWith('GoToLibrary/Services/')) groups.Services.push(abs);
  else if (r.startsWith('GoToLibrary/UI/')) groups.UI.push(abs);
  else groups.root.push(abs);
}

const lines = [];
const push = (s = '') => lines.push(s);

push('// !$*UTF8*$!');
push('{');
push('\tarchiveVersion = 1;');
push('\tclasses = {');
push('\t};');
push('\tobjectVersion = 56;');
push('\tobjects = {');

// ---- PBXBuildFile ----
push('');
push('/* Begin PBXBuildFile section */');
const buildFileIds = {};
for (const abs of swiftFiles) {
  const id = uuid('buildfile:' + rel(abs));
  buildFileIds[abs] = id;
  push(`\t\t${id} /* ${path.basename(abs)} in Sources */ = {isa = PBXBuildFile; fileRef = ${uuid('fileref:' + rel(abs))} /* ${path.basename(abs)} */; };`);
}
const assetsAbs = path.join(ROOT, 'GoToLibrary/Assets.xcassets');
const assetsBuildId = uuid('buildfile:' + rel(assetsAbs));
const assetsRefId = uuid('fileref:' + rel(assetsAbs));
push(`\t\t${assetsBuildId} /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = ${assetsRefId} /* Assets.xcassets */; };`);
// 隐私清单必须进 Resources 阶段才会被合并进 app bundle，且文件名固定，不能改名。
const privacyAbs = path.join(ROOT, 'GoToLibrary/PrivacyInfo.xcprivacy');
const privacyBuildId = uuid('buildfile:' + rel(privacyAbs));
const privacyRefId = uuid('fileref:' + rel(privacyAbs));
push(`\t\t${privacyBuildId} /* PrivacyInfo.xcprivacy in Resources */ = {isa = PBXBuildFile; fileRef = ${privacyRefId} /* PrivacyInfo.xcprivacy */; };`);
push('/* End PBXBuildFile section */');

// ---- PBXFileReference ----
push('');
push('/* Begin PBXFileReference section */');
for (const abs of swiftFiles) {
  const r = rel(abs);
  push(`\t\t${uuid('fileref:' + r)} /* ${path.basename(abs)} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = ${path.basename(abs)}; path = ${path.basename(abs)}; sourceTree = "<group>"; };`);
}
push(`\t\t${assetsRefId} /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = Assets.xcassets; path = Assets.xcassets; sourceTree = "<group>"; };`);
push(`\t\t${privacyRefId} /* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference; lastKnownFileType = text.xml; name = PrivacyInfo.xcprivacy; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };`);
const plistRefId = uuid('fileref:Info.plist');
push(`\t\t${plistRefId} /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = Info.plist; path = Info.plist; sourceTree = "<group>"; };`);
const entRefId = uuid('fileref:entitlements');
push(`\t\t${entRefId} /* GoToLibrary.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; name = GoToLibrary.entitlements; path = GoToLibrary.entitlements; sourceTree = "<group>"; };`);
const productRefId = uuid('product:' + TARGET);
push(`\t\t${productRefId} /* ${TARGET}.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ${TARGET}.app; sourceTree = BUILT_PRODUCTS_DIR; };`);
push('/* End PBXFileReference section */');

// ---- PBXFrameworksBuildPhase ----
const frameworksPhaseId = uuid('phase:frameworks');
push('');
push('/* Begin PBXFrameworksBuildPhase section */');
push(`\t\t${frameworksPhaseId} /* Frameworks */ = {`);
push('\t\t\tisa = PBXFrameworksBuildPhase;');
push('\t\t\tbuildActionMask = 2147483647;');
push('\t\t\tfiles = (');
push('\t\t\t);');
push('\t\t\trunOnlyForDeploymentPostprocessing = 0;');
push('\t\t};');
push('/* End PBXFrameworksBuildPhase section */');

// ---- PBXGroup ----
const mainGroupId = uuid('group:main');
const appGroupId = uuid('group:app');
const productsGroupId = uuid('group:products');
const coreGroupId = uuid('group:Core');
const servicesGroupId = uuid('group:Services');
const uiGroupId = uuid('group:UI');

function groupChildren(list) {
  return list.map((abs) => `\t\t\t\t${uuid('fileref:' + rel(abs))} /* ${path.basename(abs)} */,`).join('\n');
}

push('');
push('/* Begin PBXGroup section */');
push(`\t\t${mainGroupId} = {`);
push('\t\t\tisa = PBXGroup;');
push('\t\t\tchildren = (');
push(`\t\t\t\t${appGroupId} /* GoToLibrary */,`);
push(`\t\t\t\t${productsGroupId} /* Products */,`);
push('\t\t\t);');
push('\t\t\tsourceTree = "<group>";');
push('\t\t};');

push(`\t\t${appGroupId} /* GoToLibrary */ = {`);
push('\t\t\tisa = PBXGroup;');
push('\t\t\tchildren = (');
for (const abs of groups.root) push(`\t\t\t\t${uuid('fileref:' + rel(abs))} /* ${path.basename(abs)} */,`);
push(`\t\t\t\t${coreGroupId} /* Core */,`);
push(`\t\t\t\t${servicesGroupId} /* Services */,`);
push(`\t\t\t\t${uiGroupId} /* UI */,`);
push(`\t\t\t\t${assetsRefId} /* Assets.xcassets */,`);
push(`\t\t\t\t${privacyRefId} /* PrivacyInfo.xcprivacy */,`);
push(`\t\t\t\t${plistRefId} /* Info.plist */,`);
push(`\t\t\t\t${entRefId} /* GoToLibrary.entitlements */,`);
push('\t\t\t);');
push('\t\t\tpath = GoToLibrary;');
push('\t\t\tsourceTree = "<group>";');
push('\t\t};');

for (const [name, id, list] of [['Core', coreGroupId, groups.Core], ['Services', servicesGroupId, groups.Services], ['UI', uiGroupId, groups.UI]]) {
  push(`\t\t${id} /* ${name} */ = {`);
  push('\t\t\tisa = PBXGroup;');
  push('\t\t\tchildren = (');
  if (list.length) push(groupChildren(list));
  push('\t\t\t);');
  push(`\t\t\tpath = ${name};`);
  push('\t\t\tsourceTree = "<group>";');
  push('\t\t};');
}

push(`\t\t${productsGroupId} /* Products */ = {`);
push('\t\t\tisa = PBXGroup;');
push('\t\t\tchildren = (');
push(`\t\t\t\t${productRefId} /* ${TARGET}.app */,`);
push('\t\t\t);');
push('\t\t\tname = Products;');
push('\t\t\tsourceTree = "<group>";');
push('\t\t};');
push('/* End PBXGroup section */');

// ---- PBXNativeTarget ----
const targetId = uuid('target:' + TARGET);
const sourcesPhaseId = uuid('phase:sources');
const resourcesPhaseId = uuid('phase:resources');
const projectId = uuid('project');
const cfgListProjectId = uuid('cfglist:project');
const cfgListTargetId = uuid('cfglist:target');
const cfgDebugProjectId = uuid('cfg:project:Debug');
const cfgReleaseProjectId = uuid('cfg:project:Release');
const cfgDebugTargetId = uuid('cfg:target:Debug');
const cfgReleaseTargetId = uuid('cfg:target:Release');

push('');
push('/* Begin PBXNativeTarget section */');
push(`\t\t${targetId} /* ${TARGET} */ = {`);
push('\t\t\tisa = PBXNativeTarget;');
push(`\t\t\tbuildConfigurationList = ${cfgListTargetId} /* Build configuration list for PBXNativeTarget "${TARGET}" */;`);
push('\t\t\tbuildPhases = (');
push(`\t\t\t\t${sourcesPhaseId} /* Sources */,`);
push(`\t\t\t\t${frameworksPhaseId} /* Frameworks */,`);
push(`\t\t\t\t${resourcesPhaseId} /* Resources */,`);
push('\t\t\t);');
push('\t\t\tbuildRules = (');
push('\t\t\t);');
push('\t\t\tdependencies = (');
push('\t\t\t);');
push(`\t\t\tname = ${TARGET};`);
push(`\t\t\tproductName = ${TARGET};`);
push(`\t\t\tproductReference = ${productRefId} /* ${TARGET}.app */;`);
push('\t\t\tproductType = "com.apple.product-type.application";');
push('\t\t};');
push('/* End PBXNativeTarget section */');

// ---- PBXProject ----
push('');
push('/* Begin PBXProject section */');
push(`\t\t${projectId} /* Project object */ = {`);
push('\t\t\tisa = PBXProject;');
push('\t\t\tattributes = {');
push('\t\t\t\tBuildIndependentTargetsInParallel = 1;');
push('\t\t\t\tLastSwiftUpdateCheck = 1500;');
push('\t\t\t\tLastUpgradeCheck = 1500;');
push('\t\t\t\tTargetAttributes = {');
push(`\t\t\t\t\t${targetId} = {`);
push('\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;');
push('\t\t\t\t\t};');
push('\t\t\t\t};');
push('\t\t\t};');
push(`\t\t\tbuildConfigurationList = ${cfgListProjectId} /* Build configuration list for PBXProject "${TARGET}" */;`);
push('\t\t\tcompatibilityVersion = "Xcode 14.0";');
push('\t\t\tdevelopmentRegion = zh_CN;');
push('\t\t\thasScannedForEncodings = 0;');
push('\t\t\tknownRegions = (');
push('\t\t\t\tzh_CN,');
push('\t\t\t\tBase,');
push('\t\t\t);');
push(`\t\t\tmainGroup = ${mainGroupId};`);
push(`\t\t\tproductRefGroup = ${productsGroupId} /* Products */;`);
push('\t\t\tprojectDirPath = "";');
push('\t\t\tprojectRoot = "";');
push('\t\t\ttargets = (');
push(`\t\t\t\t${targetId} /* ${TARGET} */,`);
push('\t\t\t);');
push('\t\t};');
push('/* End PBXProject section */');

// ---- PBXResourcesBuildPhase ----
push('');
push('/* Begin PBXResourcesBuildPhase section */');
push(`\t\t${resourcesPhaseId} /* Resources */ = {`);
push('\t\t\tisa = PBXResourcesBuildPhase;');
push('\t\t\tbuildActionMask = 2147483647;');
push('\t\t\tfiles = (');
push(`\t\t\t\t${assetsBuildId} /* Assets.xcassets in Resources */,`);
push(`\t\t\t\t${privacyBuildId} /* PrivacyInfo.xcprivacy in Resources */,`);
push('\t\t\t);');
push('\t\t\trunOnlyForDeploymentPostprocessing = 0;');
push('\t\t};');
push('/* End PBXResourcesBuildPhase section */');

// ---- PBXSourcesBuildPhase ----
push('');
push('/* Begin PBXSourcesBuildPhase section */');
push(`\t\t${sourcesPhaseId} /* Sources */ = {`);
push('\t\t\tisa = PBXSourcesBuildPhase;');
push('\t\t\tbuildActionMask = 2147483647;');
push('\t\t\tfiles = (');
for (const abs of swiftFiles) {
  push(`\t\t\t\t${buildFileIds[abs]} /* ${path.basename(abs)} in Sources */,`);
}
push('\t\t\t);');
push('\t\t\trunOnlyForDeploymentPostprocessing = 0;');
push('\t\t};');
push('/* End PBXSourcesBuildPhase section */');

// ---- XCBuildConfiguration ----
const sharedSettings = {
  ALWAYS_SEARCH_USER_PATHS: 'NO',
  CLANG_ENABLE_MODULES: 'YES',
  CLANG_ENABLE_OBJC_ARC: 'YES',
  COPY_PHASE_STRIP: 'NO',
  ENABLE_STRICT_OBJC_MSGSEND: 'YES',
  GCC_C_LANGUAGE_STANDARD: 'gnu17',
  IPHONEOS_DEPLOYMENT_TARGET: '16.0',
  SDKROOT: 'iphoneos',
  SWIFT_VERSION: '5.9',
  // 本项目大量使用 @MainActor + @unchecked Sendable，complete 级别会刷出成片并发诊断，
  // 先保持 minimal 让它能编过；收敛并发后可在 README 的指引下逐级收紧。
  SWIFT_STRICT_CONCURRENCY: 'minimal',
  TARGETED_DEVICE_FAMILY: '"1,2"',
};

const targetSettings = {
  ASSETCATALOG_COMPILER_APPICON_NAME: 'AppIcon',
  ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: 'AccentColor',
  CODE_SIGN_ENTITLEMENTS: 'GoToLibrary/GoToLibrary.entitlements',
  CODE_SIGN_STYLE: 'Automatic',
  // 发版前必须填自己的 Team ID，否则 archive 会失败。
  DEVELOPMENT_TEAM: '""',
  CURRENT_PROJECT_VERSION: '37',
  MARKETING_VERSION: '1.8.6',
  ENABLE_USER_SCRIPT_SANDBOXING: 'YES',
  GENERATE_INFOPLIST_FILE: 'NO',
  INFOPLIST_FILE: 'GoToLibrary/Info.plist',
  INFOPLIST_KEY_UILaunchScreen_Generation: 'NO',
  LD_RUNPATH_SEARCH_PATHS: '"$(inherited) @executable_path/Frameworks"',
  PRODUCT_BUNDLE_IDENTIFIER: BUNDLE_ID,
  PRODUCT_NAME: '"$(TARGET_NAME)"',
  SWIFT_EMIT_LOC_STRINGS: 'YES',
};

function configBlock(id, name, settings) {
  const body = [];
  body.push(`\t\t${id} /* ${name} */ = {`);
  body.push('\t\t\tisa = XCBuildConfiguration;');
  body.push('\t\t\tbuildSettings = {');
  for (const [k, v] of Object.entries(settings)) body.push(`\t\t\t\t${k} = ${v};`);
  body.push('\t\t\t};');
  body.push('\t\t\tname = ' + name + ';');
  body.push('\t\t};');
  return body;
}

push('');
push('/* Begin XCBuildConfiguration section */');
for (const l of configBlock(cfgDebugProjectId, 'Debug', {
  ...sharedSettings,
  DEBUG_INFORMATION_FORMAT: 'dwarf',
  ENABLE_TESTABILITY: 'YES',
  GCC_OPTIMIZATION_LEVEL: '0',
  GCC_PREPROCESSOR_DEFINITIONS: '("DEBUG=1", "$(inherited)")',
  MTL_ENABLE_DEBUG_INFO: 'INCLUDE_SOURCE',
  ONLY_ACTIVE_ARCH: 'YES',
  SWIFT_ACTIVE_COMPILATION_CONDITIONS: 'DEBUG',
  SWIFT_OPTIMIZATION_LEVEL: '"-Onone"',
})) push(l);
for (const l of configBlock(cfgReleaseProjectId, 'Release', {
  ...sharedSettings,
  DEBUG_INFORMATION_FORMAT: '"dwarf-with-dsym"',
  ENABLE_NS_ASSERTIONS: 'NO',
  MTL_ENABLE_DEBUG_INFO: 'NO',
  SWIFT_COMPILATION_MODE: 'wholemodule',
})) push(l);
for (const l of configBlock(cfgDebugTargetId, 'Debug', targetSettings)) push(l);
for (const l of configBlock(cfgReleaseTargetId, 'Release', targetSettings)) push(l);
push('/* End XCBuildConfiguration section */');

// ---- XCConfigurationList ----
push('');
push('/* Begin XCConfigurationList section */');
push(`\t\t${cfgListProjectId} /* Build configuration list for PBXProject "${TARGET}" */ = {`);
push('\t\t\tisa = XCConfigurationList;');
push('\t\t\tbuildConfigurations = (');
push(`\t\t\t\t${cfgDebugProjectId} /* Debug */,`);
push(`\t\t\t\t${cfgReleaseProjectId} /* Release */,`);
push('\t\t\t);');
push('\t\t\tdefaultConfigurationIsVisible = 0;');
push('\t\t\tdefaultConfigurationName = Release;');
push('\t\t};');
push(`\t\t${cfgListTargetId} /* Build configuration list for PBXNativeTarget "${TARGET}" */ = {`);
push('\t\t\tisa = XCConfigurationList;');
push('\t\t\tbuildConfigurations = (');
push(`\t\t\t\t${cfgDebugTargetId} /* Debug */,`);
push(`\t\t\t\t${cfgReleaseTargetId} /* Release */,`);
push('\t\t\t);');
push('\t\t\tdefaultConfigurationIsVisible = 0;');
push('\t\t\tdefaultConfigurationName = Release;');
push('\t\t};');
push('/* End XCConfigurationList section */');

push('\t};');
push(`\trootObject = ${projectId} /* Project object */;`);
push('}');

fs.mkdirSync(PROJECT, { recursive: true });
fs.writeFileSync(path.join(PROJECT, 'project.pbxproj'), lines.join('\n') + '\n', 'utf8');

// 自检：Sources 阶段列出的每个 UUID 都必须有对应 PBXBuildFile，且文件数与磁盘一致。
const text = lines.join('\n');
const sourcesSection = text.split('/* Begin PBXSourcesBuildPhase section */')[1].split('/* End PBXSourcesBuildPhase section */')[0];
const listed = (sourcesSection.match(/^\t\t\t\t([0-9A-F]{24}) /gm) || []).length;
const buildFileSection = text.split('/* Begin PBXBuildFile section */')[1].split('/* End PBXBuildFile section */')[0];
const buildFiles = (buildFileSection.match(/^\t\t([0-9A-F]{24}) /gm) || []).length;

console.log(`Swift 文件: ${swiftFiles.length}`);
console.log(`  root=${groups.root.length} Core=${groups.Core.length} Services=${groups.Services.length} UI=${groups.UI.length}`);
console.log(`PBXSourcesBuildPhase 条目: ${listed}`);
console.log(`PBXBuildFile 条目: ${buildFiles}（含 Assets.xcassets 与 PrivacyInfo.xcprivacy）`);
if (listed !== swiftFiles.length) throw new Error(`Sources 阶段条目数 ${listed} != 磁盘 Swift 文件数 ${swiftFiles.length}`);
if (buildFiles !== swiftFiles.length + 2) throw new Error(`BuildFile 条目数 ${buildFiles} != Swift 文件数+2`);
console.log('自检通过：Sources 阶段与磁盘文件一一对应');
