# frozen_string_literal: true

module ::TexdemEvents
  class Indexer
    SERVER_TZ = ActiveSupport::TimeZone["America/Chicago"]

    def self.reindex_post!(post_id)
      post = Post.find_by(id: post_id)
      return if post.blank? || post.deleted_at.present?

      topic = post.topic
      return if topic.blank? || topic.deleted_at.present?
      return unless topic.visible
      return if topic.unlisted? # <- this was your “unlisted” gotcha

      raw = post.raw.to_s
      return if raw.blank?

      visibility = extract_detail(raw, "Visibility")
      return unless visibility&.strip&.casecmp("public")&.zero?

      title = extract_title(raw) || topic.title.to_s

      starts_at, ends_at, tz = parse_times(raw, post)
      return if starts_at.blank?

      location_name = extract_detail(raw, "Location") || extract_detail(raw, "Location name")
      address       = extract_detail(raw, "Address")
      city          = extract_detail(raw, "City")
      state         = extract_detail(raw, "State")
      zip           = extract_detail(raw, "ZIP") || extract_detail(raw, "Zip")
      external_url  = extract_detail(raw, "RSVP / More info") || extract_detail(raw, "URL")
      graphic_url   = extract_detail(raw, "Graphic")

      # If state is missing, we assume TX for your use-case.
      # This stops “random world hits” when address is incomplete.
      inferred_state = state.presence || "TX"

      # Only attempt geocode if we have something reasonable.
      # (We’ll keep it cheap; you can make this async later.)
      lat = nil
      lng = nil

      geocode_base = [address.presence || location_name, city, inferred_state, zip].compact.join(", ")
      geocode_base = "#{geocode_base}, USA" if geocode_base.present? && geocode_base !~ /\bUSA\b/i

      # For now: NO geocoding during indexing (fast path).
      # If you want, we’ll add a separate job later to fill lat/lng.

      row = ::TexdemEvents::EventIndex.find_or_initialize_by(post_id: post.id)
      row.topic_id       = topic.id
      row.category_id    = topic.category_id
      row.title          = title
      row.starts_at      = starts_at
      row.ends_at        = ends_at
      row.timezone       = tz
      row.location_name  = location_name
      row.address        = address
      row.city           = city
      row.state          = inferred_state
      row.zip            = zip
      row.visibility     = "public"
      row.lat            = lat
      row.lng            = lng
      row.external_url   = external_url
      row.graphic_url    = graphic_url
      row.source         = "post"
      row.save!
    end

    def self.extract_title(raw)
      raw.each_line do |line|
        l = line.strip
        next if l.blank?
        next if l.start_with?("[date")
        next if l =~ /^\*\*Event Details\*\*/i
        return l
      end
      nil
    end

    def self.extract_detail(raw, label)
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

    def self.parse_times(raw, post)
      tz_name = SERVER_TZ.name

      if raw =~ /\[date=(?<date>\d{4}-\d{2}-\d{2})(?:\s+time=(?<time>[0-9:]+))?(?:\s+timezone="(?<tz>[^"]+)")?\]/i
        date_str = Regexp.last_match(:date)
        time_raw = (Regexp.last_match(:time) || "000000")
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
        starts_at = zone.parse("#{date_str} #{hh}:#{mm}:#{ss}")
        ends_at   = starts_at + 1.hour
        return [starts_at, ends_at, tz_name]
      end

      starts_at = post.created_at.in_time_zone(SERVER_TZ)
      [starts_at, starts_at + 1.hour, tz_name]
    rescue
      [nil, nil, tz_name]
    end
  end
end
