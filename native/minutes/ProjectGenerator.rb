# Regenerates Minutes.xcodeproj. Run from this directory: `ruby ProjectGenerator.rb`.
# Requires the `xcodeproj` gem. The bot itself is the shared `subset-minutes` CLI (packages/minutes-cli);
# the "Embed Minutes CLI" phase copies its staged app-runtime/ into the app's Resources.
require "xcodeproj"
require "fileutils"

project_path = File.join(__dir__, "Minutes.xcodeproj")
FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
project.root_object.attributes["LastSwiftUpdateCheck"] = "1640"
project.root_object.attributes["LastUpgradeCheck"] = "1640"
project.root_object.attributes["TargetAttributes"] = {}

mac_group = project.main_group.new_group("MacApp", "MacApp")

mac_target = project.new_target(:application, "Minutes", :osx, "14.0")
project.root_object.attributes["TargetAttributes"][mac_target.uuid] = { "CreatedOnToolsVersion" => "16.4" }

mac_target.build_configurations.each do |config|
  config.build_settings.merge!(
    "SWIFT_VERSION" => "6.0",
    "CLANG_ENABLE_MODULES" => "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
    "SWIFT_EMIT_LOC_STRINGS" => "NO",
    "PRODUCT_NAME" => "Minutes",
    "PRODUCT_BUNDLE_IDENTIFIER" => "dev.subset.minutes",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => "MacApp/macOS-Info.plist",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "MACOSX_DEPLOYMENT_TARGET" => "14.0",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/../Frameworks"],
    "MARKETING_VERSION" => "0.1.0",
    "CURRENT_PROJECT_VERSION" => "1",
    "SUPPORTED_PLATFORMS" => "macosx"
  )
end

refs = %w[MinutesApp.swift ContentView.swift MinutesController.swift MinutesCLI.swift].map { |name| mac_group.new_file(name) }
mac_target.add_file_references(refs)
mac_group.new_file("macOS-Info.plist")
mac_target.add_resources([mac_group.new_file("Assets.xcassets")])

# Copies packages/minutes-cli/app-runtime (built by `npm run build` at the repository root) into
# Minutes.app/Contents/Resources/minutes-cli. A Release build fails without it; a Debug build warns
# and the app falls back to the repository build of the CLI.
embed = mac_target.new_shell_script_build_phase("Embed Minutes CLI")
embed.shell_path = "/bin/sh"
embed.input_paths = ["$(SRCROOT)/../../packages/minutes-cli/app-runtime"]
embed.output_paths = ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/minutes-cli"]
embed.always_out_of_date = "1"
embed.shell_script = <<~'SH'
  set -eu
  SRC="${SRCROOT}/../../packages/minutes-cli/app-runtime"
  DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/minutes-cli"
  rm -rf "${DEST}"
  if [ ! -f "${SRC}/dist/cli.mjs" ]; then
    if [ "${CONFIGURATION}" = "Release" ]; then
      echo "error: ${SRC} is missing. Run npm ci && npm run build at the repository root first."
      exit 1
    fi
    echo "warning: ${SRC} is missing; this Debug app will use packages/minutes-cli/dist from the repository."
    exit 0
  fi
  ditto "${SRC}" "${DEST}"
SH

project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(mac_target, nil, launch_target: true)
scheme.save_as(project_path, "Minutes", true)
puts "Generated #{project_path}"
