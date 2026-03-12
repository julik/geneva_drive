# frozen_string_literal: true

# Provides safe read/write access to the freeform JSON metadata column
# on step executions. All "does the column exist?" logic lives here so
# the rest of the codebase can call read_metadata / write_metadata without
# guarding. When the metadata column has not been migrated yet, writes
# are silent no-ops and reads return nil.
#
# Once the migration becomes mandatory, delete this concern and replace with
# a plain `attribute :metadata, :json, default: -> { {} }` on StepExecution.
#
# @api private
module GenevaDrive::StepExecution::MetadataAccessor
  extend ActiveSupport::Concern

  class_methods do
    # Lazily checks whether the metadata column exists and registers
    # the JSON attribute type on first positive detection. Never hits the
    # database at class definition time — only on the first runtime call.
    #
    # @return [Boolean]
    def metadata_column?
      if defined?(@_metadata_column)
        return @_metadata_column
      end

      available = table_exists? && column_names.include?("metadata")
      attribute(:metadata, :json, default: -> { {} }) if available
      @_metadata_column = available
    end

    # Counts reattempted step executions in the given scope, excluding
    # flow-control reattempts when the metadata column is available.
    # Without the column, counts all reattempts (coarser but safe —
    # errs on the side of pausing sooner).
    #
    # @param scope [ActiveRecord::Relation] a relation of step executions
    #   already filtered to outcome: "reattempted"
    # @return [Integer]
    def count_error_reattempts(scope)
      unless metadata_column?
        return scope.count
      end

      scope.pluck(:metadata).count do |meta|
        reason = meta.is_a?(Hash) ? meta["reattempt_reason"] : nil
        reason != "flow_control"
      end
    end

    # Clears the cached detection result. Call this in tests or after
    # running migrations in-process so the next access re-checks.
    #
    # @return [void]
    def reset_metadata_column_cache!
      remove_instance_variable(:@_metadata_column) if defined?(@_metadata_column)
    end
  end

  # Reads a single key from the metadata hash.
  #
  # @param key [String, Symbol] the metadata key
  # @return [Object, nil] the value, or nil if the column is absent
  def read_metadata(key)
    return nil unless self.class.metadata_column?
    parsed_metadata[key.to_s]
  end

  # Merges a key/value pair into the metadata hash (in-memory only, does
  # not persist — call save!/update! separately or include in a broader
  # update).
  #
  # @param key [String, Symbol] the metadata key
  # @param value [Object] the value to store
  # @return [void]
  def write_metadata(key, value)
    return unless self.class.metadata_column?
    merged = parsed_metadata.merge(key.to_s => value)
    # When the JSON attribute type is active, assign the Hash directly so
    # AR handles serialization. When it's not (record loaded before lazy
    # registration), write a JSON string so the text column gets valid JSON.
    if metadata.is_a?(Hash) || metadata.nil?
      self.metadata = merged
    else
      write_attribute(:metadata, merged.to_json)
    end
  end

  # Returns the reattempt reason from metadata.
  # Possible values: "flow_control", "exception_policy", "precondition", or nil.
  #
  # @return [String, nil]
  def reattempt_reason
    read_metadata("reattempt_reason")
  end

  # Returns the exception info hash from metadata, if recorded.
  # Keys: "class", "message", "backtrace" (backtrace is an Array of strings).
  #
  # @return [Hash, nil]
  def exception_info
    read_metadata("exception")
  end

  private

  # Returns metadata as a Hash regardless of whether the JSON attribute
  # type has been applied to this instance. On SQLite/MySQL the raw value
  # may still be a JSON string if the record was loaded before the
  # attribute type was lazily registered.
  #
  # @return [Hash]
  def parsed_metadata
    raw = metadata
    case raw
    when Hash then raw
    when String then JSON.parse(raw)
    when NilClass then {}
    else {}
    end
  rescue JSON::ParserError
    {}
  end
end
