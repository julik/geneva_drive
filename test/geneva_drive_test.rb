require "test_helper"

class GenevaDriveTest < ActiveSupport::TestCase
  test "it has a version number" do
    assert GenevaDrive::VERSION
  end

  test "initializer template only documents settings that exist" do
    template = File.expand_path("../lib/generators/geneva_drive/install/templates/initializer.rb.tt", __dir__)
    settings = File.read(template).scan(/GenevaDrive\.(\w+)\s*=/).flatten
    refute_empty settings

    settings.each do |setting|
      assert GenevaDrive.respond_to?("#{setting}="), "GenevaDrive.#{setting} in the initializer template is not a setting"
    end
  end
end
