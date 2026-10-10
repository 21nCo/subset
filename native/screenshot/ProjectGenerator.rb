require "xcodeproj"
require "fileutils"

project_path = File.join(__dir__, "Screenshot.xcodeproj")
FileUtils.rm_rf(project_path) if File.exist?(project_path)

project = Xcodeproj::Project.new(project_path)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2640"
project.root_object.attributes["LastUpgradeCheck"] = "2640"
project.root_object.attributes["TargetAttributes"] = {}

main_group = project.main_group
sources_group = main_group.new_group("Sources", "Sources")
mac_group = main_group.new_group("MacApp", "MacApp")
tests_group = main_group.new_group("Tests", "Tests")

app_target = project.new_target(:application, "Screenshot", :osx, "14.0")
test_target = project.new_target(:unit_test_bundle, "ScreenshotTests", :osx, "14.0")
test_target.add_dependency(app_target)

project.root_object.attributes["TargetAttributes"][app_target.uuid] = {
  "CreatedOnToolsVersion" => "26.4"
}
project.root_object.attributes["TargetAttributes"][test_target.uuid] = {
  "CreatedOnToolsVersion" => "26.4",
  "TestTargetID" => app_target.uuid
}

common_settings = {
  "SWIFT_VERSION" => "5.0",
  "CLANG_ENABLE_MODULES" => "YES",
  "DEFINES_MODULE" => "YES",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "SWIFT_EMIT_LOC_STRINGS" => "NO",
  "MACOSX_DEPLOYMENT_TARGET" => "14.0",
  "SUPPORTED_PLATFORMS" => "macosx",
  "SWIFT_STRICT_CONCURRENCY" => "minimal"
}.freeze

app_target.build_configurations.each do |config|
  common_settings.each { |key, value| config.build_settings[key] = value }
  config.build_settings.merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.screenshot",
    "PRODUCT_NAME" => "Screenshot",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => "MacApp/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/../Frameworks"],
    "MARKETING_VERSION" => "1.0.0",
    "CODE_SIGN_ENTITLEMENTS" => "MacApp/Screenshot.entitlements",
    "ENABLE_HARDENED_RUNTIME" => "YES",
    "CURRENT_PROJECT_VERSION" => "1",
    "CODE_SIGN_STYLE" => "Automatic",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS" => "YES",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon"
  )
end

test_target.build_configurations.each do |config|
  common_settings.each { |key, value| config.build_settings[key] = value }
  config.build_settings.merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.screenshot.tests",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/Screenshot.app/Contents/MacOS/Screenshot",
    "BUNDLE_LOADER" => "$(TEST_HOST)",
    "CODE_SIGNING_ALLOWED" => "NO"
  )
end

def add_swift_tree(group, target, root)
  Dir.glob(File.join(root, "**", "*.swift")).sort.each do |path|
    relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
    components = relative.split(File::SEPARATOR)
    filename = components.pop
    destination = components.reduce(group) do |current, component|
      current.groups.find { |candidate| candidate.display_name == component } ||
        current.new_group(component, component)
    end
    ref = destination.new_file(filename)
    target.add_file_references([ref])
  end
end

require "pathname"
add_swift_tree(sources_group, app_target, File.join(__dir__, "Sources"))
Dir.glob(File.join(__dir__, "MacApp", "*.swift")).sort.each do |path|
  ref = mac_group.new_file(File.basename(path))
  app_target.add_file_references([ref])
end
assets_ref = mac_group.new_file("Assets.xcassets")
app_target.resources_build_phase.add_file_reference(assets_ref)
Dir.glob(File.join(__dir__, "Tests", "*.swift")).sort.each do |path|
  ref = tests_group.new_file(File.basename(path))
  test_target.add_file_references([ref])
end

frameworks = %w[
  AppKit.framework
  AVFoundation.framework
  AVKit.framework
  Carbon.framework
  CoreGraphics.framework
  CoreImage.framework
  CoreMedia.framework
  CoreServices.framework
  ImageIO.framework
  ScreenCaptureKit.framework
  Security.framework
  SwiftUI.framework
  UniformTypeIdentifiers.framework
  Vision.framework
  VideoToolbox.framework
]

frameworks.each do |framework|
  ref = project.frameworks_group.new_file("System/Library/Frameworks/#{framework}")
  ref.source_tree = "SDKROOT"
  app_target.frameworks_build_phase.add_file_reference(ref)
end

# xcodeproj adds Cocoa.framework under DEVELOPER_DIR with a pinned SDK version; resolve it
# through the selected SDK instead so the project builds with any installed macOS SDK.
project.files.each do |ref|
  next unless ref.path.to_s.end_with?("Cocoa.framework")
  ref.path = "System/Library/Frameworks/Cocoa.framework"
  ref.source_tree = "SDKROOT"
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, test_target, launch_target: true)
scheme.save_as(project_path, "Screenshot", true)

puts "Generated #{project_path}"
