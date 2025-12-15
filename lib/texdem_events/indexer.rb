# frozen_string_literal: true

module ::TexdemEvents
  class Indexer
    SERVER_TZ = ActiveSupport::TimeZone["America/Chicago"]

    def self.reindex_post!(post_id)
      post = Post.find_by(id: post_id)
      return if post.nil? || post.deleted_at.present?

      topic = post.topic
      return if topic.nil? || topic.deleted_at.present?
      return unless topic.visible # IMPORTANT: unlisted/unvisible should not index

      raw = post.raw.to_s
      return if raw.blank?

      visibility = extract_field(raw, "Visibility")
      visibility = visibility.to_s.strip.downcase
      return unless visibility == "public"

      title = extract_title(raw) || topic.title.to_s

      starts_at, ends_at, tz = parse_times_from_raw(raw, post)

      city  = extract_field(raw, "City")&.strip
      state = extract_field(raw, "State")&.strip
      zip   = (extract_field(raw, "ZIP") || extract_field(raw, "Zip"))&.strip

      # Default state/country to Texas/USA if missing
      state   = SiteSetting.texdem_events_default_state if state.blank?
      country = SiteSetting.texdem_events_default_country

      location_name = (extract_field(raw, "Location") || extract_field(raw, "Location name"))&.strip
      address       = extract_field(raw, "Address")&.strip

      external_url = (extract_field(raw, "RSVP / More info") || extract_field(raw, "URL"))&.strip
      graphic_url  = extract_field(raw, "Graphic")&.strip

      # Build query once (used only if we decide to geocode)
      geocode_query = build_geocode_query(
        address: address,
        location_name: location_name,
        city: city,
        state: state,
        zip: zip,
        country: country
      )

      # --- PHYSICAL LOCATION GUARD ---
      # If we don't have a real-world location, do not geocode (prevents "plausible but wrong" pins).
      has_physical_location =
        address.present? ||
        (city.present? && state.present?)

      lat = nil
      lng = nil

      if has_physical_location && geocode_query.present?
        raw_lat, raw_lng = ::TexdemEvents::Geocoder.geocode(geocode_query)

        lat = normalize_coord(raw_lat)
        lng = normalize_coord(raw_lng)

        unless valid_lat_lng?(lat, lng)
          Rails.logger.info(
            "[TexdemEvents] Dropping invalid coords for post_id=#{post.id} query=#{geocode_query.inspect} raw=#{[raw_lat, raw_lng].inspect}"
          )
          lat = nil
          lng = nil
        end
      end
      # --------------------------------

      row = ::TexdemEvents::EventIndex.find_or_initialize_by(post_id: post.id)

      row.topic_id      = topic.id
      row.category_id   = topic.category_id
      row.visibility    = "public"
      row.title         = title
      row.starts_at     = starts_at
      row.ends_at       = ends_at
      row.timezone      = tz
      row.location_name = location_name
      row.address       = address
      row.city          = city
      row.state         = state
      row.zip           = zip
      row.lat           = lat
      row.lng           = lng
      row.external_url  = external_url
      row.graphic_url   = graphic_url
      row.indexed_at    = Time.zone.now

      row.save!
    rescue => e
      Rails.logger.warn("TexdemEvents Indexer failed post_id=#{post_id}: #{e.class} #{e.message}")
    end

    def self.deindex_post!(post_id)
      ::TexdemEvents::EventIndex.where(post_id: post_id).delete_all
    end

    # Treat nil/blank/"0"/"0.0" as missing; otherwise coerce to Float
    def self.normalize_coord(value)
      return nil if value.nil?

      s = value.to_s.strip
      return nil if s.blank? || s == "0" || s == "0.0"

      Float(s)
    rescue ArgumentError, TypeError
      nil
    end

    def self.valid_lat_lng?(lat, lng)
      return false if lat.nil? || lng.nil?
      lat.between?(-90, 90) && lng.between?(-180, 180)
    end

    def self.extract_field(raw, label)
      raw.each_line do |line|
        l = line.strip
        l.sub!(/^\-\s*/, "")

        if l =~ /\*\*#{Regexp.escape(label)}:\*\*\s*(.+)\s*$/i
          return Regexp.last_match(1).strip
        end
        if l =~ /^#{Regexp.escape(label)}:\s*(.+)\s*$/i
          return Regexp.last_match(1).strip
        end
      end
      nil
    end

    def self.extract_title(raw)
      raw.each_line do |line|
        t = line.strip
        next if t.blank?
        next if t.start_with?("[date")
        next if t.start_with?("[date-range")
        next if t =~ /^\*\*Event Details\*\*/i
        return t
      end
      nil
    end

    def self.parse_times_from_raw(raw, post)
      tz_name = SERVER_TZ.name

      if raw =~ /\[date-range\s+from=(?<from>[^\s\]]+)\s+to=(?<to>[^\s\]]+)(?:\s+timezone="(?<tz>[^"]+)")?/i
        from_str = Regexp.last_match(:from)
        to_str   = Regexp.last_match(:to)
        tz       = Regexp.last_match(:tz)
        tz_name  = tz if tz.present?

        start_time = parse_datetime(from_str, tz_name) || post.created_at.in_time_zone(SERVER_TZ)
        end_time   = parse_datetime(to_str, tz_name)   || (start_time + 1.hour)
        return [start_time, end_time, tz_name]
      end

      if raw =~ /\[date=(?<date>\d{4}-\d{2}-\d{2})(?:\s+time=(?<time>[0-9:]+))?(?:\s+timezone="(?<tz>[^"]+)")?\]/i
        date_str = Regexp.last_match(:date)
        time_raw = Regexp.last_match(:time) || "000000"
        tz       = Regexp.last_match(:tz)
        tz_name  = tz if tz.present?

        digits = time_raw.delete(":")
        hh, mm, ss =
          case digits.length
          when 2 then [digits, "00", "00"]
          when 4 then [digits[0,2], digits[2,2], "00"]
          when 6 then [digits[0,2], digits[2,2], digits[4,2]]
          else ["00","00","00"]
          end

        zone = ActiveSupport::TimeZone[tz_name] || SERVER_TZ
        start_time = zone.parse("#{date_str} #{hh}:#{mm}:#{ss}")
        end_time   = start_time + 1.hour
        return [start_time, end_time, tz_name]
      end

      start_time = post.created_at.in_time_zone(SERVER_TZ)
      [start_time, start_time + 1.hour, tz_name]
    end

    def self.parse_datetime(str, tz_name)
      zone = ActiveSupport::TimeZone[tz_name] || SERVER_TZ
      zone.parse(str)
    rescue
      nil
    end

    def self.build_geocode_query(address:, location_name:, city:, state:, zip:, country:)
      base = address.presence || location_name
      parts = []
      parts << base if base.present?
      parts << city if city.present?
      parts << state if state.present?
      parts << zip if zip.present?
      parts << country if country.present?
      parts.compact.join(", ")
    end
  end
end
