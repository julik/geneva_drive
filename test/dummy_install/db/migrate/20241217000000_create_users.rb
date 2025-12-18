# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[7.2]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :name
      t.boolean :active, default: true
      t.timestamps
    end
  end
end
