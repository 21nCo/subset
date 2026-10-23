require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

# Runs ProjectGenerator.rb on a copy of its inputs, failing each step that installs a generated file in turn. The
# previous project and scheme must stay installed as a pair, and local Xcode user data must survive every run. When
# putting a file back fails too, every restore must still be tried and the previous files kept in a reported folder.
# Run from native/timer with the xcodeproj gem installed: ruby Tests/ProjectGenerator/install_test.rb
class ProjectGeneratorInstallTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GENERATED = ["project.pbxproj", "xcshareddata/xcschemes/Timer.xcscheme"].freeze
  USER_DATA = ["xcuserdata/test.xcuserdatad/keep", "project.xcworkspace/xcuserdata/test.xcuserdatad/keep"].freeze

  def setup
    @dir = Dir.mktmpdir("timer-generator")
    %w[ProjectGenerator.rb Core MacApp Timer.xcodeproj].each { |entry| FileUtils.cp_r(File.join(ROOT, entry), @dir) }
    @previous = GENERATED.to_h do |file|
      path = project_file(file)
      File.write(path, "#{File.read(path)}\n<!-- previous generation -->\n")
      [file, File.binread(path)]
    end
    USER_DATA.each do |file|
      FileUtils.mkdir_p(File.dirname(project_file(file)))
      File.write(project_file(file), file)
    end
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  {
    "link_project" => ["link", "project.pbxproj", "Errno::EIO"],
    "install_project" => ["rename", "project.pbxproj", "Errno::EIO"],
    "link_scheme" => ["link", "Timer.xcscheme", "Errno::EIO"],
    "install_scheme" => ["rename", "Timer.xcscheme", "Errno::EIO"],
    "interrupt_scheme" => ["rename", "Timer.xcscheme", "Interrupt"]
  }.each do |name, (operation, file, error)|
    define_method("test_failure_at_#{name}_keeps_previous_pair") do
      refute generate(operation: operation, file: file, error: error).first, "#{operation} of #{file} raises #{error}"
      GENERATED.each { |generated| assert_equal @previous[generated], File.binread(project_file(generated)), generated }
      assert_user_data_and_no_staging
    end
  end

  def test_regeneration_is_deterministic_and_keeps_user_data
    2.times do
      success, output = generate
      assert success, output
      GENERATED.each do |file|
        assert_equal File.binread(File.join(ROOT, "Timer.xcodeproj", file)), File.binread(project_file(file)), file
      end
      assert_user_data_and_no_staging
    end
  end

  def test_failed_project_restore_keeps_previous_project_and_reports_both_errors
    success, output = generate({ operation: "rename", file: "Timer.xcscheme", error: "Errno::EIO" },
                               { operation: "rename", file: "project.pbxproj", error: "Errno::EACCES", restore: true })
    refute success
    assert_includes output, "Errno::EIO: Input/output error"
    assert_includes output, "project.pbxproj (Errno::EACCES"
    assert_equal @previous["xcshareddata/xcschemes/Timer.xcscheme"], File.binread(project_file(GENERATED[1]))
    assert_previous_files_recoverable(output)
  end

  def test_failed_scheme_restore_still_restores_project
    success, output = generate({ operation: "rename", file: "Timer.xcscheme", error: "Interrupt", after: true },
                               { operation: "rename", file: "Timer.xcscheme", error: "Errno::EACCES", restore: true })
    refute success
    assert_includes output, "(Interrupt: Interrupt)"
    assert_includes output, "Timer.xcscheme (Errno::EACCES"
    # The scheme was restored first and failed, so the project's restore after it shows that every restore is tried.
    assert_equal @previous["project.pbxproj"], File.binread(project_file(GENERATED[0]))
    assert_previous_files_recoverable(output)
  end

  private

  def project_file(file)
    File.join(@dir, "Timer.xcodeproj", file)
  end

  # Loads the generator in a child process and returns its success and output. Each fault makes File.link or File.rename
  # raise its error when it installs the named file, or with restore: true, when it puts the file's old copy back; with
  # after: true, the operation completes before the error is raised.
  def generate(*faults)
    inject = faults.empty? ? "" : <<~RB
      FAULTS = #{faults.inspect}
      File.singleton_class.prepend(Module.new do
        %w[link rename].each do |operation|
          define_method(operation) do |from, to|
            restore = from.include?("Timer-xcodeproj-backup")
            fault = FAULTS.find do |f|
              f[:operation] == operation && File.basename(to) == f[:file] && !f[:restore] == !restore
            end
            raise Object.const_get(fault[:error]) if fault && !fault[:after]
            super(from, to).tap { raise Object.const_get(fault[:error]) if fault }
          end
        end
      end)
    RB
    output, status = Open3.capture2e(RbConfig.ruby, "-e", "#{inject}load 'ProjectGenerator.rb'", chdir: @dir)
    [status.success?, output]
  end

  # Each generated file is either installed as its previous copy or kept in the backup folder the error names.
  def assert_previous_files_recoverable(output)
    kept = output[/The previous files are kept in (\S+);/, 1]
    assert kept, output
    GENERATED.each do |file|
      next if File.binread(project_file(file)) == @previous[file]
      assert_equal @previous[file], File.binread(File.join(kept, file)), "#{file} is neither installed nor kept"
    end
    USER_DATA.each { |file| assert_equal file, File.read(project_file(file)), file }
    assert_equal [File.basename(kept)], Dir.glob("Timer-xcodeproj*", base: @dir)
  end

  def assert_user_data_and_no_staging
    USER_DATA.each { |file| assert_equal file, File.read(project_file(file)), file }
    assert_empty Dir.glob("Timer-xcodeproj*", base: @dir)
  end
end
