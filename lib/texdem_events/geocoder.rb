# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "digest/sha1"

module ::TexdemEvents
  class Geocoder
    TEXAS_BBOX = {
      min_lat: 25.8371,  # south TX
      max_lat: 36.5007,  # north TX
      min_lng: -106.6456, # west TX
      max_lng: -93.5080   # east TX
    }.freeze

    def self.geocode(location)
      return [nil, nil] if location.blank?

      cache_key = "texdem_events:geocode:#{Digest::SHA1.hexdigest(location)}"
      if (cached = Discourse.cache.read(cache_key))
        return cached
      end

      lat, lng = nil, nil

      google_key = SiteSetting.try(:texdem_google_maps_api_key)
      if google_key.present?
        lat, lng = geocode_with_google(location, google_key)
      end

      if lat.nil? || lng.nil?
        lat, lng = geocode_with_nominatim(location)
      end

      if lat && lng
        # Hard filter: must land in Texas bbox
        unless in_texas_bbox?(lat, lng)
          lat = nil
          lng = nil
        end
      end

      Discourse.cache.write(cache_key, [lat, lng], expires_in: 7.days)
      [lat, lng]
    end

    def self.in_texas_bbox?(lat, lng)
      lat = lat.to_f
      lng = lng.to_f
      lat >= TEXAS_BBOX[:min_lat] && lat <= TEXAS_BBOX[:max_lat] &&
        lng >= TEXAS_BBOX[:min_lng] && lng <= TEXAS_BBOX[:max_lng]
    end

    def self.geocode_with_google(location, api_key)
      uri = URI("https://maps.googleapis.com/maps/api/geocode/json")
      uri.query = URI.encode_www_form({ address: location, key: api_key })

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 8
      http.open_timeout = 8

      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "TexDemEventsCore/0.13.0 (forum.texdem.org)"

      res = http.request(req)
      return [nil, nil] unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body)
      return [nil, nil] unless data["status"] == "OK"

      first = data["results"]&.first
      loc = first&.dig("geometry", "location")
      return [nil, nil] unless loc

      [loc["lat"].to_f, loc["lng"].to_f]
    rescue
      [nil, nil]
    end

    def self.geocode_with_nominatim(location)
      uri = URI("https://nominatim.openstreetmap.org/search")
      uri.query = URI.encode_www_form({
        q: location,
        format: "json",
        limit: 1
      })

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 8
      http.open_timeout = 8

      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "TexDemEventsCore/0.13.0 (forum.texdem.org)"

      res = http.request(req)
      return [nil, nil] unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body)
      first = data&.first
      return [nil, nil] unless first

      [first["lat"].to_f, first["lon"].to_f]
    rescue
      [nil, nil]
    end
  end
end
