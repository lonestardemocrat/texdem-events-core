# frozen_string_literal: true

module ::Jobs
  class TexdemEventsReindexAll < ::Jobs::Base
    def execute(_args)
      Post.where(deleted_at: nil).find_each do |post|
        ::TexdemEvents::Indexer.reindex_post!(post.id)
      rescue => e
        Rails.logger.warn("TexdemEvents reindex failed post_id=#{post.id}: #{e.class} #{e.message}")
      end
    end
  end
end
