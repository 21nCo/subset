# Regenerates Breaks.xcodeproj. Run from this directory: `ruby ProjectGenerator.rb`.
# Requires the `xcodeproj` gem.
require "xcodeproj"
require "fileutils"

project_path = File.join(__dir__, "Breaks.xcodeproj")
FileUtils.rm_rf(project_path)
project = Xcodeproj::Project.new(project_path)

project.root_object.attributes["LastSwiftUpdateCheck"] = "2640"
project.root_object.attributes["LastUpgradeCheck"] = "2640"
project.root_object.attributes["TargetAttributes"] = {}

main_group = project.main_group
app_group = main_group.new_group("App", "App")
shared_group = main_group.new_group("Shared", "Shared")
monitor_group = main_group.new_group("DeviceActivityMonitor", "DeviceActivityMonitor")
shield_config_group = main_group.new_group("ShieldConfiguration", "ShieldConfiguration")
shield_action_group = main_group.new_group("ShieldAction", "ShieldAction")
widget_group = main_group.new_group("WidgetExtension", "WidgetExtension")
tests_group = main_group.new_group("Tests", "Tests")
mac_group = main_group.new_group("Mac", "Mac")

app_target = project.new_target(:application, "Breaks", :ios, "17.2")
monitor_target = project.new_target(:app_extension, "BreakDeviceActivityMonitor", :ios, "17.2")
shield_config_target = project.new_target(:app_extension, "BreakShieldConfiguration", :ios, "17.2")
shield_action_target = project.new_target(:app_extension, "BreakShieldAction", :ios, "17.2")
widget_target = project.new_target(:app_extension, "BreakLiveActivity", :ios, "17.2")
tests_target = project.new_target(:unit_test_bundle, "BreaksTests", :ios, "17.2")
mac_target = project.new_target(:application, "BreaksMac", :osx, "14.0")
mac_tests_target = project.new_target(:unit_test_bundle, "BreaksMacTests", :osx, "14.0")

[app_target, monitor_target, shield_config_target, shield_action_target, widget_target, tests_target, mac_target, mac_tests_target].each do |target|
  project.root_object.attributes["TargetAttributes"][target.uuid] = {
    "CreatedOnToolsVersion" => "26.4"
  }
end

BASE_SETTINGS = {
  "SWIFT_VERSION" => "5.0",
  "CLANG_ENABLE_MODULES" => "YES",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "SWIFT_EMIT_LOC_STRINGS" => "NO",
  "PRODUCT_NAME" => "$(TARGET_NAME)",
  "MARKETING_VERSION" => "0.1.0",
  "CURRENT_PROJECT_VERSION" => "1",
  "DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING" => "YES"
}.freeze

COMMON_SETTINGS = BASE_SETTINGS.merge(
  "IPHONEOS_DEPLOYMENT_TARGET" => "17.2",
  "TARGETED_DEVICE_FAMILY" => "1,2",
  "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator",
  "SUPPORTS_MACCATALYST" => "NO"
).freeze

MAC_SETTINGS = BASE_SETTINGS.merge(
  "MACOSX_DEPLOYMENT_TARGET" => "14.0",
  "SUPPORTED_PLATFORMS" => "macosx"
).freeze

def apply_settings(target, settings, base = COMMON_SETTINGS)
  target.build_configurations.each do |config|
    base.each { |key, value| config.build_settings[key] = value }
    settings.each { |key, value| config.build_settings[key] = value }
  end
end

apply_settings(
  app_target,
  "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.breaks",
  "GENERATE_INFOPLIST_FILE" => "NO",
  "INFOPLIST_FILE" => "App/Info.plist",
  "CODE_SIGN_ENTITLEMENTS" => "App/Breaks.entitlements",
  "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
  "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME" => "AccentColor",
  "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"]
)

extension_settings = lambda do |bundle_id, plist, entitlements|
  {
    "PRODUCT_BUNDLE_IDENTIFIER" => bundle_id,
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => plist,
    "CODE_SIGN_ENTITLEMENTS" => entitlements,
    "APPLICATION_EXTENSION_API_ONLY" => "YES",
    "SKIP_INSTALL" => "YES",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]
  }
end

apply_settings(monitor_target, extension_settings.call("dev.subset.breaks.DeviceActivity", "DeviceActivityMonitor/Info.plist", "DeviceActivityMonitor/DeviceActivityMonitor.entitlements"))
apply_settings(shield_config_target, extension_settings.call("dev.subset.breaks.ShieldConfiguration", "ShieldConfiguration/Info.plist", "ShieldConfiguration/ShieldConfiguration.entitlements"))
apply_settings(shield_action_target, extension_settings.call("dev.subset.breaks.ShieldAction", "ShieldAction/Info.plist", "ShieldAction/ShieldAction.entitlements"))
apply_settings(widget_target, extension_settings.call("dev.subset.breaks.LiveActivity", "WidgetExtension/Info.plist", "WidgetExtension/WidgetExtension.entitlements"))

apply_settings(
  tests_target,
  "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.breaks.Tests",
  "GENERATE_INFOPLIST_FILE" => "YES",
  "BUNDLE_LOADER" => "$(TEST_HOST)",
  "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/Breaks.app/Breaks"
)

# macOS menu bar app. PRODUCT_NAME is "Breaks" so the bundle is Breaks.app; the module is BreaksMac so it
# cannot be confused with the iOS module. It shares the iOS bundle identifier, as a separate-platform app.
apply_settings(
  mac_target,
  {
    "PRODUCT_NAME" => "Breaks",
    "PRODUCT_MODULE_NAME" => "BreaksMac",
    "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.breaks",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => "Mac/Info.plist",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME" => "AccentColor",
    "ENABLE_HARDENED_RUNTIME" => "YES",
    "COMBINE_HIDPI_IMAGES" => "YES",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/../Frameworks"]
  },
  MAC_SETTINGS
)
mac_target.product_reference.path = "Breaks.app"
mac_target.product_reference.name = "Breaks.app"

# Hostless unit tests: the bundle compiles the shared domain sources directly.
apply_settings(
  mac_tests_target,
  {
    "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.breaks.MacTests",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"]
  },
  MAC_SETTINGS
)

def add_sources(group, target, names)
  names.each do |name|
    reference = group.new_file(name)
    target.add_file_references([reference])
  end
end

shared_files = {}
%w[
  BreakModels.swift
  BreakPersistence.swift
  ScreenTimeNames.swift
].each { |name| shared_files[name] = [app_target, monitor_target, shield_config_target] }
shared_files["BreakModels.swift"] += [mac_target, mac_tests_target]
shared_files["BreakPersistence.swift"] += [mac_target, mac_tests_target]
shared_files["BreakScheduler.swift"] = [app_target, mac_target, mac_tests_target]
shared_files["BreakActivityAttributes.swift"] = [app_target, widget_target]
shared_files["BreakActivityCoordinator.swift"] = [app_target]
shared_files["NotificationCoordinator.swift"] = [app_target]
shared_files["ScreenTimeCoordinator.swift"] = [app_target]
shared_files["ShortcutAutomationCoordinator.swift"] = [app_target]
shared_files["BreakSoundCoordinator.swift"] = [app_target, mac_target]
shared_files["BreakEngine.swift"] = [app_target]

shared_files.each do |name, targets|
  reference = shared_group.new_file(name)
  targets.each { |target| target.add_file_references([reference]) }
end

add_sources(app_group, app_target, %w[
  BreaksApp.swift
  BreakAppIntents.swift
  AppTheme.swift
  RootView.swift
  OnboardingView.swift
  DashboardView.swift
  BreakExperienceView.swift
  BreaksView.swift
  StatsView.swift
  SettingsView.swift
])
add_sources(monitor_group, monitor_target, ["DeviceActivityMonitorExtension.swift"])
add_sources(shield_config_group, shield_config_target, ["ShieldConfigurationExtension.swift"])
add_sources(shield_action_group, shield_action_target, ["ShieldActionExtension.swift"])
add_sources(widget_group, widget_target, %w[BreakReminderWidgetBundle.swift BreakLiveActivityWidget.swift])
%w[BreaksTests.swift BreakSchedulerTests.swift].each do |name|
  reference = tests_group.new_file(name)
  [tests_target, mac_tests_target].each { |target| target.add_file_references([reference]) }
end
add_sources(mac_group, mac_target, %w[
  BreaksMacApp.swift
  MacBreakController.swift
  ActivitySignals.swift
  BreakOverlay.swift
  FloatingPanels.swift
  MacSettingsView.swift
])
mac_assets = mac_group.new_file("Assets.xcassets")
mac_target.resources_build_phase.add_file_reference(mac_assets)

assets = app_group.new_file("Assets.xcassets")
app_target.resources_build_phase.add_file_reference(assets)
ambient = app_group.new_file("Resources/AmbientBreak.png")
app_target.resources_build_phase.add_file_reference(ambient)

embed_phase = app_target.new_copy_files_build_phase("Embed App Extensions")
embed_phase.symbol_dst_subfolder_spec = :plug_ins
[monitor_target, shield_config_target, shield_action_target, widget_target].each do |target|
  app_target.add_dependency(target)
  embed_phase.add_file_reference(target.product_reference)
end
tests_target.add_dependency(app_target)

# The gem points Foundation at one fixed iOS SDK version under DEVELOPER_DIR; make it relative to each
# target's SDK so the path exists on any Xcode.
project.files.select { |ref| ref.path.to_s.end_with?("Foundation.framework") }.each do |ref|
  ref.path = "System/Library/Frameworks/Foundation.framework"
  ref.source_tree = "SDKROOT"
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, tests_target, launch_target: true)
scheme.save_as(project_path, "Breaks", true)

mac_scheme = Xcodeproj::XCScheme.new
mac_scheme.configure_with_targets(mac_target, mac_tests_target, launch_target: true)
mac_scheme.save_as(project_path, "BreaksMac", true)
