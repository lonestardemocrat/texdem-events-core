# frozen_string_literal: true

module ::TexdemEvents
  class EventIndex < ActiveRecord::Base
    self.table_name = "texdem_events_event_index"

    belongs_to :post
    belongs_to :topic
  end
end
