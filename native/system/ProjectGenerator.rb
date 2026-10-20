# Pin the gem CI installs: newer releases write a different preferredProjectObjectVersion, so a plain require would
# make the committed project depend on whichever xcodeproj the host happens to have.
gem "xcodeproj", "= 1.27.0"
require "xcodeproj"
require "fileutils"
require "tmpdir"

# Generates System.xcodeproj from the same sources as Package.swift: a static SystemCore library, the Subset System
# menu-bar app that links it, and the core unit tests. Run `ruby ProjectGenerator.rb` from this folder after adding
# or removing a source file; CI regenerates the project and fails if the committed copy differs.
Dir.chdir(__dir__)
project_path = File.join(__dir__, "System.xcodeproj")
project = Xcodeproj::Project.new(project_path, false, 46)
project.root_object.preferred_project_object_version = "77"

project.root_object.attributes["LastSwiftUpdateCheck"] = "2640"
project.root_object.attributes["LastUpgradeCheck"] = "2640"
project.root_object.attributes["TargetAttributes"] = {}

core_group = project.main_group.new_group("Core", "Core")
app_group = project.main_group.new_group("MacApp", "MacApp")
tests_group = project.main_group.new_group("Tests", "Tests/CoreTests")

core_target = project.new_target(:static_library, "SystemCore", :osx, "14.0")
app_target = project.new_target(:application, "SubsetSystem", :osx, "14.0")
test_target = project.new_target(:unit_test_bundle, "SystemCoreTests", :osx, "14.0")
app_target.add_dependency(core_target)
test_target.add_dependency(core_target)

# new_target links Cocoa through a DEVELOPER_DIR path pinned to one SDK version; frameworks are added relative to
# SDKROOT below instead.
[core_target, app_target, test_target].each { |target| target.frameworks_build_phase.files.to_a.each(&:remove_from_project) }
project.frameworks_group.recursive_children.select { |child| child.isa == "PBXFileReference" }.each(&:remove_from_project)
project.frameworks_group.groups.each(&:remove_from_project)
[app_target, test_target].each do |target|
  project.root_object.attributes["TargetAttributes"][target.uuid] = { "CreatedOnToolsVersion" => "26.4" }
end

COMMON_SETTINGS = {
  "SWIFT_VERSION" => "6.0",
  "CLANG_ENABLE_MODULES" => "YES",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "SWIFT_EMIT_LOC_STRINGS" => "NO",
  "MACOSX_DEPLOYMENT_TARGET" => "14.0",
  "SUPPORTED_PLATFORMS" => "macosx"
}.freeze

core_target.build_configurations.each do |config|
  COMMON_SETTINGS.each { |key, value| config.build_settings[key] = value }
  config.build_settings["PRODUCT_NAME"] = "SystemCore"
  config.build_settings["PRODUCT_MODULE_NAME"] = "SystemCore"
  config.build_settings["DEFINES_MODULE"] = "YES"
  # Only the app belongs in the release archive.
  config.build_settings["SKIP_INSTALL"] = "YES"
  config.build_settings["CODE_SIGNING_ALLOWED"] = "NO"
end

app_target.build_configurations.each do |config|
  COMMON_SETTINGS.each { |key, value| config.build_settings[key] = value }
  config.build_settings["PRODUCT_NAME"] = "Subset System"
  config.build_settings["EXECUTABLE_NAME"] = "SubsetSystem"
  config.build_settings["PRODUCT_MODULE_NAME"] = "SubsetSystem"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.system"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["INFOPLIST_FILE"] = "MacApp/Info.plist"
  # The entitlements file is intentionally empty: no App Sandbox and no exceptions, only the hardened runtime.
  config.build_settings["CODE_SIGN_ENTITLEMENTS"] = "MacApp/SubsetSystem.entitlements"
  config.build_settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  config.build_settings["ENABLE_APP_SANDBOX"] = "NO"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["MARKETING_VERSION"] = "0.1.0"
  config.build_settings["CURRENT_PROJECT_VERSION"] = "1"
  config.build_settings.delete("ASSETCATALOG_COMPILER_APPICON_NAME")
  config.build_settings.delete("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME")
  config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/../Frameworks"]
end
# new_target names the product after the target; point Products and the scheme at the bundle PRODUCT_NAME builds.
app_target.product_reference.path = "Subset System.app"
app_target.product_reference.name = "Subset System.app"

test_target.build_configurations.each do |config|
  COMMON_SETTINGS.each { |key, value| config.build_settings[key] = value }
  config.build_settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.system.tests"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["CODE_SIGNING_ALLOWED"] = "NO"
end

def add_sources(group, target, pattern)
  Dir.glob(pattern).sort.each do |path|
    target.add_file_references([group.new_file(File.basename(path))])
  end
end

add_sources(core_group, core_target, "Core/*.swift")
add_sources(core_group.new_group("Attribution", "Attribution"), core_target, "Core/Attribution/*.swift")
add_sources(core_group.new_group("Signals", "Signals"), core_target, "Core/Signals/*.swift")
add_sources(core_group.new_group("Containers", "Containers"), core_target, "Core/Containers/*.swift")
add_sources(app_group, app_target, "MacApp/*.swift")
add_sources(tests_group, test_target, "Tests/CoreTests/*.swift")
app_group.new_file("Info.plist")
app_group.new_file("SubsetSystem.entitlements")

app_target.frameworks_build_phase.add_file_reference(core_target.product_reference)
test_target.frameworks_build_phase.add_file_reference(core_target.product_reference)
%w[AppKit.framework SwiftUI.framework].each do |framework|
  file_ref = project.frameworks_group.new_file("System/Library/Frameworks/#{framework}", :sdk_root)
  app_target.frameworks_build_phase.add_file_reference(file_ref)
end

# Derive object IDs from their paths so regeneration is byte-for-byte reproducible.
project.predictabilize_uuids
# Target dependency proxies hash the targets' IDs, so a second pass settles them on the derived IDs.
project.predictabilize_uuids

# Write the project and its scheme to a staging folder, then install only those generated files into
# System.xcodeproj. Everything else in the bundle (breakpoints and personal schemes in xcuserdata, project.xcworkspace)
# belongs to the developer and stays. Each replaced file is backed up first and a failed install restores the backups,
# so a failure leaves the previous project intact. Tests/project-generator.sh checks both.
staging = Dir.mktmpdir("System-xcodeproj", __dir__)
keep_staging = false
begin
  staged_path = File.join(staging, File.basename(project_path))
  backup_path = File.join(staging, "backup")
  project.save(staged_path)
  scheme = Xcodeproj::XCScheme.new
  scheme.doc.root.attributes["LastUpgradeVersion"] = "2640"
  scheme.configure_with_targets(app_target, test_target, launch_target: true)
  scheme.save_as(staged_path, "SubsetSystem", true)

  generated = Dir.glob("**/*", base: staged_path).select { |path| File.file?(File.join(staged_path, path)) }.sort
  installed = []
  begin
    generated.each do |path|
      target = File.join(project_path, path)
      FileUtils.mkdir_p(File.dirname(target))
      if File.exist?(target)
        FileUtils.mkdir_p(File.dirname(File.join(backup_path, path)))
        FileUtils.cp(target, File.join(backup_path, path), preserve: true)
      end
      # rename replaces the file atomically; the staging folder is on the same volume.
      File.rename(File.join(staged_path, path), target)
      installed << path
    end
  rescue StandardError
    begin
      installed.each do |path|
        backup = File.join(backup_path, path)
        File.exist?(backup) ? File.rename(backup, File.join(project_path, path)) : File.delete(File.join(project_path, path))
      end
    rescue StandardError => restore_error
      keep_staging = true
      warn "Could not restore #{project_path} (#{restore_error.message}); the previous files are in #{backup_path}"
    end
    raise
  end
ensure
  FileUtils.rm_rf(staging) unless keep_staging
end

puts "Generated #{project_path}"
