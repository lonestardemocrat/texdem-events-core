# name: texdem-events-core
# about: Minimal backend-only JSON endpoint for TexDem events, based on selected Discourse categories.
# version: 0.8.0
# authors: TexDem
# url: https://texdem.org

enabled_site_setting :texdem_events_enabled

after_initialize do
  require 'net/http'
  require 'uri'
  require 'json'
  require 'digest/sha1'

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
    SERVER_TIME_ZONE = ActiveSupport::TimeZone["America/Chicago"]

    # Main entry point used by the JSON controller.
    #
    # Uses the official Discourse Calendar plugin:
    # - Only posts that have a row in discourse_calendar_calendar_events
    # - Only posts that contain <!-- texdem-visibility: public -->
    def fetch_events
      return [] unless SiteSetting.texdem_events_enabled

      # If the calendar plugin/constant isn't available, fail gracefully
      unless defined?(DiscourseCalendar) && defined?(DiscourseCalendar::CalendarEvent)
        Rails.logger.warn(
          "TexdemEvents: DiscourseCalendar::CalendarEvent not available; returning []."
        )
        return []
      end

      category_ids = parse_category_ids(SiteSetting.texdem_events_category_ids)

      begin
        posts = Post
          .joins(:topic)
          .joins("INNER JOIN discourse_calendar_calendar_events dcc ON dcc.post_id = posts.id")
          .where("topics.visible = ? AND topics.deleted_at IS NULL", true)
          .where("posts.deleted_at IS NULL")
          .where("posts.raw LIKE '%texdem-visibility: public%'")

        if category_ids.present?
          posts = posts.where("topics.category_id IN (?)", category_ids)
        end
      rescue ActiveRecord::StatementInvalid => e
        # e.g. if discourse_calendar_calendar_events table is missing
        Rails.logger.warn(
          "TexdemEvents: calendar join failed (likely missing table): " \
          "#{e.class} #{e.message}"
        )
        return []
      end

      limit = SiteSetting.texdem_events_limit.to_i
      limit = 100 if limit <= 0

      # Oversample in case some posts are malformed and get filtered out
      posts = posts.order("posts.created_at DESC").limit(limit * 2)

      events = posts.map { |post| map_post_to_event(post) }.compact
      events = events.sort_by { |e| e[:start].to_s }

      # Respect configured limit on final JSON
      events.first(limit)
    end

    private

    # Parse a comma-separated list of category ids from a site setting.
    def parse_category_ids(raw)
      return [] if raw.blank?
      raw.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
    end

    # Helper to pull a field from the "Event Details" block in a raw post body.
    def extract_event_detail_from_raw(raw, label)
      return nil if raw.blank?

      raw.each_line do |line|
        # Markdown bullet with bold label
        if line =~ /\*\*#{Regexp.escape(label)}:\*\*\s*(.+)\s*$/i
          return Regexp.last_match(1).strip
        # Plain "Label: value"
        elsif line =~ /#{Regexp.escape(label)}:\s*(.+)\s*$/i
          return Regexp.last_match(1).strip
        end
      end

      nil
    end

    # Backwards-compatible helper if anything still calls with a topic.
    def extract_event_detail(topic, label)
      raw = topic.first_post&.raw
      extract_event_detail_from_raw(raw, label)
    end

    # Try to derive a human-readable event title from the post body.
    # Skip [date=...] lines and the **Event Details** header.
    def extract_event_title_from_raw(raw)
      return nil if raw.blank?

      raw.each_line do |line|
        line = line.strip
        next if line.blank?
        next if line.start_with?("[date=")
        next if line =~ /^\*\*Event Details\*\*/i

        return line
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
        request["User-Agent"] = "TexDemEventsCore/0.8.0 (forum.texdem.org)"

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

    # Core mapper: convert a single post into an event Hash (or nil if invalid).
    def map_post_to_event(post)
      raw = post.raw
      return nil if raw.blank?

      # Safety: only treat explicitly-public posts as events
      unless raw.include?("texdem-visibility: public")
        return nil
      end

      topic = post.topic
      return nil if topic.blank?

      # If calendar plugin/constant isn't available, bail on this post
      unless defined?(DiscourseCalendar) && defined?(DiscourseCalendar::CalendarEvent)
        return nil
      end

      # Use DiscourseCalendar::CalendarEvent for real timestamps + timezone
      calendar_event = DiscourseCalendar::CalendarEvent.find_by(post_id: post.id)

      unless calendar_event
        Rails.logger.warn(
          "TexdemEvents skipped post=#{post.id} topic=#{post.topic_id}: missing Calendar Event"
        )
        return nil
      end

      start_time = calendar_event.start   # UTC datetime
      end_time   = calendar_event.finish  # UTC datetime (nil if none)
      tz_name    = calendar_event.timezone.presence || SERVER_TIME_ZONE.name

      # Pull details from the Event Details block (if present)
      county_from_body   = extract_event_detail_from_raw(raw, "County")
      loc_name_from_body = extract_event_detail_from_raw(raw, "Location name")
      address_from_body  = extract_event_detail_from_raw(raw, "Address")

      # County
      county = county_from_body&.strip
      county = county.titleize if county.present?

      # What we want to show in JSON
      display_location_name = loc_name_from_body.presence
      display_address       = address_from_body

      # Legacy combined "location" field
      location =
        display_address ||
        display_location_name

      # Geocoding base string
      geocode_base =
        display_address ||
        display_location_name

      lat = nil
      lng = nil

      if geocode_base.present?
        Rails.logger.warn(
          "TexdemEvents geocode: topic=#{post.topic_id} post=#{post.id} title=#{topic.title.inspect} " \
          "geocode_base=#{geocode_base.inspect} county=#{county.inspect}"
        )

        lat, lng = geocode_location(geocode_base)
      end

      category        = topic.category
      parent_category = category&.parent_category
      root            = parent_category || category
      root_name       = root&.name

      event_title =
        extract_event_title_from_raw(raw) ||
        topic.title

      tags =
        begin
          topic.tags.map(&:name)
        rescue StandardError
          []
        end

      {
        id:                   "discourse-post-#{post.id}",
        post_id:              post.id,
        topic_id:             topic.id,
        topic_title:          topic.title,
        category_id:          category&.id,
        category_name:        category&.name,
        parent_category_name: parent_category&.name,
        title:                event_title,
        start:                start_time&.iso8601,
        end:                  end_time&.iso8601,
        county:               county,
        location:             location,             # combined / legacy
        location_name:        display_location_name,
        address:              display_address,
        lat:                  lat,
        lng:                  lng,
        root_category:        root_name,
        url:                  post.full_url,
        timezone:             tz_name,
        visibility:           "public",
        tags:                 tags,
        rsvp_count:           rsvp_count_for(topic),
        debug_version:        "texdem-events-v10"
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
