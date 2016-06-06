module Spree
  module Search
    # The following search options are available.
    #   * taxon
    #   * keywords in name or description
    #   * properties values
    class Elasticsearch <  Spree::Core::Search::Base
      include ::Virtus.model

      attribute :query, String
      attribute :price_ranges, Array
      attribute :taxons, Array
      attribute :brands, Array
      attribute :browse_mode, Boolean, default: true
      attribute :properties, Hash
      attribute :per_page, String
      attribute :page, String
      attribute :sorting, String

      def initialize(params)
        self.current_currency = Spree::Config[:currency]
        prepare(params)
      end

      def retrieve_products(paged=true, includes=[])
        begin
          from = (@page - 1) * Spree::Config.products_per_page
          search_result = Spree::Product.__elasticsearch__.search(
            Spree::Product::ElasticsearchQuery.new(
              query: query,
              taxons: taxons,
              brands: brands,
              browse_mode: browse_mode,
              from: from,
              price_ranges: price_ranges,
              properties: properties,
              sorting: sorting
            ).to_hash
          )
          if paged
            return search_result.limit(per_page).page(page).records(includes: includes)
          else
            limit = search_result.limit(1).results.total rescue nil
            return search_result.limit([limit||1000, 5000].min).records(includes: includes)
          end
        rescue Exception => e
          Rails.logger.info "ES Exception: #{e.message}"
          if Rails.env.production? and defined?(Spree::ExceptionMailer)
            Spree::ExceptionMailer.exception_mail(e).deliver
          end
          return Spree::Product.where("1=0").page(1).per(1)
        end
      end

      def self.available?
        begin
          check = Spree::Product.__elasticsearch__.client.cluster.health
          if (check and ["yellow", "green"].include?(check["status"]))
            return Spree::Product.__elasticsearch__.index_exists?
          else
            return false
          end
        rescue => e
          return false
        end
      end

      def autocomplete
        Spree::Product.__elasticsearch__.search({
          query: {
            query_string: {
              query: query,
              fields: ["name"]
            }
          }
        }).limit(per_page).records
      end

      def suggestions
        results = Spree::Product.__elasticsearch__.search({
          suggest: {
            text: query,
            didYouMean: {
              phrase: {
                field: "name.did_you_mean",
                max_errors: 2,
                direct_generator: [
                  {
                    field: "name.did_you_mean",
                    min_word_length: 1
                  }
                ]
              }
            }
          }
        }).limit(5)
        results.response[:suggest]["didYouMean"].first.options.map{|o| o["text"]}
      end

      protected

      # converts params to instance variables
      def prepare(params)
        @query = params[:keywords]
        @sorting = params[:sorting]
        @taxons = params[:taxon] unless params[:taxon].nil?
        @browse_mode = params[:browse_mode] unless params[:browse_mode].nil?

        # price
        @price_ranges ||= []
        if params[:search] && params[:search][:price]
          @price_ranges << [params[:search][:price][:min].to_f, params[:search][:price][:max].to_f]
        elsif params[:search] && params[:search][:price_range_any]
          @price_ranges = params[:search][:price_range_any].map{|pr| pr.split('#')}
        end

        # properties
        @properties = params[:search][:properties] if params[:search]

        # brands
        @brands = params[:search][:brand_any] if params[:search]

        @per_page = (params[:per_page].to_i <= 0) ? Spree::Config[:products_per_page] : params[:per_page].to_i
        @page = (params[:page].to_i <= 0) ? 1 : params[:page].to_i
      end
    end
  end
end
