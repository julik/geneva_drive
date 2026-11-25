# frozen_string_literal: true

# The Mongoid hero model for the Mongoid test suite - the twin of the
# ActiveRecord User. Only referenced (and so only loaded) when the dummy app
# boots with GENEVA_DRIVE_ORM=mongoid.
class MongoUser
  include Mongoid::Document
  include GlobalID::Identification
  include Mongoid::Timestamps

  field :email, type: String
  field :name, type: String
  field :active, type: Mongoid::Boolean, default: true

  validates :email, presence: true

  def deactivated?
    !active?
  end
end
