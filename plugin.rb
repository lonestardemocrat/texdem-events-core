# name: texdem-events-core
# about: Minimal backend-only JSON endpoint for TexDem events, based on selected Discourse categories.
# version: 0.4.0
# authors: TexDem
# url: https://texdem.org

require 'net/http'
require 'uri'
require 'json'

enabled_site_setting :texdem_events_enabled

after_initialize do
  module ::TexdemEvents
  end

  #
  # CONTROLLER
  #
  class ::TexdemEvents::EventsController < ::ApplicationController
    requires_plugin 'texdem-events-core'

    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required

    def index
      raise Discourse::NotFound unless SiteSetting.texdem_events_enabled

      events = TexdemEvents::EventFetcher.new.fetch_events

      # Allow texdem.org to fetch this JSON from the browser
      response.headers['Access-Control-Allow-Origin'] = 'https://texdem.org'
      render_json_dump(events)
    end
  end

  #
  # EVENT FETCHER
  #
  module ::TexdemEvents
    class EventFetcher
      EVENT_TAG = "event".freeze

      def fetch_events
        category_ids = parse_category_ids(SiteSetting.texdem_events_category_ids)
        return [] if category_ids.empty?

        topics = Topic
          .where(category_id: category_ids)
          .where(visible: true, deleted_at: nil)
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
      #   event
      #   date-YYYY-MM-DD
      #   time-HH:MM
      #   county-harris
      #   loc-katy-tx
      #
      # Content convention:
      #   A line in the first post like:
      #   "Address: 4455 University Dr, Houston, TX 77204"
      #
      def map_topic_to_event(topic)
        tags = topic.tags.map(&:name)

        # Only include topics explicitly tagged as events
        return nil unless tags.include?(EVENT_TAG)

        date_tag   = tags.find { |t| t.start_with?("date-") }
        time_tag   = tags.find { |t| t.start_with?("time-") }
        county_tag = tags.find { |t| t.start_with?("county-") }
        loc_tag    = tags.find { |t| t.start_with?("loc-") }

        date = date_tag&.sub("date-", "")
        time = time_tag&.sub("time-", "") || "00:00"

        # Build start time from date+time tags if present, otherwise fall back
        start_time =
          if date
            begin
              Time.zone.parse("#{date} #{time}")
            rescue
              topic.created_at
            end
          else
            topic.created_at
          end

        # Find root category: parent if it exists, otherwise the topic's own category
        cat        = topic.category
        root       = cat&.parent_category || cat
        root_name  = root&.name

        # County + location label
        county   = county_tag&.sub("county-", "")&.titleize

        # Prefer loc- tag for location label; if missing, fall back to Address:
        address  = extract_address(topic)
        location_from_tag = loc_tag&.sub("loc-", "")&.tr("-", " ")
        location = location_from_tag || address

        # Get latitude / longitude from Address: (auto-geocode)
        latitude, longitude = geocode_address(address)

        {
          id:            "discourse-#{topic.id}",
          title:         topic.title,
          start:         start_time&.iso8601,
          end:           nil,
          county:        county,
          location:      location,
          root_category: root_name,
          latitude:      latitude,
          longitude:     longitude,
          url:           topic.url
        }
      end

      # Extract "Address: ..." line from the first post raw markdown
      def extract_address(topic)
        raw = topic.first_post&.raw
        return nil if raw.blank?

        raw.each_line do |line|
          if line =~ /Address:\s*(.+)\s*$/i
            return $1.strip
          end
        end

        nil
      end

      # Geocode an address using OpenStreetMap Nominatim.
      # Returns [lat, lng] or [nil, nil] on failure.
      def geocode_address(address)
        return [nil, nil] if address.blank?

        begin
          uri = URI("https://nominatim.openstreetmap.org/search")
          params = {
            format: "json",
            q: address,
            limit: 1
          }
          uri.query = URI.encode_www_form(params)

          req = Net::HTTP::Get.new(uri)
          # Nominatim asks for a descriptive User-Agent
          req["User-Agent"] = "TexDemEventsCore/0.4 (contact@texdem.org)"

          res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
            http.request(req)
          end

          return [nil, nil] unless res.is_a?(Net::HTTPSuccess)

          data = JSON.parse(res.body)
          first = data.first
          return [nil, nil] unless first

          [first["lat"].to_f, first["lon"].to_f]
        rescue => e
          Rails.logger.warn("TexDem geocode failed for '#{address}': #{e}")
          [nil, nil]
        end
      end
    end
  end

  #
  # ROUTE
  #
  Discourse::Application.routes.append do
    # GET /texdem-events.json
    get "/texdem-events" => "texdem_events/events#index", defaults: { format: :json }
  end
end
