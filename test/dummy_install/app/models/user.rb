# frozen_string_literal: true

class User < ApplicationRecord
  validates :email, presence: true

  def deactivated?
    !active?
  end
end
