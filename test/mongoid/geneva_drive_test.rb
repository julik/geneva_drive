# Mongoid tests run only under `rake test:mongoid`, which boots the dummy app
# against MongoDB (GENEVA_DRIVE_ORM=mongoid) - see test/mongoid_helper.rb
return unless ENV["GENEVA_DRIVE_ORM"] == "mongoid"
require "mongoid_helper"

class GenevaDriveTest < ActiveSupport::TestCase
  test "it has a version number" do
    assert GenevaDrive::VERSION
  end

  test "initializer template only documents settings that exist" do
    template = File.expand_path("../../lib/generators/geneva_drive/install/templates/initializer.rb.tt", __dir__)
    settings = File.read(template).scan(/GenevaDrive\.(\w+)\s*=/).flatten
    refute_empty settings

    settings.each do |setting|
      assert GenevaDrive.respond_to?("#{setting}="), "GenevaDrive.#{setting} in the initializer template is not a setting"
    end
  end
end
