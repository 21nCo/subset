require "xcodeproj"
require "fileutils"

project_path = File.join(__dir__, "Launcher.xcodeproj")
# Keep the SwiftPM pin across regeneration; removing the project would otherwise drop it.
resolved_path = File.join(project_path, "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
resolved = File.exist?(resolved_path) ? File.read(resolved_path) : nil
project = Xcodeproj::Project.new(project_path)

project.root_object.attributes["LastSwiftUpdateCheck"] = "2640"
project.root_object.attributes["LastUpgradeCheck"] = "2640"
project.root_object.attributes["TargetAttributes"] = {}

main_group = project.main_group
mac_group = main_group.new_group("MacApp", "MacApp")
shared_group = main_group.new_group("Shared", "Shared")
models_group = shared_group.new_group("Models", "Models")
services_group = shared_group.new_group("Services", "Services")
views_group = shared_group.new_group("Views", "Views")
tests_group = main_group.new_group("Tests", "Tests")

mac_target = project.new_target(:application, "Launcher", :osx, "14.0")
test_target = project.new_target(:unit_test_bundle, "LauncherTests", :osx, "14.0")
test_target.add_dependency(mac_target)

# new_target links Cocoa through a DEVELOPER_DIR path pinned to one macOS SDK version.
# The frameworks the app needs are added below relative to SDKROOT instead.
[mac_target, test_target].each { |target| target.frameworks_build_phase.files.to_a.each(&:remove_from_project) }
project.frameworks_group.recursive_children.select { |child| child.isa == "PBXFileReference" }.each(&:remove_from_project)
project.frameworks_group.groups.each(&:remove_from_project)
project.root_object.attributes["TargetAttributes"][mac_target.uuid] = {
  "CreatedOnToolsVersion" => "26.4"
}
project.root_object.attributes["TargetAttributes"][test_target.uuid] = {
  "CreatedOnToolsVersion" => "26.4",
  "TestTargetID" => mac_target.uuid
}

# EmojiKit (MIT, https://github.com/danielsaidi/EmojiKit) supplies the emoji catalog.
emoji_kit_package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
emoji_kit_package.repositoryURL = "https://github.com/danielsaidi/EmojiKit.git"
emoji_kit_package.requirement = {
  "kind" => "upToNextMajorVersion",
  "minimumVersion" => "2.4.0"
}
project.root_object.package_references << emoji_kit_package

emoji_kit_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
emoji_kit_product.product_name = "EmojiKit"
emoji_kit_product.package = emoji_kit_package
mac_target.package_product_dependencies << emoji_kit_product

COMMON_SETTINGS = {
  "SWIFT_VERSION" => "6.0",
  "CLANG_ENABLE_MODULES" => "YES",
  "DEFINES_MODULE" => "YES",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "SWIFT_EMIT_LOC_STRINGS" => "NO",
  "MACOSX_DEPLOYMENT_TARGET" => "14.0",
  "SUPPORTED_PLATFORMS" => "macosx"
}.freeze

mac_target.build_configurations.each do |config|
  COMMON_SETTINGS.each { |key, value| config.build_settings[key] = value }
  config.build_settings["PRODUCT_NAME"] = "Launcher"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.launcher"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["INFOPLIST_FILE"] = "MacApp/macOS-Info.plist"
  config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/../Frameworks"]
  config.build_settings["MARKETING_VERSION"] = "1.0"
  config.build_settings["CURRENT_PROJECT_VERSION"] = "1"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  # The asset catalog has no AccentColor set.
  config.build_settings.delete("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME")
  # Hardened runtime (required for notarization) blocks Apple Events to System Events without this.
  config.build_settings["CODE_SIGN_ENTITLEMENTS"] = "MacApp/Launcher.entitlements"
end

test_target.build_configurations.each do |config|
  COMMON_SETTINGS.each { |key, value| config.build_settings[key] = value }
  config.build_settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.launcher.tests"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/Launcher.app/Contents/MacOS/Launcher"
  config.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  config.build_settings["CODE_SIGNING_ALLOWED"] = "NO"
end

def add_files(group, target, names)
  names.each do |name|
    target.add_file_references([group.new_file(name)])
  end
end

add_files(mac_group, mac_target, %w[
  AppDelegate.swift
  AvatarWindowController.swift
  LauncherApp.swift
  LauncherIntentBridge.swift
  LauncherPanelController.swift
  QuickNotesWindowController.swift
  StatusBarController.swift
])
add_files(models_group, mac_target, %w[
  LauncherModels.swift
  QuickNote.swift
])
add_files(services_group, mac_target, %w[
  AppSearchService.swift
  Collection+Uniqued.swift
  EmojiAnnotationIndex.swift
  EmojiSearchService.swift
  FileSearchService.swift
  GlobalShortcutMonitor.swift
  LauncherAppState.swift
  PersistenceController.swift
  ShortcutSearchService.swift
  WindowManagementService.swift
])
add_files(views_group, mac_target, %w[
  AvatarView.swift
  LauncherView.swift
  QuickNotesView.swift
])
add_files(tests_group, test_target, %w[LauncherTests.swift])
mac_target.resources_build_phase.add_file_reference(mac_group.new_file("Assets.xcassets"))
mac_group.new_file("macOS-Info.plist")
mac_group.new_file("Launcher.entitlements")
# Third-party license notices ship inside the app bundle (Contents/Resources).
mac_target.resources_build_phase.add_file_reference(mac_group.new_file("EmojiKit-LICENSE.txt"))
mac_target.resources_build_phase.add_file_reference(services_group.new_file("EmojiAnnotationIndex-LICENSE.txt"))

frameworks = mac_target.frameworks_build_phase
%w[AppIntents.framework AppKit.framework Carbon.framework CoreData.framework SwiftUI.framework].each do |framework|
  file_ref = project.frameworks_group.new_file("System/Library/Frameworks/#{framework}", :sdk_root)
  frameworks.add_file_reference(file_ref)
end
emoji_kit_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
emoji_kit_build_file.product_ref = emoji_kit_product
frameworks.files << emoji_kit_build_file

# Remove the old project only after generation has succeeded, so a failure leaves it intact.
FileUtils.rm_rf(project_path) if File.exist?(project_path)
project.save
if resolved
  FileUtils.mkdir_p(File.dirname(resolved_path))
  File.write(resolved_path, resolved)
end

scheme = Xcodeproj::XCScheme.new
scheme.doc.root.attributes["LastUpgradeVersion"] = "2640"
scheme.configure_with_targets(mac_target, test_target, launch_target: true)
scheme.save_as(project_path, "Launcher", true)

puts "Generated #{project_path}"
