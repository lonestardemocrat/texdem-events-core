# frozen_string_literal: true

module ::TexdemEvents
  class EventsController < ::ApplicationController
    requires_plugin "texdem-events-core"

    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required

    def index
      raise Discourse::NotFound unless SiteSetting.texdem_events_enabled

      limit = SiteSetting.texdem_events_limit.to_i
      limit = 200 if limit <= 0

      rows = ::TexdemEvents::EventIndex
        .where(visibility: "public")
        .where("starts_at IS NOT NULL")
        .order("starts_at ASC")
        .limit(limit)

      full = params[:full].to_s == "1"

      events = rows.map do |r|
        base = {
          id: "discourse-post-#{r.post_id}",
          post_id: r.post_id,
          topic_id: r.topic_id,
          category_id: r.category_id,
          title: r.title,
          start: r.starts_at&.iso8601,
          end: r.ends_at&.iso8601,
          timezone: r.timezone,
          location_name: r.location_name,
          address: r.address,
          city: r.city,
          state: r.state,
          zip: r.zip,
          lat: r.lat,
          lng: r.lng,
          external_url: r.external_url,
          graphic_url: r.graphic_url
        }

        if full
          base[:indexed_at] = r.indexed_at&.iso8601
        end

        base
      end

      render_json_dump(events)
    end
  end
end
