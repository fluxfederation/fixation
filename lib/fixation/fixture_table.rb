module Fixation
  class FixtureTable
    attr_reader :filename, :fixture_name, :class_name, :table_name, :connection, :loaded_at

    def self.erb_content(filename)
      template = File.read(filename)
      render_context = ActiveRecord::FixtureSet::RenderContext.create_subclass.new.get_binding
      ERB.new(template).result(render_context)
    end

    def initialize(filename, basename, connection, loaded_at)
      @filename = filename
      @connection = connection
      @loaded_at = loaded_at

      @fixture_name = basename.gsub('/', '_')

      @class_name = basename.classify
      begin
        @klass = @class_name.constantize
        @klass = nil unless @klass < ActiveRecord::Base
      rescue NameError
        ActiveRecord::Base.logger.warn "couldn't load #{class_name} for fixture table #{table_name}: #{$!}"
      end

      if @klass
        @table_name = @klass.table_name
        @primary_key = @klass.primary_key
        @record_timestamps = @klass.record_timestamps
        @inheritance_column = @klass.inheritance_column
      else
        @table_name = basename.gsub('/', '_')
      end
    end

    def columns_hash
      @columns_hash ||= connection.columns(table_name).index_by(&:name)
    end

    def parsed_rows
      result = YAML.load(self.class.erb_content(filename))
      result ||= {} # for completely empty files

      unless (result.is_a?(Hash) || result.is_a?(YAML::Omap)) && result.all? { |name, attributes| name.is_a?(String) && attributes.is_a?(Hash) }
        raise ActiveRecord::Fixture::FormatError, "#{filename} needs to contain a hash of fixtures"
      end

      result.delete('DEFAULTS')
      result
    rescue ArgumentError, Psych::SyntaxError => error
      # we use exactly the same error class and message as ActiveRecord::FixtureSet in case anyone was depending on it
      raise ActiveRecord::Fixture::FormatError, "a YAML error occurred parsing #{filename}. Please note that YAML must be consistently indented using spaces. Tabs are not allowed. Please have a look at http://www.yaml.org/faq.html\nThe exact error was:\n  #{error.class}: #{error}", error.backtrace
    end

    def embellished_rows
      @embellished_rows ||= parsed_rows.each do |name, attributes|
        embellish_fixture(name, attributes)
      end
    end

    def embellish_fixture(name, attributes)
      # populate the primary key column, if not already set
      if @primary_key && columns_hash[@primary_key] && !attributes.has_key?(@primary_key)
        attributes[@primary_key] = Fixation.identify(name, columns_hash[@primary_key].type)
      end

      # substitute $LABEL into all string values
      attributes.each do |column_name, value|
        attributes[column_name] = value.gsub("$LABEL", name) if value.is_a?(String)
      end

      # populate any timestamp columns, if not already set
      if @record_timestamps
        %w(created_at updated_at).each do |column_name|
          attributes[column_name] = loaded_at if columns_hash[column_name] && !attributes.has_key?(column_name)
        end
        %w(created_at updated_at).each do |column_name|
          attributes[column_name] = loaded_at.to_date if columns_hash[column_name] && !attributes.has_key?(column_name)
        end
      end

      # convert enum names to values
      @klass.defined_enums.each do |name, values|
        attributes[name] = values.fetch(attributes[name], attributes[name]) if attributes.has_key?(name)
      end if @klass.respond_to?(:defined_enums)

      # convert any association names into the identity column equivalent - following code from activerecord's fixtures.rb
      nonexistant_columns = attributes.keys - columns_hash.keys

      if @klass && nonexistant_columns.present?
        # If STI is used, find the correct subclass for association reflection
        reflection_class =
          if attributes.include?(@inheritance_column)
            attributes[@inheritance_column].constantize rescue @klass
          else
            @klass
          end

        nonexistant_columns.each do |column_name|
          association = reflection_class.reflect_on_association(column_name)

          if association.nil?
            raise ActiveRecord::Fixture::FormatError, "No column named #{column_name} found in table #{table_name}"
          elsif association.macro != :belongs_to
            raise ActiveRecord::Fixture::FormatError, "Association #{column_name} in table #{table_name} has type #{association.macro}, which is not currently supported"
          else
            value = attributes.delete(column_name)

            if association.options[:polymorphic] && value.is_a?(String) && value.sub!(/\s*\(([^\)]*)\)\s*$/, "")
              # support polymorphic belongs_to as "label (Type)"
              attributes[association.foreign_type] = $1
            end

            fk_name = (association.options[:foreign_key] || "#{association.name}_id").to_s
            attributes[fk_name] = value ? ActiveRecord::FixtureSet.identify(value) : value
          end
        end
      end
    end

    def add_row(name, attributes)
      embellish_fixture(name, attributes)
      embellished_rows[name] = attributes
    end

    def fixture_ids
      embellished_rows.each_with_object({}) do |(name, attributes), ids|
        ids[name] = attributes['id'] || attributes['uuid']
      end
    end

    def statements
      statements = ["DELETE FROM #{connection.quote_table_name table_name}"]

      unless embellished_rows.empty?
        # first figure out what columns we have to insert into; we're going to need to use the same names for
        # all rows so we can use the multi-line INSERT syntax
        columns_to_include = Set.new
        embellished_rows.each do |name, attributes|
          attributes.each do |column_name, value|
            raise ActiveRecord::Fixture::FormatError, "No column named #{column_name.inspect} found in table #{table_name.inspect} (attribute on fixture #{name.inspect})" unless columns_hash[column_name]
            columns_to_include.add(columns_hash[column_name])
          end
        end

        # now build the INSERT statement
        quoted_column_names = columns_to_include.collect { |column| connection.quote_column_name(column.name) }.join(', ')
        statements <<
          "INSERT INTO #{connection.quote_table_name table_name} (#{quoted_column_names}) VALUES " +
          embellished_rows.collect do |name, attributes|
            '(' + columns_to_include.collect do |column|
              if attributes.has_key?(column.name)
                quote_value(column, attributes[column.name])
              else
                column.default_function || quote_value(column, column.default)
              end
            end.join(', ') + ')'
          end.join(', ')
      end

      statements
    end

    def quote_value(column, value)
      connection.quote(value)
    rescue TypeError
      connection.quote(YAML.dump(value))
    end
  end
end
