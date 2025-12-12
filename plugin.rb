# frozen_string_literal: true

# name: texdem-events-core
# about: Fast indexed JSON endpoint for TexDem public events
# version: 0.13.0
# authors: TexDem
# url: https://texdem.org
# requires_plugin: discourse-calendar

enabled_site_setting :texdem_events_enabled

after_initialize do
  require_relative "app/models/texdem_events/event_index"
  require_relative "lib/texdem_events/geocoder"
  require_relative "lib/texdem_events/indexer"

  # CORS for /texdem-events*
  ::ApplicationController.class_eval do
    before_action :texdem_events_cors_headers,
                  if: -> { request.path&.start_with?("/texdem-events") }

    private

    def texdem_events_cors_headers
      origin  = request.headers["Origin"]
      allowed = ["https://texdem.org", "https://www.texdem.org"]

      if origin.present? && allowed.include?(origin)
        response.headers["Access-Control-Allow-Origin"] = origin
      end

      response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
      response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    end
  end

  # Index on create/edit
  on(:post_created) { |post, _opts, _user| ::TexdemEvents::Indexer.reindex_post!(post.id) }
  on(:post_edited)  { |post, _topic_changed| ::TexdemEvents::Indexer.reindex_post!(post.id) }

  # If a post is destroyed, remove it from index
  on(:post_destroyed) { |post, _opts, _user| ::TexdemEvents::Indexer.deindex_post!(post.id) }

  # Routes + controller
  require_relative "app/controllers/texdem_events/events_controller"
  Discourse::Application.routes.append do
    get "/texdem-events" => "texdem_events/events#index", defaults: { format: :json }
  end
end
