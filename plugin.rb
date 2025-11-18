# name: texdem-events-core
# about: Minimal backend-only JSON endpoint for TexDem events, based on selected Discourse categories.
# version: 0.7.0
# authors: TexDem
# url: https://texdem.org

require 'net/http'
require 'uri'
require 'json'
require 'digest/sha1'

enabled_site_setting :texdem_events_enabled

after_initialize do
  #
  # NAMESPACE
  #
  module ::TexdemEvents
  end

  #
  # RSVP MODEL
  #
  class ::TexdemEvents::Rsvp < ActiveRecord::Base
    self.table_name = "texdem_event_rsvps"

    belongs_to :topic

    validates :topic_id,   presence: true
    validates :first_name, presence: true
    validates :last_name,  presence: true
    validates :email,      presence: true

    validates :guests,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 },
      allow_nil: true
  end

  #
  # GLOBAL CORS FOR /texdem-events*
  #
  ::ApplicationController.class_eval do
    before_action :texdem_events_cors_headers,
                  if: -> { request.path&.start_with?("/texdem-events") }

    private

    def texdem_events_cors_headers
      # Allow texdem.org (and www) to call these endpoints from the browser
      origin = request.headers['Origin']
      allowed = ["https://texdem.org", "https://www.texdem.org"]

      if origin.present? && allowed.include?(origin)
        response.headers['Access-Control-Allow-Origin'] = origin
      end

      response.headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
      response.headers['Access-Control-Allow-Headers'] = 'Content-Type'
    end
  end

  #
  # EVENTS JSON CONTROLLER
  #
  class ::TexdemEvents::EventsController < ::ApplicationController
    requires_plugin 'texdem-events-core'

    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required

    def index
      raise Discourse::NotFound unless SiteSetting.texdem_events_enabled

      events = ::TexdemEvents::EventFetcher.new.fetch_events
      render_json_dump(events)
    end
  end

  #
  # RSVP SUBMISSION + STATS CONTROLLER
  #
  class ::TexdemEvents::RsvpsController < ::ApplicationController
    requires_plugin 'texdem-events-core'

    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required
    skip_before_action :verify_authenticity_token  # allow external POST

    #
    # OPTIONS /texdem-events/:topic_id/rsvp
    # CORS preflight
    #
    def options
      head :no_content
    end

    #
    # GET /texdem-events/:topic_id/rsvp
    # Returns aggregated RSVP stats for a topic.
    #
    def show
      topic_id = params[:topic_id].to_i
      topic    = Topic.find_by(id: topic_id)

      return render_json_error("Invalid topic") if topic.nil?

      rsvps = ::TexdemEvents::Rsvp.where(topic_id: topic_id)

      rsvp_count  = rsvps.count
      guest_count = rsvps.sum("COALESCE(guests, 0)")

      render json: {
        success: true,
        topic_id: topic_id,
        rsvp_count: rsvp_count,
        guest_count: guest_count
      }
    end

    #
    # POST /texdem-events/:topic_id/rsvp
    # Create a new RSVP row for an event.
    #
    def create
      topic_id = params[:topic_id].to_i
      topic    = Topic.find_by(id: topic_id)

      return render_json_error("Invalid topic") if topic.nil?

      # Required fields
      first = params[:first_name]&.strip
      last  = params[:last_name]&.strip
      email = params[:email]&.strip

      unless first.present? && last.present? && email.present?
        return render_json_error("Missing required fields")
      end

      guests_param = params[:guests]
      guests_value =
        if guests_param.present?
          begin
            Integer(guests_param)
          rescue ArgumentError
            return render_json_error("Guests must be an integer")
          end
        else
          nil
        end

      rsvp = ::TexdemEvents::Rsvp.new(
        topic_id:   topic_id,
        first_name: first,
        last_name:  last,
        email:      email,
        phone:      params[:phone],
        address:    params[:address],
        guests:     guests_value
      )

      if rsvp.save
        render json: {
          success: true,
          message: "RSVP recorded",
          rsvp_count: ::TexdemEvents::Rsvp.where(topic_id: topic_id).count
        }
      else
        render_json_error(rsvp.errors.full_messages.join(", "))
      end
    end

    private

    def render_json_error(msg)
      render json: { success: false, error: msg }, status: 422
    end
  end

  #
  # EVENT FETCHER
  #
  class ::TexdemEvents::EventFetcher
    EVENT_TAG = "event".freeze
    SERVER_TIME_ZONE = ActiveSupport::TimeZone["America/Chicago"]

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

    # Helper to pull a field from the "Event Details" block.
    # Matches lines like:
    #   * **Date:** 2025-12-09
    #   * **Start time:** 06:00 PM
    #   * **Address:** 4455 University Dr, Houston, TX 77204
    #   * **County:** Harris
    #   * **Location name:** Something
    def extract_event_detail(topic, label)
      raw = topic.first_post&.raw
      return nil if raw.blank?

      raw.each_line do |line|
        # Markdown bullet with bold label
        if line =~ /\*\*#{Regexp.escape(label)}:\*\*\s*(.+)\s*$/i
          return $1.strip
        # Plain "Label: value"
        elsif line =~ /#{Regexp.escape(label)}:\s*(.+)\s*$/i
          return $1.strip
        end
      end

      nil
    end

    # Geocode a location string using Nominatim and cache the result.
    #
    # Returns [lat, lng] floats, or [nil, nil] if not found.
    def geocode_location(location)
      return [nil, nil] if location.blank?

      cache_key = "texdem_events:geocode:#{Digest::SHA1.hexdigest(location)}"

      if (cached = Discourse.cache.read(cache_key))
        return cached
      end

      begin
        uri = URI("https://nominatim.openstreetmap.org/search")
        params = { q: location, format: "json", limit: 1 }
        uri.query = URI.encode_www_form(params)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.read_timeout = 3
        http.open_timeout = 3

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "TexDemEventsCore/0.7.0 (forum.texdem.org)"

        response = http.request(request)
        return [nil, nil] unless response.is_a?(Net::HTTPSuccess)

        json = JSON.parse(response.body)
        first = json.first
        return [nil, nil] unless first

        lat = first["lat"].to_f
        lng = first["lon"].to_f

        # Cache for a week so we don't re-hit the API constantly
        Discourse.cache.write(cache_key, [lat, lng], expires_in: 7.days)

        [lat, lng]
      rescue => e
        Rails.logger.warn(
          "TexdemEvents: geocode failed for #{location.inspect}: " \
          "#{e.class} #{e.message}"
        )
        [nil, nil]
      end
    end

    def rsvp_count_for(topic)
      ::TexdemEvents::Rsvp.where(topic_id: topic.id).count
    rescue StandardError
      # If the model or table isn't ready yet, don't break the JSON endpoint.
      0
    end

    def map_topic_to_event(topic)
      tags = topic.tags.map(&:name)

      # Only include topics explicitly tagged as events
      return nil unless tags.include?(EVENT_TAG)

      # Try tags first, then fall back to Event Details content.
      date_tag   = tags.find { |t| t.start_with?("date-") }
      time_tag   = tags.find { |t| t.start_with?("time-") }
      county_tag = tags.find { |t| t.start_with?("county-") }
      loc_tag    = tags.find { |t| t.start_with?("loc-") }

      date_from_tag   = date_tag&.sub("date-", "")
      time_from_tag   = time_tag&.sub("time-", "")
      county_from_tag = county_tag&.sub("county-", "")&.titleize
      loc_from_tag    = loc_tag&.sub("loc-", "")&.tr("-", " ")

      # From Event Details block
      date_from_body       = extract_event_detail(topic, "Date")
      start_time_from_body = extract_event_detail(topic, "Start time")
      county_from_body     = extract_event_detail(topic, "County")
      loc_name_from_body   = extract_event_detail(topic, "Location name")
      address_from_body    = extract_event_detail(topic, "Address")

      # Date/time: prefer Event Details; fall back to tags; then created_at
      date_str = date_from_body || date_from_tag
      time_str = start_time_from_body || time_from_tag || "00:00"

      start_time =
        if date_str
          begin
            SERVER_TIME_ZONE.parse("#{date_str} #{time_str}")
          rescue
            topic.created_at.in_time_zone(SERVER_TIME_ZONE)
          end
        else
          topic.created_at.in_time_zone(SERVER_TIME_ZONE)
        end

      # County: prefer Event Details, then tag
      county = (county_from_body || county_from_tag)&.strip
      county = county.titleize if county

      # What we *want* to show in JSON
      display_location_name =
        loc_name_from_body.presence ||
        loc_from_tag

      display_address = address_from_body

      # Legacy combined location field (used by v3 front-ends)
      location =
        display_address ||
        display_location_name ||
        loc_from_tag

      # Geocoding base string
      geocode_base =
        display_address ||
        display_location_name ||
        loc_from_tag

      geo_query = geocode_base

      Rails.logger.warn(
        "TexdemEvents geocode: topic=#{topic.id} title=#{topic.title.inspect} " \
        "geocode_base=#{geocode_base.inspect} county=#{county.inspect}"
      )

      lat, lng = geocode_location(geo_query)

      # Root / host org
      cat       = topic.category
      root      = cat&.parent_category || cat
      root_name = root&.name

      {
        id:            "discourse-#{topic.id}",
        topic_id:      topic.id,
        title:         topic.title,
        start:         start_time&.iso8601,
        end:           nil,
        county:        county,
        location:      location,               # combined / legacy
        location_name: display_location_name,  # v4+
        address:       display_address,        # v4+
        lat:           lat,
        lng:           lng,
        root_category: root_name,
        url:           topic.url,
        timezone:      (
          SERVER_TIME_ZONE.respond_to?(:tzinfo) ?
            SERVER_TIME_ZONE.tzinfo.name :
            SERVER_TIME_ZONE.name
        ),
        rsvp_count:    rsvp_count_for(topic),
        debug_version: "texdem-events-v7"
      }
    end
  end

  #
  # ROUTES
  #
  Discourse::Application.routes.append do
    # GET /texdem-events.json
    get  "/texdem-events" => "texdem_events/events#index",
         defaults: { format: :json }

    # GET /texdem-events/:topic_id/rsvp (stats)
    get  "/texdem-events/:topic_id/rsvp" => "texdem_events/rsvps#show",
         defaults: { format: :json }

    # POST /texdem-events/:topic_id/rsvp (create)
    post "/texdem-events/:topic_id/rsvp" => "texdem_events/rsvps#create",
         defaults: { format: :json }

    # OPTIONS /texdem-events/:topic_id/rsvp (CORS preflight)
    match "/texdem-events/:topic_id/rsvp" => "texdem_events/rsvps#options",
          via: [:options],
          defaults: { format: :json }
  end
end
