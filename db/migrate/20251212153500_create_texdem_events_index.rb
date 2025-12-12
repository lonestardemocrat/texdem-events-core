# frozen_string_literal: true

class CreateTexdemEventsIndex < ActiveRecord::Migration[7.0]
  def change
    create_table :texdem_events_index do |t|
      t.integer :post_id, null: false
      t.integer :topic_id
      t.integer :category_id

      t.string  :title
      t.datetime :starts_at
      t.datetime :ends_at
      t.string  :timezone

      t.string  :location_name
      t.string  :address
      t.string  :city
      t.string  :state
      t.string  :zip
      t.string  :visibility

      t.float :lat
      t.float :lng

      t.string :external_url
      t.string :graphic_url
      t.string :source  # e.g. "ics", "modal", etc.

      t.timestamps
    end

    add_index :texdem_events_index, :post_id, unique: true
    add_index :texdem_events_index, :starts_at
    add_index :texdem_events_index, :topic_id
    add_index :texdem_events_index, :category_id
    add_index :texdem_events_index, [:lat, :lng]
  end
end
