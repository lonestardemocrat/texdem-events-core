# name: texdem-events-core
# about: Minimal backend-only JSON endpoint for TexDem events, based on selected Discourse categories.
# version: 0.2.0
# authors: TexDem
# url: https://texdem.org

enabled_site_setting :texdem_events_enabled

after_initialize do
  module ::TexdemEvents
  end

  class ::TexdemEvents::EventsController < ::ApplicationController
    requires_plugin 'texdem-events-core'

    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required

    def index
      raise Discourse::NotFound unless SiteSetting.texdem_events_enabled

      events = TexdemEvents::EventFetcher.new.fetch_events

      # Let texdem.org fetch this from the browser
      response.headers['Access-Control-Allow-Origin'] = 'https://texdem.org'
      render_json_dump(events)
    end
  end

module ::TexdemEvents
  class EventFetcher
    EVENT_TAG = "event".freeze

    def fetch_events
      category_ids = parse_category_ids(SiteSetting.texdem_events_category_ids)
      return [] if category_ids.empty?

      topics = Topic
        .joins(:tags)
        .where(category_id: category_ids)
        .where(visible: true, deleted_at: nil)
        .where(tags: { name: EVENT_TAG })
        .order("created_at DESC")
        .limit(SiteSetting.texdem_events_limit)

      topics.map { |topic| map_topic_to_event(topic) }.compact
    end

    private

    def parse_category_ids(raw)
      return [] if raw.blank?
      raw.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
    end

    # Tag conventions:
    #   date-YYYY-MM-DD
    #   time-HH:MM
    #   county-harris
    #   loc-katy-tx
    def map_topic_to_event(topic)
      tags = topic.tags.map(&:name)

      date_tag   = tags.find { |t| t.start_with?("date-") }
      time_tag   = tags.find { |t| t.start_with?("time-") }
      county_tag = tags.find { |t| t.start_with?("county-") }
      loc_tag    = tags.find { |t| t.start_with?("loc-") }

      date = date_tag&.sub("date-", "")
      time = time_tag&.sub("time-", "") || "00:00"

      start_iso =
        if date
          "#{date}T#{time}:00"
        else
          topic.created_at&.iso8601
        end

      {
        id:       "discourse-#{topic.id}",
        title:    topic.title,
        start:    start_iso,
        end:      nil,
        county:   county_tag&.sub("county-", "")&.titleize,
        location: loc_tag&.sub("loc-", "")&.tr("-", " "),
        url:      topic.url
      }
    end
  end
end
