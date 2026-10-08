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

app_target = project.new_target(:application, "Breaks", :ios, "17.2")
monitor_target = project.new_target(:app_extension, "BreakDeviceActivityMonitor", :ios, "17.2")
shield_config_target = project.new_target(:app_extension, "BreakShieldConfiguration", :ios, "17.2")
shield_action_target = project.new_target(:app_extension, "BreakShieldAction", :ios, "17.2")
widget_target = project.new_target(:app_extension, "BreakLiveActivity", :ios, "17.2")
tests_target = project.new_target(:unit_test_bundle, "BreaksTests", :ios, "17.2")

[app_target, monitor_target, shield_config_target, shield_action_target, widget_target, tests_target].each do |target|
  project.root_object.attributes["TargetAttributes"][target.uuid] = {
    "CreatedOnToolsVersion" => "26.4"
  }
end

COMMON_SETTINGS = {
  "SWIFT_VERSION" => "5.0",
  "CLANG_ENABLE_MODULES" => "YES",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "SWIFT_EMIT_LOC_STRINGS" => "NO",
  "PRODUCT_NAME" => "$(TARGET_NAME)",
  "IPHONEOS_DEPLOYMENT_TARGET" => "17.2",
  "TARGETED_DEVICE_FAMILY" => "1,2",
  "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator",
  "SUPPORTS_MACCATALYST" => "NO",
  "MARKETING_VERSION" => "0.1.0",
  "CURRENT_PROJECT_VERSION" => "1",
  "DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING" => "YES"
}.freeze

def apply_settings(target, settings)
  target.build_configurations.each do |config|
    COMMON_SETTINGS.each { |key, value| config.build_settings[key] = value }
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
shared_files["BreakActivityAttributes.swift"] = [app_target, widget_target]
shared_files["BreakActivityCoordinator.swift"] = [app_target]
shared_files["NotificationCoordinator.swift"] = [app_target]
shared_files["ScreenTimeCoordinator.swift"] = [app_target]
shared_files["ShortcutAutomationCoordinator.swift"] = [app_target]
shared_files["BreakSoundCoordinator.swift"] = [app_target]
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
add_sources(tests_group, tests_target, ["BreaksTests.swift"])

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

project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, tests_target, launch_target: true)
scheme.save_as(project_path, "Breaks", true)
