require "minitest/autorun"
require "fileutils"
require "rbconfig"
require "tmpdir"

# Runs ProjectGenerator.rb on a copy of its inputs, failing each step that installs a generated file in turn. The
# previous project and scheme must stay installed as a pair, and local Xcode user data must survive every run.
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
      refute generate(operation, file, error), "generator should fail when #{operation} of #{file} raises #{error}"
      GENERATED.each { |generated| assert_equal @previous[generated], File.binread(project_file(generated)), generated }
      assert_user_data_and_no_staging
    end
  end

  def test_regeneration_is_deterministic_and_keeps_user_data
    2.times do
      assert generate, "generator should succeed"
      GENERATED.each do |file|
        assert_equal File.binread(File.join(ROOT, "Timer.xcodeproj", file)), File.binread(project_file(file)), file
      end
      assert_user_data_and_no_staging
    end
  end

  private

  def project_file(file)
    File.join(@dir, "Timer.xcodeproj", file)
  end

  # Loads the generator in a child process; with a failure set, the given File operation raises when it targets file.
  def generate(operation = nil, file = nil, error = nil)
    inject = operation ? <<~RB : ""
      File.singleton_class.prepend(Module.new do
        define_method(:#{operation}) do |from, to|
          raise #{error} if File.basename(#{operation == "link" ? "from" : "to"}) == #{file.dump}
          super(from, to)
        end
      end)
    RB
    system(RbConfig.ruby, "-e", "#{inject}load 'ProjectGenerator.rb'", chdir: @dir, out: File::NULL, err: File::NULL)
  end

  def assert_user_data_and_no_staging
    USER_DATA.each { |file| assert_equal file, File.read(project_file(file)), file }
    assert_empty Dir.glob("Timer-xcodeproj*", base: @dir)
  end
end
