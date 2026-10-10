require "xcodeproj"
require "fileutils"

project_path = File.join(__dir__, "Clipboard.xcodeproj")
FileUtils.rm_rf(project_path) if File.exist?(project_path)
project = Xcodeproj::Project.new(project_path)

project.root_object.attributes["LastSwiftUpdateCheck"] = "2640"
project.root_object.attributes["LastUpgradeCheck"] = "2640"
project.root_object.attributes["TargetAttributes"] = {}

main_group = project.main_group
shared_group = main_group.new_group("Shared", "Shared")
models_group = shared_group.new_group("Models", "Models")
services_group = shared_group.new_group("Services", "Services")
views_group = shared_group.new_group("Views", "Views")
mac_group = main_group.new_group("MacApp", "MacApp")
ios_group = main_group.new_group("iOSApp", "iOSApp")
keyboard_group = main_group.new_group("KeyboardExtension", "KeyboardExtension")

COMMON_SETTINGS = {
  "SWIFT_VERSION" => "6.0",
  "CLANG_ENABLE_MODULES" => "YES",
  "DEFINES_MODULE" => "YES",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "SWIFT_EMIT_LOC_STRINGS" => "NO",
  "PRODUCT_NAME" => "$(TARGET_NAME)"
}.freeze

def apply_common_settings(target)
  target.build_configurations.each do |config|
    COMMON_SETTINGS.each { |key, value| config.build_settings[key] = value }
    yield(config)
  end
end

def add_source_files(group, file_names, targets)
  file_names.each do |name|
    ref = group.new_file(name)
    targets.each do |target|
      target.add_file_references([ref])
    end
  end
end

def add_project_files(group, file_names)
  file_names.each do |name|
    group.new_file(name)
  end
end

def save_shared_scheme(project_path, target)
  scheme = Xcodeproj::XCScheme.new
  scheme.configure_with_targets(target, nil, launch_target: true)
  scheme.save_as(project_path, target.name, true)
end

mac_target = project.new_target(:application, "ClipboardMac", :osx, "14.0")
ios_target = project.new_target(:application, "ClipboardiOS", :ios, "17.0")
keyboard_target = project.new_target(:app_extension, "ClipboardKeyboardExtension", :ios, "17.0")

[mac_target, ios_target, keyboard_target].each do |target|
  project.root_object.attributes["TargetAttributes"][target.uuid] = {
    "CreatedOnToolsVersion" => "16.4"
  }
end

apply_common_settings(mac_target) do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.clipboard.macos"
  config.build_settings["PRODUCT_NAME"] = "Clipboard"
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["INFOPLIST_FILE"] = "MacApp/macOS-Info.plist"
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/../Frameworks"]
  config.build_settings["MARKETING_VERSION"] = "1.0.0"
  config.build_settings["CURRENT_PROJECT_VERSION"] = "1"
  config.build_settings["SUPPORTED_PLATFORMS"] = "macosx"
end

apply_common_settings(ios_target) do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.clipboard.ios"
  config.build_settings["PRODUCT_NAME"] = "Clipboard"
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["INFOPLIST_FILE"] = "iOSApp/iOS-Info.plist"
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
  config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks"]
  config.build_settings["MARKETING_VERSION"] = "1.0.0"
  config.build_settings["CURRENT_PROJECT_VERSION"] = "1"
  config.build_settings["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
  config.build_settings["CODE_SIGN_ENTITLEMENTS"] = "iOSApp/ClipboardiOS.entitlements"
end

apply_common_settings(keyboard_target) do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.clipboard.ios.keyboard"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["INFOPLIST_FILE"] = "KeyboardExtension/Keyboard-Info.plist"
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
  config.build_settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
  config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]
  config.build_settings["MARKETING_VERSION"] = "1.0.0"
  config.build_settings["CURRENT_PROJECT_VERSION"] = "1"
  config.build_settings["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
  config.build_settings["SKIP_INSTALL"] = "YES"
  config.build_settings["CODE_SIGN_ENTITLEMENTS"] = "KeyboardExtension/ClipboardKeyboard.entitlements"
end

mac_tests_target = project.new_target(:unit_test_bundle, "ClipboardMacTests", :osx, "14.0")
mac_tests_target.add_dependency(mac_target)
project.root_object.attributes["TargetAttributes"][mac_tests_target.uuid] = {
  "CreatedOnToolsVersion" => "26.4",
  "TestTargetID" => mac_target.uuid
}
mac_tests_target.build_configurations.each do |config|
  config.build_settings["SWIFT_VERSION"] = "6.0"
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.clipboard.macos.tests"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/Clipboard.app/Contents/MacOS/Clipboard"
  config.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  config.build_settings["CODE_SIGNING_ALLOWED"] = "NO"
end

ios_target.add_dependency(keyboard_target)
embed_extensions_phase = ios_target.new_copy_files_build_phase("Embed App Extensions")
embed_extensions_phase.dst_subfolder_spec = "13"
embed_build_file = embed_extensions_phase.add_file_reference(keyboard_target.product_reference)
embed_build_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }

model_files = %w[
  ClipboardItem.swift
]

shared_service_files = %w[
  ClipboardAutoSync.swift
  ClipboardHistoryStore.swift
  KeyboardSetupState.swift
  SharedContainer.swift
]

mobile_service_files = %w[
  MobileClipboardManager.swift
]

keyboard_service_files = %w[
  KeyboardClipboardController.swift
]

shared_view_files = %w[
  MobileClipboardShelf.swift
]

mac_service_files = %w[
  ActiveAppPasteService.swift
  ClipboardManager.swift
  ClipboardMonitor.swift
  GlobalShortcutMonitor.swift
]

mac_files = %w[
  ClipboardAppController.swift
  ClipboardHistoryPanel.swift
  ClipboardMacApp.swift
  ClipboardPanel.swift
  ClipboardPanelController.swift
  ClipboardPanelRow.swift
  StatusBarController.swift
]

ios_files = %w[
  ClipboardiOSApp.swift
  IOSClipboardHostView.swift
]

keyboard_files = %w[
  ClipboardKeyboardRootView.swift
  ClipboardKeyboardViewController.swift
]

add_source_files(models_group, model_files, [mac_target, ios_target, keyboard_target])
add_source_files(services_group, shared_service_files, [mac_target, ios_target, keyboard_target])
add_source_files(services_group, mobile_service_files, [ios_target])
add_source_files(services_group, keyboard_service_files, [keyboard_target])
add_source_files(views_group, shared_view_files, [ios_target, keyboard_target])
add_source_files(services_group, mac_service_files, [mac_target])
add_source_files(mac_group, mac_files, [mac_target])
add_source_files(ios_group, ios_files, [ios_target])
add_source_files(keyboard_group, keyboard_files, [keyboard_target])

mac_target.resources_build_phase.add_file_reference(mac_group.new_file("Assets.xcassets"))
ios_target.resources_build_phase.add_file_reference(ios_group.new_file("Assets.xcassets"))

tests_group = main_group.new_group("Tests", "Tests")
mac_tests_target.add_file_references([tests_group.new_file("ClipboardMacTests.swift")])

add_project_files(mac_group, ["macOS-Info.plist"])
add_project_files(ios_group, ["iOS-Info.plist", "ClipboardiOS.entitlements"])
add_project_files(keyboard_group, ["Keyboard-Info.plist", "ClipboardKeyboard.entitlements"])

# xcodeproj adds platform frameworks (Cocoa, Foundation, UIKit) under DEVELOPER_DIR with pinned
# SDK versions; resolve them through each target's selected SDK instead.
project.files.each do |ref|
  path = ref.path.to_s
  next unless path.include?(".sdk/System/Library/Frameworks/")
  ref.path = path.sub(%r{\A.*\.sdk/}, "")
  ref.source_tree = "SDKROOT"
end

project.save

mac_scheme = Xcodeproj::XCScheme.new
mac_scheme.configure_with_targets(mac_target, mac_tests_target, launch_target: true)
mac_scheme.save_as(project_path, mac_target.name, true)

save_shared_scheme(project_path, ios_target)

# A keyboard extension cannot be launched on its own; its scheme only builds it. Run
# ClipboardiOS and switch to the keyboard to try it.
keyboard_scheme = Xcodeproj::XCScheme.new
keyboard_scheme.configure_with_targets(keyboard_target, nil, launch_target: false)
keyboard_scheme.save_as(project_path, keyboard_target.name, true)
