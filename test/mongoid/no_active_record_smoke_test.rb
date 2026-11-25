# frozen_string_literal: true

# Mongoid tests run only under `rake test:mongoid`, which boots the dummy app
# against MongoDB (GENEVA_DRIVE_ORM=mongoid) - see test/mongoid_helper.rb
return unless ENV["GENEVA_DRIVE_ORM"] == "mongoid"
require "mongoid_helper"

# ActiveRecord moved from a hard gemspec dependency to a soft one so a
# Mongoid-only app does not drag it in. This is the check that keeps it that
# way: the gem - including the Mongoid backend - must load without
# ActiveRecord ever hitting $LOADED_FEATURES.
class NoActiveRecordSmokeTest < ActiveSupport::TestCase
  test "this Mongoid-only boot never loaded ActiveRecord" do
    refute defined?(::ActiveRecord), "ActiveRecord is loaded in the Mongoid test boot"
    assert_empty $LOADED_FEATURES.grep(%r{/active_record(/|\.rb)})
  end

  test "require geneva_drive and geneva_drive/mongoid pulls no ActiveRecord in a bare process" do
    script = <<~RUBY
      require "rails"
      require "geneva_drive"
      require "geneva_drive/mongoid"
      raise "ActiveRecord got defined" if defined?(::ActiveRecord)
      unless $LOADED_FEATURES.grep(%r{/active_record(/|\\.rb)}).empty?
        raise "activerecord files got required"
      end
      print "CLEAN"
    RUBY

    output = IO.popen(["bundle", "exec", "ruby", "-e", script], err: [:child, :out], &:read)

    assert $?.success?, "subprocess failed: #{output}"
    assert_includes output, "CLEAN"
  end
end
