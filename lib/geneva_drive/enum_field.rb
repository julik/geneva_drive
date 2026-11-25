# frozen_string_literal: true

# Mongoid has no `enum`, so this tiny concern provides the slice of it the
# ActiveRecord models relied on: a String field with a default, an inclusion
# validation, per-value predicate methods and per-value class scopes.
#
# @api private
module GenevaDrive::EnumField
  extend ActiveSupport::Concern

  class_methods do
    # Declares a string-backed enum field.
    #
    # @param name [Symbol] the field name
    # @param values [Array<String>] the allowed values
    # @param default [String] the default value
    # @param instance_methods [Boolean] whether to define `value?` predicates
    # @param scopes [Boolean] whether to define `Model.value` scopes
    # @return [void]
    def enum_field(name, values, default:, instance_methods: true, scopes: true)
      field name, type: String, default: default
      validates name, inclusion: {in: values}

      values.each do |value|
        if instance_methods
          define_method(:"#{value}?") { public_send(name) == value }
        end
        if scopes
          scope value.to_sym, -> { where(name => value) }
        end
      end
    end
  end
end
