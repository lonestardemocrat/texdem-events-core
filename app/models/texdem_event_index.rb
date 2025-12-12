# frozen_string_literal: true

module ::TexdemEvents
  class EventIndex < ActiveRecord::Base
    self.table_name = "texdem_events_index"
  end
end
