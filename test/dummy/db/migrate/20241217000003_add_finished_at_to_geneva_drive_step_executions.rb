# frozen_string_literal: true

class AddFinishedAtToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  def change
    add_column :geneva_drive_step_executions, :finished_at, :datetime

    add_index :geneva_drive_step_executions, :finished_at

    reversible do |direction|
      direction.up do
        # Backfill finished_at from existing timestamp columns.
        # Uses COALESCE to pick the first non-null value.
        execute <<-SQL.squish
          UPDATE geneva_drive_step_executions
          SET finished_at = COALESCE(completed_at, failed_at, canceled_at, skipped_at)
          WHERE finished_at IS NULL
            AND (completed_at IS NOT NULL
              OR failed_at IS NOT NULL
              OR canceled_at IS NOT NULL
              OR skipped_at IS NOT NULL)
        SQL
      end
    end
  end
end
