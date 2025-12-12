# frozen_string_literal: true

class CreateTexdemEventsEventIndex < ActiveRecord::Migration[7.0]
  def change
    create_table :texdem_events_event_index do |t|
      t.integer  :post_id, null: false
      t.integer  :topic_id, null: false
      t.integer  :category_id
      t.string   :visibility, null: false, default: "internal"

      t.string   :title
      t.datetime :starts_at
      t.datetime :ends_at
      t.string   :timezone

      t.string   :location_name
      t.string   :address
      t.string   :city
      t.string   :state
      t.string   :zip
      t.float    :lat
      t.float    :lng

      t.string   :external_url
      t.string   :graphic_url

      t.datetime :indexed_at, null: false
    end

    add_index :texdem_events_event_index, :post_id, unique: true
    add_index :texdem_events_event_index, [:visibility, :starts_at]
    add_index :texdem_events_event_index, :topic_id
    add_index :texdem_events_event_index, :category_id
  end
end
