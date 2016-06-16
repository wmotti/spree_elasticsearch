module Spree
  Classification.class_eval do

    after_save :update_index
    after_destroy :update_index

    private

      def update_index
        if Spree::Config.searcher_class.eql?(Spree::Search::Elasticsearch)
          taxon.products.each do |_product|
            _product.__elasticsearch__.update_document
          end
        end
      end

  end
end
