# Regenerates Dictate.xcodeproj. Run from this directory: `ruby ProjectGenerator.rb`.
# Requires the `xcodeproj` gem. Run scripts/setup-whispercpp.sh before building so that
# .build/whisper.xcframework exists; the project references it but it is not committed.
require "xcodeproj"

project_path = File.join(__dir__, "Dictate.xcodeproj")
project = Xcodeproj::Project.new(project_path)

project.root_object.attributes["LastSwiftUpdateCheck"] = "2640"
project.root_object.attributes["LastUpgradeCheck"] = "2640"
project.root_object.attributes["TargetAttributes"] = {}

main_group = project.main_group
shared_group = main_group.new_group("Shared", "Shared")
models_group = shared_group.new_group("Models", "Models")
services_group = shared_group.new_group("Services", "Services")
ui_group = shared_group.new_group("UI", "UI")
whisper_group = main_group.new_group("whisper", "whisper")
vendor_group = whisper_group.new_group("vendor", "vendor")
mac_group = main_group.new_group("MacApp", "MacApp")
tests_group = main_group.new_group("Tests", "Tests")
frameworks_group = main_group.new_group("Frameworks")

mac_target = project.new_target(:application, "Dictate", :osx, "14.0")
project.root_object.attributes["TargetAttributes"][mac_target.uuid] = {
  "CreatedOnToolsVersion" => "26.4"
}

test_target = project.new_target(:unit_test_bundle, "DictateTests", :osx, "14.0")
test_target.add_dependency(mac_target)
project.root_object.attributes["TargetAttributes"][test_target.uuid] = {
  "CreatedOnToolsVersion" => "26.4",
  "TestTargetID" => mac_target.uuid
}
test_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["SWIFT_VERSION"] = "6.0"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.dictate.tests"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  settings["SUPPORTED_PLATFORMS"] = "macosx"
  settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/Dictate.app/Contents/MacOS/Dictate"
  settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  settings["CODE_SIGNING_ALLOWED"] = "NO"
end
test_target.add_file_references([tests_group.new_file("DictateTests.swift")])

mac_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["SWIFT_VERSION"] = "6.0"
  settings["CLANG_ENABLE_MODULES"] = "YES"
  settings["DEFINES_MODULE"] = "YES"
  settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "YES"
  settings["SWIFT_EMIT_LOC_STRINGS"] = "NO"
  settings["PRODUCT_NAME"] = "Dictate"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.subset.dictate"
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["INFOPLIST_FILE"] = "MacApp/macOS-Info.plist"
  settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/../Frameworks"]
  settings["MARKETING_VERSION"] = "0.1.0"
  settings["CURRENT_PROJECT_VERSION"] = "1"
  settings["SUPPORTED_PLATFORMS"] = "macosx"
  settings["SWIFT_OBJC_BRIDGING_HEADER"] = "whisper/Dictate-Bridging-Header.h"
  settings["CLANG_ENABLE_OBJC_ARC"] = "YES"
  settings["GCC_ENABLE_CPP_EXCEPTIONS"] = "YES"
  settings["GCC_ENABLE_CPP_RTTI"] = "YES"
  settings["CODE_SIGN_ENTITLEMENTS"] = "MacApp/Dictate.entitlements"
  settings["ENABLE_HARDENED_RUNTIME"] = "YES"
end

{
  models_group => %w[DictationModels.swift WhisperModelCatalog.swift],
  services_group => %w[
    SharedTranscriptStore.swift
    DictationBackendFactory.swift
    MockDictationBackend.swift
    CloudDictationBackend.swift
    WhisperModelStore.swift
    WhisperModelDownloadService.swift
    WhisperModelManager.swift
    WhisperAudioProcessor.swift
    WhisperCppBackend.swift
    DictationManager.swift
    ActiveAppTextInjector.swift
  ],
  ui_group => %w[TranscriptCard.swift],
  whisper_group => %w[WhisperCppWrapper.mm],
  mac_group => %w[
    DictateApp.swift
    DictationAppController.swift
    MacRootView.swift
    FloatingActivationPanelController.swift
    FloatingActivationView.swift
    GlobalHotkeyMonitor.swift
  ]
}.each do |group, names|
  refs = names.map { |name| group.new_file(name) }
  mac_target.add_file_references(refs)
end

%w[WhisperCppWrapper.h Dictate-Bridging-Header.h].each { |name| whisper_group.new_file(name) }
%w[ggml.h ggml-alloc.h ggml-backend.h ggml-blas.h ggml-cpu.h ggml-metal.h gguf.h whisper.h LICENSE].each do |name|
  vendor_group.new_file(name)
end
mac_group.new_file("macOS-Info.plist")
mac_group.new_file("Dictate.entitlements")

assets = mac_group.new_file("Assets.xcassets")
mac_target.add_resources([assets])

# whisper.xcframework is fetched by scripts/setup-whispercpp.sh into .build/ (gitignored).
whisper_framework = frameworks_group.new_file(".build/whisper.xcframework")
whisper_framework.name = "whisper.xcframework"
whisper_framework.last_known_file_type = "wrapper.xcframework"
mac_target.frameworks_build_phase.add_file_reference(whisper_framework)

embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_phase.name = "Embed Frameworks"
embed_phase.symbol_dst_subfolder_spec = :frameworks
mac_target.build_phases << embed_phase
embed_file = embed_phase.add_file_reference(whisper_framework)
embed_file.settings = { "ATTRIBUTES" => %w[CodeSignOnCopy RemoveHeadersOnCopy] }

# xcodeproj adds Cocoa.framework under DEVELOPER_DIR with a pinned SDK version; resolve it
# through the selected SDK instead.
project.files.each do |ref|
  next unless ref.path.to_s.end_with?("Cocoa.framework")
  ref.path = "System/Library/Frameworks/Cocoa.framework"
  ref.source_tree = "SDKROOT"
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(mac_target, test_target, launch_target: true)
scheme.save_as(project_path, "Dictate", true)
