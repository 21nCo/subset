# Regenerates Record.xcodeproj. Run from this directory: `ruby ProjectGenerator.rb`.
# Requires the `xcodeproj` gem.
require "xcodeproj"

project_path = File.join(__dir__, "Record.xcodeproj")
project = Xcodeproj::Project.new(project_path)

project.root_object.attributes["LastSwiftUpdateCheck"] = "1640"
project.root_object.attributes["LastUpgradeCheck"] = "1640"
project.root_object.attributes["TargetAttributes"] = {}

main_group = project.main_group
shared_group = main_group.new_group("Shared", "Shared")
ios_group = main_group.new_group("iOSApp", "iOSApp")
mac_group = main_group.new_group("MacApp", "MacApp")
widget_group = main_group.new_group("WidgetExtension", "WidgetExtension")

ios_target = project.new_target(:application, "RecordiOS", :ios, "17.0")
mac_target = project.new_target(:application, "RecordMac", :osx, "14.0")
widget_target = project.new_target(:app_extension, "RecordWidgetExtension", :ios, "17.0")

[ios_target, mac_target, widget_target].each do |target|
  project.root_object.attributes["TargetAttributes"][target.uuid] = { "CreatedOnToolsVersion" => "16.4" }
end

COMMON_SETTINGS = {
  "SWIFT_VERSION" => "6.0",
  "CLANG_ENABLE_MODULES" => "YES",
  "DEFINES_MODULE" => "YES",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "SWIFT_EMIT_LOC_STRINGS" => "NO",
  "MARKETING_VERSION" => "0.1.0",
  "CURRENT_PROJECT_VERSION" => "1",
  "GENERATE_INFOPLIST_FILE" => "NO"
}.freeze

def apply_settings(target, settings)
  target.build_configurations.each do |config|
    COMMON_SETTINGS.merge(settings).each { |key, value| config.build_settings[key] = value }
  end
end

apply_settings(
  ios_target,
  "PRODUCT_NAME" => "Record",
  "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.record.ios",
  "INFOPLIST_FILE" => "iOSApp/iOS-Info.plist",
  "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
  "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
  "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
  "TARGETED_DEVICE_FAMILY" => "1,2",
  "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator"
)

apply_settings(
  mac_target,
  "PRODUCT_NAME" => "Record",
  "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.record",
  "INFOPLIST_FILE" => "MacApp/macOS-Info.plist",
  # Hardened runtime (required for notarization) blocks the microphone without this entitlement.
  "CODE_SIGN_ENTITLEMENTS" => "MacApp/Record-macOS.entitlements",
  "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
  "MACOSX_DEPLOYMENT_TARGET" => "14.0",
  "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/../Frameworks"],
  "SUPPORTED_PLATFORMS" => "macosx"
)

apply_settings(
  widget_target,
  "PRODUCT_NAME" => "RecordWidgetExtension",
  "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.record.ios.widget",
  "INFOPLIST_FILE" => "WidgetExtension/Widget-Info.plist",
  "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
  "APPLICATION_EXTENSION_API_ONLY" => "YES",
  "SKIP_INSTALL" => "YES",
  "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME" => "",
  "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
  "TARGETED_DEVICE_FAMILY" => "1,2",
  "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator"
)

shared_files = {
  "DurationFormatting.swift" => [ios_target, mac_target, widget_target],
  "WaveformView.swift" => [ios_target, mac_target, widget_target],
  "RecordingDashboardView.swift" => [ios_target, mac_target],
  "RecordingManager.swift" => [ios_target, mac_target],
  "RecordingActivityAttributes.swift" => [ios_target, widget_target],
  "RecordingActivityBridge.swift" => [ios_target],
  "FloatingWindowConfigurator.swift" => [mac_target]
}

shared_files.each do |name, targets|
  ref = shared_group.new_file(name)
  targets.each { |target| target.add_file_references([ref]) }
end

ios_target.add_file_references([ios_group.new_file("RecordiOSApp.swift")])
ios_group.new_file("iOS-Info.plist")
ios_target.add_resources([
  ios_group.new_file("Sounds/silent.caf"),
  ios_group.new_file("Assets.xcassets")
])

mac_refs = %w[
  RecordMacApp.swift
  MacRootView.swift
  FloatingRecorderView.swift
  FloatingRecorderPanelController.swift
].map { |name| mac_group.new_file(name) }
mac_target.add_file_references(mac_refs)
mac_group.new_file("macOS-Info.plist")
mac_group.new_file("Record-macOS.entitlements")
mac_target.add_resources([mac_group.new_file("Assets.xcassets")])

widget_refs = %w[RecordWidgetBundle.swift RecordingLiveActivityWidget.swift].map { |name| widget_group.new_file(name) }
widget_target.add_file_references(widget_refs)
widget_group.new_file("Widget-Info.plist")

ios_target.add_dependency(widget_target)
embed_phase = ios_target.new_copy_files_build_phase("Embed App Extensions")
embed_phase.symbol_dst_subfolder_spec = :plug_ins
embed_file = embed_phase.add_file_reference(widget_target.product_reference)
embed_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }

project.save

{ "Record-iOS" => ios_target, "Record-macOS" => mac_target }.each do |scheme_name, target|
  scheme = Xcodeproj::XCScheme.new
  scheme.configure_with_targets(target, nil, launch_target: true)
  scheme.save_as(project_path, scheme_name, true)
end
