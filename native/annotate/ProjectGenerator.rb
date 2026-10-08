require "xcodeproj"
require "fileutils"

# Regenerates Annotate.xcodeproj. The POC shipped a hand-written project; this keeps its
# settings (iOS 17, iPhone and iPad, Mac Catalyst) and adds an asset catalog and tests.
project_path = File.join(__dir__, "Annotate.xcodeproj")
FileUtils.rm_rf(project_path) if File.exist?(project_path)
project = Xcodeproj::Project.new(project_path)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2640"
project.root_object.attributes["LastUpgradeCheck"] = "2640"
project.root_object.attributes["TargetAttributes"] = {}

app_group = project.main_group.new_group("Annotate", "Annotate")
feature_group = app_group.new_group("Features", "Features").new_group("PDFAnnotation", "PDFAnnotation")
tests_group = project.main_group.new_group("Tests", "Tests")

app = project.new_target(:application, "Annotate", :ios, "17.0")
tests = project.new_target(:unit_test_bundle, "AnnotateTests", :ios, "17.0")
tests.add_dependency(app)
project.root_object.attributes["TargetAttributes"][app.uuid] = { "CreatedOnToolsVersion" => "26.4" }
project.root_object.attributes["TargetAttributes"][tests.uuid] = {
  "CreatedOnToolsVersion" => "26.4",
  "TestTargetID" => app.uuid
}

common = {
  "SWIFT_VERSION" => "5.0",
  "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
  "MACOSX_DEPLOYMENT_TARGET" => "14.0",
  "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator",
  "SUPPORTS_MACCATALYST" => "YES",
  "TARGETED_DEVICE_FAMILY" => "1,2",
  "CLANG_ENABLE_MODULES" => "YES",
  "SWIFT_EMIT_LOC_STRINGS" => "YES"
}.freeze

app.build_configurations.each do |config|
  common.each { |key, value| config.build_settings[key] = value }
  config.build_settings.merge!(
    "PRODUCT_NAME" => "Annotate",
    "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.annotate",
    "CODE_SIGN_STYLE" => "Automatic",
    "MARKETING_VERSION" => "1.0",
    "CURRENT_PROJECT_VERSION" => "1",
    "ENABLE_PREVIEWS" => "YES",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "INFOPLIST_KEY_CFBundleDisplayName" => "Annotate",
    "INFOPLIST_KEY_LSApplicationCategoryType" => "public.app-category.productivity",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation" => "YES",
    "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents" => "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation" => "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad" => "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone" => "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"]
  )
end

tests.build_configurations.each do |config|
  common.each { |key, value| config.build_settings[key] = value }
  config.build_settings.merge!(
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.annotate.tests",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/Annotate.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Annotate",
    "BUNDLE_LOADER" => "$(TEST_HOST)",
    "CODE_SIGNING_ALLOWED" => "NO"
  )
end

%w[AnnotateApp.swift ContentView.swift].each { |name| app.add_file_references([app_group.new_file(name)]) }
%w[PDFAnnotatorView.swift PDFDocumentStore.swift].each { |name| app.add_file_references([feature_group.new_file(name)]) }
app.resources_build_phase.add_file_reference(app_group.new_file("Assets.xcassets"))
tests.add_file_references([tests_group.new_file("AnnotateTests.swift")])

project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests, launch_target: true)
scheme.save_as(project_path, "Annotate", true)
puts "Generated #{project_path}"
