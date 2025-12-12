# /var/www/discourse/plugins/texdem-events-core/lib/tasks/texdem_events.rake

namespace :texdem_events do
  desc "Reindex all TexDem events"
  task reindex_all: :environment do
    puts "[texdem_events] Starting full reindex..."

    unless defined?(::TexdemEvents::Indexer)
      # Make sure our lib loads even if plugin autoload order changes
      require_relative "../texdem_events/indexer"
    end

    # You can swap this to your own “find candidate posts” query later.
    # For now, just reindex posts that look like event posts or have calendar tag.
    post_ids = Post
      .joins(:topic)
      .where("posts.deleted_at IS NULL")
      .where("topics.deleted_at IS NULL")
      .where("topics.visible = ?", true)
      .where("posts.raw ILIKE ? OR topics.id IN (SELECT topic_id FROM topic_tags)", "%Visibility:%")
      .limit(50_000)
      .pluck(:id)

    puts "[texdem_events] Found #{post_ids.length} posts to reindex."

    post_ids.each_with_index do |pid, i|
      ::TexdemEvents::Indexer.reindex_post!(pid)
      puts "[texdem_events] Reindexed #{i + 1}/#{post_ids.length}" if (i % 500).zero?
    rescue => e
      puts "[texdem_events] ERROR pid=#{pid}: #{e.class} #{e.message}"
    end

    puts "[texdem_events] Done."
  end
end
