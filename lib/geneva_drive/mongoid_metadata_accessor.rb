# frozen_string_literal: true

# Provides read/write access to the freeform metadata Hash field on the
# Mongoid models. On MongoDB the field is schemaless and always present, so
# the column-detection machinery of the SQL implementation reduces to
# constants; the methods are kept so the rest of the codebase (and host apps)
# can call read_metadata / write_metadata unchanged.
#
# @api private
module GenevaDrive::MongoidMetadataAccessor
  extend ActiveSupport::Concern

  class_methods do
    # Always true on MongoDB - the field needs no migration.
    #
    # @return [Boolean]
    def metadata_column?
      true
    end

    # Kept as a no-op for API compatibility with the SQL implementation.
    #
    # @return [void]
    def reset_metadata_column_cache!
    end
  end

  # Reads a single key from the metadata hash.
  #
  # @param key [String, Symbol] the metadata key
  # @return [Object, nil] the value
  def read_metadata(key)
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
    self.metadata = parsed_metadata.merge(key.to_s => value)
  end

  private

  # Returns metadata as a Hash with string keys regardless of how it was
  # written.
  #
  # @return [Hash]
  def parsed_metadata
    raw = metadata
    case raw
    when Hash then raw.stringify_keys
    when String then JSON.parse(raw)
    when NilClass then {}
    else {}
    end
  rescue JSON::ParserError
    {}
  end
end
