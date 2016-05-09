module SpreeElasticsearch
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("../../templates", __FILE__)

      def copy_config
        template "elasticsearch.yml.sample", "config/elasticsearch.yml"
      end
    end
  end
end
