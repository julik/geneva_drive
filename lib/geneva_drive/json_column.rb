# frozen_string_literal: true

# JSON encoding for columns the database does not type as JSON itself.
#
# PostgreSQL and MySQL both hand Rails a real JSON attribute, so a Hash
# assigned to one is encoded by the adapter and comes back decoded. MariaDB
# has no JSON type - see GenevaDrive::MigrationHelpers#geneva_drive_json_column
# for why - so the column is plain LONGTEXT, Rails types it as text, and a Hash
# written to it would be stored as `#inspect` output. Encoding it here keeps
# the models writing and reading the same Ruby values everywhere.
#
# The branch is on the column, not on the adapter, deliberately: an install
# that already ran the old migration against MariaDB has a LONGTEXT column and
# gets the encoding too, without needing its column rewritten first.
#
# @api private
module GenevaDrive::JsonColumn
  extend ActiveSupport::Concern

  class_methods do
    # Whether the column holds JSON as text rather than as a JSON type, and so
    # needs encoding and decoding here. Lazily detected: never touches the
    # database at class definition time, since the column may not exist yet.
    #
    # @param name [String, Symbol] the column name
    # @return [Boolean]
    def json_column_as_text?(name)
      name = name.to_s
      @_json_column_as_text ||= {}
      return @_json_column_as_text[name] if @_json_column_as_text.key?(name)

      @_json_column_as_text[name] = begin
        column = table_exists? && columns_hash[name]
        column ? column.type == :text : false
      rescue ActiveRecord::ActiveRecordError
        false
      end
    end

    # Clears the cached detection. Call after migrating in-process.
    #
    # @return [void]
    def reset_json_column_cache!
      remove_instance_variable(:@_json_column_as_text) if defined?(@_json_column_as_text)
    end

    # Prepares an already-serialized value for writing to the column.
    #
    # @param name [String, Symbol] the column name
    # @param value [Object, nil] a JSON-safe Ruby value
    # @return [Object, nil] the value, encoded to a JSON string where needed
    def encode_json_column(name, value)
      return value unless json_column_as_text?(name)
      return nil if value.nil?

      JSON.generate(value)
    end

    # Reverses {encode_json_column} for a value read off the column.
    #
    # @param name [String, Symbol] the column name
    # @param raw [Object, nil] the raw attribute value
    # @return [Object, nil] the decoded value
    def decode_json_column(name, raw)
      return raw unless json_column_as_text?(name)
      return nil if raw.nil?
      return raw unless raw.is_a?(String)

      JSON.parse(raw)
    end
  end
end
