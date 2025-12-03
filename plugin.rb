# name: texdem-events-core
# about: Minimal backend-only JSON endpoint for TexDem events, based on selected Discourse categories.
# version: 0.11.0
# authors: TexDem
# url: https://texdem.org
# requires_plugin: discourse-calendar

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
      origin  = request.headers['Origin']
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
    #
    def options
      head :no_content
    end

    #
    # GET /texdem-events/:topic_id/rsvp
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
    #
    def create
      topic_id = params[:topic_id].to_i
      topic    = Topic.find_by(id: topic_id)

      return render_json_error("Invalid topic") if topic.nil?

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
  # EVENT FETCHER 0.11.0 (SUPER-PERMISSIVE DEBUG VERSION)
  #
  class ::TexdemEvents::EventFetcher
    SERVER_TIME_ZONE = ActiveSupport::TimeZone["America/Chicago"]

    def fetch_events
      return [] unless SiteSetting.texdem_events_enabled

      limit = SiteSetting.texdem_events_limit.to_i
      limit = 100 if limit <= 0

      # 🔓 Debug: NO category / tag / visibility / calendar table restrictions.
      posts = Post
        .joins(:topic)
        .where("topics.visible = ? AND topics.deleted_at IS NULL", true)
        .where("posts.deleted_at IS NULL")
        .order("posts.created_at DESC")
        .limit(limit * 2)

      events = posts.map { |post| map_post_to_event(post) }.compact
      events = events.sort_by { |e| e[:start].to_s }

      events.first(limit)
    end

    private

    #
    # Generic label extractor from raw (Markdown or plain)
    #
    def extract_event_detail_from_raw(raw, label)
      return nil if raw.blank?

      raw.each_line do |line|
        # Bold label: **Label:** value
        if line =~ /\*\*#{Regexp.escape(label)}:\*\*\s*(.+)\s*$/i
          return Regexp.last_match(1).strip
        end

        # Plain: Label: value
        if line =~ /#{Regexp.escape(label)}:\s*(.+)\s*$/i
          return Regexp.last_match(1).strip
        end
      end

      nil
    end

    def extract_event_title_from_raw(raw)
      return nil if raw.blank?

      raw.each_line do |line|
        line = line.strip
        next if line.blank?
        next if line.start_with?("[date") # [date=...] or [date-range ...]
        next if line =~ /^\*\*Event Details\*\*/i

        return line
      end

      nil
    end

    #
    # Date/time parsing helpers
    #
    def parse_datetime_with_zone(str, tz_name)
      return nil if str.blank?
      zone = ActiveSupport::TimeZone[tz_name] || SERVER_TIME_ZONE
      zone.parse(str)
    rescue StandardError
      nil
    end

    def parse_times_from_raw(raw, post)
      tz_name = SERVER_TIME_ZONE.name

      # 1) [date-range from=2025-12-11T17:00:00 to=2025-12-11T18:00:00 timezone="America/Chicago"]
      if raw =~ /\[date-range\s+from=(?<from>[^\s\]]+)\s+to=(?<to>[^\s\]]+)(?:\s+timezone="(?<tz>[^"]+)")?/i
        from_str = Regexp.last_match(:from)
        to_str   = Regexp.last_match(:to)
        tz       = Regexp.last_match(:tz)
        tz_name  = tz if tz.present?

        start_time = parse_datetime_with_zone(from_str, tz_name) ||
                     post.created_at.in_time_zone(SERVER_TIME_ZONE)
        end_time   = parse_datetime_with_zone(to_str, tz_name) ||
                     (start_time + 1.hour)

        return [start_time, end_time, tz_name]
      end

      # 2) [date=YYYY-MM-DD time=HHMMSS timezone="America/Chicago"]
      if raw =~ /\[date=(?<date>\d{4}-\d{2}-\d{2})(?:\s+time=(?<time>\d{6}))?(?:\s+timezone="(?<tz>[^"]+)")?\]/i
        date_str = Regexp.last_match(:date)
        time_raw = Regexp.last_match(:time) || "000000"
        tz       = Regexp.last_match(:tz)
        tz_name  = tz if tz.present?

        hh = time_raw[0, 2]
        mm = time_raw[2, 2]
        ss = time_raw[4, 2]

        zone = ActiveSupport::TimeZone[tz_name] || SERVER_TIME_ZONE
        start_time = zone.parse("#{date_str} #{hh}:#{mm}:#{ss}")
        end_time   = start_time + 1.hour

        return [start_time, end_time, tz_name]
      end

      # 3) Fallback: use created_at if no calendar markup found
      start_time = post.created_at.in_time_zone(SERVER_TIME_ZONE)
      end_time   = start_time + 1.hour

      [start_time, end_time, tz_name]
    end

    #
    # Geocoding
    #
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
        request["User-Agent"] = "TexDemEventsCore/0.11.0 (forum.texdem.org)"

        response = http.request(request)
        return [nil, nil] unless response.is_a?(Net::HTTPSuccess)

        json  = JSON.parse(response.body)
        first = json.first
        return [nil, nil] unless first

        lat = first["lat"].to_f
        lng = first["lon"].to_f

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
      0
    end

    #
    # Core mapper: VERY PERMISSIVE.
    #
    def map_post_to_event(post)
      raw = post.raw
      return nil if raw.blank?

      topic = post.topic
      return nil if topic.blank?

      start_time, end_time, tz_name = parse_times_from_raw(raw, post)

      county_from_body   = extract_event_detail_from_raw(raw, "County")
      loc_name_from_body =
        extract_event_detail_from_raw(raw, "Location") ||
        extract_event_detail_from_raw(raw, "Location name")
      address_from_body  = extract_event_detail_from_raw(raw, "Address")
      summary_from_body  = extract_event_detail_from_raw(raw, "Summary")
      url_from_body      =
        extract_event_detail_from_raw(raw, "RSVP / More info") ||
        extract_event_detail_from_raw(raw, "URL")
      graphic_from_body  = extract_event_detail_from_raw(raw, "Graphic")

      county = county_from_body&.strip
      county = county.titleize if county.present?

      display_location_name = loc_name_from_body&.strip
      display_address       = address_from_body&.strip

      geocode_base = display_address.presence || display_location_name
      lat = nil
      lng = nil

      if geocode_base.present?
        Rails.logger.warn(
          "TexdemEvents geocode: topic=#{post.topic_id} post=#{post.id} " \
          "title=#{topic.title.inspect} geocode_base=#{geocode_base.inspect} " \
          "county=#{county.inspect}"
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

      summary =
        if summary_from_body.present?
          summary_from_body[0, 250]
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
        location_name:        display_location_name,
        address:              display_address,
        lat:                  lat,
        lng:                  lng,
        root_category:        root_name,
        url:                  post.full_url,
        timezone:             tz_name,
        visibility:           "debug-all",
        tags:                 tags,
        rsvp_count:           rsvp_count_for(topic),
        summary:              summary,
        external_url:         url_from_body&.strip,
        graphic_url:          graphic_from_body&.strip,
        rsvp_enabled:         false,
        debug_version:        "texdem-events-v0.11.0"
      }
    end
  end

  #
  # ROUTES
  #
  Discourse::Application.routes.append do
    get  "/texdem-events" => "texdem_events/events#index",
         defaults: { format: :json }

    get  "/texdem-events/:topic_id/rsvp" => "texdem_events/rsvps#show",
         defaults: { format: :json }

    post "/texdem-events/:topic_id/rsvp" => "texdem_events/rsvps#create",
         defaults: { format: :json }

    match "/texdem-events/:topic_id/rsvp" => "texdem_events/rsvps#options",
          via: [:options],
          defaults: { format: :json }
  end
end
