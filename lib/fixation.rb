require 'erb'
require 'yaml'
require 'set'
require 'active_support/dependencies'
require 'active_record/errors'
require "fixation/version"

module Fixation
  class FixtureTable
    attr_reader :filename, :class_name, :table_name, :connection, :now

    def initialize(filename, basename, connection, now)
      @filename = filename
      @connection = connection
      @now = now

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

    def content
      template = File.read(filename)
      render_context = ActiveRecord::FixtureSet::RenderContext.create_subclass.new.get_binding
      ERB.new(template).result(render_context)
    end

    def parsed_rows
      result = YAML.load(content)
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
        embellish_fixture(name, attributes, columns_hash)
      end
    end

    def embellish_fixture(name, attributes, columns_hash)
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
          attributes[column_name] = now if columns_hash[column_name] && !attributes.has_key?(column_name)
        end
        %w(created_at updated_at).each do |column_name|
          attributes[column_name] = now.to_date if columns_hash[column_name] && !attributes.has_key?(column_name)
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

  class Fixtures
    def initialize
      @class_names = {}
      @fixture_ids = {}
      @statements = {}

      compile_fixture_files
    end

    def compile_fixture_files(connection = ActiveRecord::Base.connection)
      puts "#{Time.now} building fixtures" if Fixation.trace

      now = ActiveRecord::Base.default_timezone == :utc ? Time.now.utc : Time.now
      Fixation.paths.each do |path|
        Dir["#{path}/{**,*}/*.yml"].each do |pathname|
          basename = pathname[path.size + 1..-5]
          compile_fixture_file(pathname, basename, connection, now) if ::File.file?(pathname)
        end
      end

      puts "#{Time.now} built fixtures for #{@fixture_ids.size} tables" if Fixation.trace
    end

    def compile_fixture_file(filename, basename, connection, now)
      fixture_table = FixtureTable.new(filename, basename, connection, now)
      fixture_name = basename.gsub('/', '_')
      @fixture_ids[fixture_name] = fixture_table.fixture_ids
      @statements[fixture_name] = fixture_table.statements
      @class_names[fixture_name] = fixture_table.class_name
    end

    def apply_fixtures(connection = ActiveRecord::Base.connection)
      connection.transaction do
        @statements.each do |table_name, table_statements|
          table_statements.each do |statement|
            connection.execute(statement)
          end
        end
      end
    end

    def fixture_methods
      fixture_ids = @fixture_ids
      class_names = @class_names

      methods = Module.new do
        def setup_fixtures(config = ActiveRecord::Base)
          if run_in_transaction?
            @@fixated_fixtures_applied ||= false
            unless @@fixated_fixtures_applied
              puts "#{Time.now} applying fixtures" if Fixation.trace
              Fixation.apply_fixtures
              @@fixated_fixtures_applied = true
              puts "#{Time.now} applied fixtures" if Fixation.trace
            end
          else
            @@fixated_fixtures_applied = false
          end
          super
        end

        fixture_ids.each do |fixture_name, fixtures|
          begin
            klass = class_names[fixture_name].constantize
          rescue NameError
            next
          end

          define_method(fixture_name) do |*fixture_names|
            force_reload = fixture_names.pop if fixture_names.last == true || fixture_names.last == :reload

            @fixture_cache[fixture_name] ||= {}

            instances = fixture_names.map do |name|
              id = fixtures[name.to_s]
              raise StandardError, "No fixture named '#{name}' found for fixture set '#{fixture_name}'" if id.nil?

              @fixture_cache[fixture_name].delete(name) if force_reload
              @fixture_cache[fixture_name][name] ||= klass.find(id)
            end

            instances.size == 1 ? instances.first : instances
          end
          private fixture_name
        end
      end
    end
  end

  cattr_accessor :trace
  cattr_accessor :paths
  self.paths = %w(test/fixtures spec/fixtures)

  def self.build_fixtures
    @fixtures = Fixtures.new
  end

  def self.apply_fixtures
    build_fixtures unless @fixtures
    @fixtures.apply_fixtures
  end

  def self.fixture_methods
    build_fixtures unless @fixtures
    @fixtures.fixture_methods
  end

  # Returns a consistent, platform-independent identifier for +label+.
  # Integer identifiers are values less than 2^30. UUIDs are RFC 4122 version 5 SHA-1 hashes.
  #
  # Uses the ActiveRecord fixtures method for compatibility.
  if ActiveRecord::FixtureSet.method(:identify).arity == 1
    def self.identify(label, _column_type = :integer)
      ActiveRecord::FixtureSet.identify(label)
    end
  else
    def self.identify(label, column_type = :integer)
      ActiveRecord::FixtureSet.identify(label, column_type)
    end
  end

  def self.running_under_spring?
    defined?(Spring::Application)
  end

  def self.preload_for_spring
    build_fixtures
    unload_models!
    watch_paths
  end

  def self.watch_paths
    paths.each do |path|
      Spring.watch(path)
    end
  end

  # reloads Rails (using the code from Spring) in order to unload the model classes that get
  # auto-loaded when we read the fixture definitions.
  def self.unload_models!
    # Rails 5.1 forward-compat. AD::R is deprecated to AS::R in Rails 5.
    if defined? ActiveSupport::Reloader
      Rails.application.reloader.reload!
    else
      ActionDispatch::Reloader.cleanup!
      ActionDispatch::Reloader.prepare!
    end
  end
end
