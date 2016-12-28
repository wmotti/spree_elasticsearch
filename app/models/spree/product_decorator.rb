module Spree
  Product.class_eval do
    include Elasticsearch::Model

    index_name Spree::ElasticsearchSettings.index
    document_type 'spree_product'

    mapping _all: {"index_analyzer" => "nGram_analyzer", "search_analyzer" => "whitespace_analyzer"} do
      indexes :name, type: 'multi_field' do
        indexes :name, type: 'string', analyzer: 'nGram_analyzer', boost: 100
        indexes :did_you_mean, type: 'string', analyzer: 'didYouMean_analyzer'
        indexes :untouched, type: 'string', include_in_all: false, index: 'not_analyzed'
        indexes :whitespace, type: 'string', include_in_all: false, analyzer: 'whitespace_analyzer'
      end
      indexes :brand, type: 'string', index: 'not_analyzed'
      indexes :description, analyzer: Spree::Config[:elasticsearch_description_analyzer]
      indexes :available_on, type: 'date', format: 'dateOptionalTime', include_in_all: false
      indexes :visible, type: 'boolean', include_in_all: false
      indexes :sellable, type: 'boolean', include_in_all: false
      indexes :price, type: 'double'
      indexes :sku, type: 'string', index: 'not_analyzed'
      indexes :taxon_ids, type: 'string', index: 'not_analyzed'
      indexes :taxons_position, type: 'nested' do
        indexes :id, type: 'integer', index: 'not_analyzed'
        indexes :position, type: 'integer', index: 'not_analyzed'
      end
      indexes :properties, type: 'string', index: 'not_analyzed'
    end

    # If available_on is null, the product is considered available
    def as_indexed_json(options={})
      result = as_json({
        methods: [:price, :sku],
        only: [:available_on, :description, :name, :visible, :sellable],
        include: {
          variants: {
            only: [:sku],
            include: {
              option_values: {
                only: [:name, :presentation]
              }
            }
          }
        }
      }).stringify_keys
      result["description"] = ActionView::Base.full_sanitizer.sanitize(description)
      result["brand"] = sanitized_brand
      result["available_on"] ||= Time.now
      result["properties"] = property_list unless property_list.empty?
      result["taxon_ids"] = taxon_ids unless taxons.empty?
      result["taxons_position"] = classifications.map{|c| {id: c.taxon_id, position: c.position}} unless classifications.empty?
      result
    end

    # Inner class used to query elasticsearch. The idea is that the query is dynamically build based on the parameters.
    class Product::ElasticsearchQuery
      include ::Virtus.model

      attribute :from, Integer, default: 0
      attribute :price_ranges, Array
      attribute :properties, Hash
      attribute :query, String
      attribute :taxons, Array
      attribute :brands, Array
      attribute :browse_mode, Boolean
      attribute :sorting, String

      # When browse_mode is enabled, the taxon filter is placed at top level. This causes the results to be limited, but facetting is done on the complete dataset.
      # When browse_mode is disabled, the taxon filter is placed inside the filtered query. This causes the facets to be limited to the resulting set.

      # Method that creates the actual query based on the current attributes.
      # The idea is to always to use the following schema and fill in the blanks.
      # {
      #   query: {
      #     filtered: {
      #       query: {
      #         query_string: { query: , fields: [] }
      #       }
      #       filter: {
      #         and: [
      #           { terms: { taxons: [] } },
      #           { terms: { properties: [] } }
      #         ]
      #       }
      #     }
      #   }
      #   filter: { or: [ { range: { price: { lte: , gte: } } } }, { range: { price: { lte: , gte: } } } }],
      #   sort: [],
      #   from: ,
      #   facets:
      # }
      def to_hash
        main_field = Spree::Config.search_all_keywords_in_name ? 'name.whitespace' : 'name'

        #es. "name,description^2,brand"
        fields = ["#{main_field}^5",'description','brand','sku']
        custom_fields = Spree::Config.elasticsearch_custom_fields.split(',')
        fields = custom_fields if custom_fields.present?

        q = { match_all: {} }
        unless query.blank? # nil or empty
          q = {
            query_string: {
              query: query,
              fields: fields,
              default_operator: 'AND',
              use_dis_max: true
            }
          }
        end
        query = q

        and_filter = []
        unless @properties.nil? || @properties.empty?
          # transform properties from [{"key1" => ["value_a","value_b"]},{"key2" => ["value_a"]}
          # to { terms: { properties: ["key1||value_a","key1||value_b"] }
          #    { terms: { properties: ["key2||value_a"] }
          # This enforces "and" relation between different property values and "or" relation between same property values
          properties = @properties.map {|k,v| [k].product(v)}.map do |pair|
            and_filter << { terms: { properties: pair.map {|prop| prop.join("||")} } }
          end
        end

        unless taxons.empty?
          taxons.dup.each do |t|
            taxons.concat Spree::Taxon.find(t).descendants.flatten.map(&:id)
          end
        end

        sorting = case @sorting
        when "name_asc"
          [ {"name.untouched" => { order: "asc" }}, {"price" => { order: "asc" }}, "_score" ]
        when "name_desc"
          [ {"name.untouched" => { order: "desc" }}, {"price" => { order: "asc" }}, "_score" ]
        when "price_asc"
          [ {"price" => { order: "asc" }}, {"name.untouched" => { order: "asc" }}, "_score" ]
        when "price_desc"
          [ {"price" => { order: "desc" }}, {"name.untouched" => { order: "asc" }}, "_score" ]
        when "score"
          [ "_score", {"name.untouched" => { order: "asc" }}, {"price" => { order: "asc" }} ]
        when "taxons_position"
          _s = []
          taxons.each do |t|
            _s << {"taxons_position.position" => { order: "asc", nested_filter: { "term" => { "taxons_position.id" => t }}}}
          end
          _s << {"_uid" => { order: "asc" }}
          _s
        else
          [ {"name.untouched" => { order: "asc" }}, {"price" => { order: "asc" }}, "_score" ]
        end

        # facets
        facets = {
          price: { statistical: { field: "price" } },
          properties: { terms: { field: "properties", order: "count", size: 1000000 } },
          taxon_ids: { terms: { field: "taxon_ids", size: 1000000 } }
        }

        # basic skeleton
        result = {
          min_score: Spree::Config.elasticsearch_min_score,
          query: { filtered: {} },
          sort: sorting,
          from: from,
          facets: facets
        }

        # add query and filters to filtered
        result[:query][:filtered][:query] = query
        # taxon and property filters have an effect on the facets

        and_filter << { terms: { taxon_ids: taxons.uniq } } unless taxons.empty?
        and_filter << { terms: { brand: brands } } unless brands.empty?
        # only return products that are available
        and_filter << { range: { available_on: { lte: "now" } } }
        and_filter << { term: { visible: 1 } }
        result[:query][:filtered][:filter] = { "and" => and_filter } unless and_filter.empty?

        # add price filter outside the query because it should have no effect on facets
        _filters = []
        price_ranges.each do |range|
          range.map!(&:to_f)
          if range[1].nil? or range[0] <= range[1]
            if range[1].nil?
              _filters << { range: { price: { gte: range[0] } } }
            else
              _filters << { range: { price: { gte: range[0], lte: range[1] } } }
            end
          end
        end
        result[:filter] = {or: _filters} if _filters.any?

        result
      end
    end

    private

    def property_list
      product_properties.map{|pp| "#{pp.property.name}||#{pp.value}"}
    end
  end
end
