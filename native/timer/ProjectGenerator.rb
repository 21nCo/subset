# Pin the gem CI installs: newer releases write a different preferredProjectObjectVersion, so a plain require would
# make the committed project depend on whichever xcodeproj the host happens to have.
gem "xcodeproj", "= 1.27.0"
require "xcodeproj"
require "fileutils"
require "tmpdir"

# Generates Timer.xcodeproj from the same sources as Package.swift: a static TimerCore library and the Timer menu bar
# app that links it and embeds the Timer CLI runtime. Run `ruby ProjectGenerator.rb` from this folder after adding or
# removing a source file; CI regenerates the project and fails if the committed copy differs.
Dir.chdir(__dir__)
project_path = File.join(__dir__, "Timer.xcodeproj")
project = Xcodeproj::Project.new(project_path, false, 46)
project.root_object.preferred_project_object_version = "77"

project.root_object.attributes["LastSwiftUpdateCheck"] = "2640"
project.root_object.attributes["LastUpgradeCheck"] = "2640"
project.root_object.attributes["TargetAttributes"] = {}

core_group = project.main_group.new_group("Core", "Core")
app_group = project.main_group.new_group("MacApp", "MacApp")

core_target = project.new_target(:static_library, "TimerCore", :osx, "14.0")
app_target = project.new_target(:application, "Timer", :osx, "14.0")
app_target.add_dependency(core_target)

# new_target links Cocoa through a DEVELOPER_DIR path pinned to one SDK version; frameworks are added relative to
# SDKROOT below instead.
[core_target, app_target].each { |target| target.frameworks_build_phase.files.to_a.each(&:remove_from_project) }
project.frameworks_group.recursive_children.select { |child| child.isa == "PBXFileReference" }.each(&:remove_from_project)
project.frameworks_group.groups.each(&:remove_from_project)
project.root_object.attributes["TargetAttributes"][app_target.uuid] = { "CreatedOnToolsVersion" => "26.4" }

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
  config.build_settings["PRODUCT_NAME"] = "TimerCore"
  config.build_settings["PRODUCT_MODULE_NAME"] = "TimerCore"
  config.build_settings["DEFINES_MODULE"] = "YES"
  # Only the app belongs in the release archive.
  config.build_settings["SKIP_INSTALL"] = "YES"
  config.build_settings["CODE_SIGNING_ALLOWED"] = "NO"
end

app_target.build_configurations.each do |config|
  COMMON_SETTINGS.each { |key, value| config.build_settings[key] = value }
  config.build_settings["PRODUCT_NAME"] = "Timer"
  config.build_settings["EXECUTABLE_NAME"] = "Timer"
  # A module named Timer would shadow Foundation's Timer class inside the app.
  config.build_settings["PRODUCT_MODULE_NAME"] = "TimerApp"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.timer"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["INFOPLIST_FILE"] = "MacApp/Info.plist"
  config.build_settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["MARKETING_VERSION"] = "0.1.0"
  config.build_settings["CURRENT_PROJECT_VERSION"] = "1"
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  config.build_settings.delete("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME")
  config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/../Frameworks"]
  # The Embed Timer CLI phase copies a folder tree, and a sandboxed script may write only the paths it declares, not
  # the files and folders inside a declared folder.
  config.build_settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO"
end

def add_sources(group, target, pattern)
  Dir.glob(pattern).sort.each do |path|
    target.add_file_references([group.new_file(File.basename(path))])
  end
end

add_sources(core_group, core_target, "Core/*.swift")
add_sources(app_group, app_target, "MacApp/*.swift")
app_target.resources_build_phase.add_file_reference(app_group.new_file("Assets.xcassets"))
app_group.new_file("Info.plist")

app_target.frameworks_build_phase.add_file_reference(core_target.product_reference)
%w[AppKit.framework Network.framework SwiftUI.framework].each do |framework|
  file_ref = project.frameworks_group.new_file("System/Library/Frameworks/#{framework}", :sdk_root)
  app_target.frameworks_build_phase.add_file_reference(file_ref)
end

# Copies the generation packages/timer-cli/app-runtime links to (dist, web, mcp-app and skills, staged by
# `npm run build` at the repository root) into Timer.app/Contents/Resources/timer-cli. A build that publishes a newer
# generation meanwhile may remove that one, so the copy counts only if the generation still exists afterwards. A Release
# build fails without a staged runtime; a Debug build warns, and that app then needs SUBSET_TIMER_CLI_PATH.
embed = app_target.new_shell_script_build_phase("Embed Timer CLI")
embed.shell_path = "/bin/sh"
embed.input_paths = ["$(SRCROOT)/../../packages/timer-cli/app-runtime"]
embed.output_paths = ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/timer-cli"]
embed.always_out_of_date = "1"
embed.shell_script = <<~'SH'
  set -eu
  RUNTIME="${SRCROOT}/../../packages/timer-cli/app-runtime"
  DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/timer-cli"
  for attempt in 1 2 3; do
    rm -rf "${DEST}"
    GENERATION=$(readlink "${RUNTIME}" || true)
    SRC="${RUNTIME%/*}/${GENERATION}"
    for part in dist/cli.mjs web/index.html mcp-app/board.html skills/subset-timer/SKILL.md; do
      if [ -z "${GENERATION}" ] || [ ! -f "${SRC}/${part}" ]; then
        if [ -n "${GENERATION}" ] && [ "$(readlink "${RUNTIME}" || true)" != "${GENERATION}" ]; then continue 2; fi
        if [ "${CONFIGURATION}" = "Release" ]; then
          echo "error: ${RUNTIME}/${part} is missing. Run npm ci && npm run build at the repository root first."
          exit 1
        fi
        echo "warning: ${RUNTIME}/${part} is missing; this Debug app runs the CLI only from SUBSET_TIMER_CLI_PATH."
        exit 0
      fi
    done
    if ditto "${SRC}" "${DEST}" && [ -d "${SRC}" ]; then exit 0; fi
  done
  echo "error: ${RUNTIME} kept changing while it was copied. Wait for the npm run build in progress, then build again."
  exit 1
SH

# Derive object IDs from their paths so regeneration is byte-for-byte reproducible.
project.predictabilize_uuids
# Target dependency proxies hash the targets' IDs, so a second pass settles them on the derived IDs.
project.predictabilize_uuids

# Write the project and its scheme to a temporary folder, then move each generated file over its old copy only after
# both saves succeed. Each move replaces one whole file, and what the generator does not write, such as xcuserdata and
# project.xcworkspace, is left alone.
Dir.mktmpdir("Timer-xcodeproj", __dir__) do |staging|
  staged_path = File.join(staging, File.basename(project_path))
  project.save(staged_path)
  scheme = Xcodeproj::XCScheme.new
  scheme.doc.root.attributes["LastUpgradeVersion"] = "2640"
  scheme.configure_with_targets(app_target, nil, launch_target: true)
  scheme.save_as(staged_path, "Timer", true)
  Dir.glob("**/*", base: staged_path).reject { |file| File.directory?(File.join(staged_path, file)) }.each do |file|
    FileUtils.mkdir_p(File.dirname(File.join(project_path, file)))
    File.rename(File.join(staged_path, file), File.join(project_path, file))
  end
end

puts "Generated #{project_path}"
