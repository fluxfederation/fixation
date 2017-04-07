module Fixation
  class FixtureContent
  end

  class Fixtures
    def initialize
      @fixture_tables = {}
    end

    def compile_fixture_files(connection = ActiveRecord::Base.connection)
      puts "#{Time.now} building fixtures" if Fixation.trace

      @class_names = {}

      @loaded_at = ActiveRecord::Base.default_timezone == :utc ? Time.now.utc : Time.now

      Fixation.paths.each do |path|
        Dir["#{path}/{**,*}/*.yml"].each do |pathname|
          basename = pathname[path.size + 1..-5]
          load_fixture_file(pathname, basename, connection) if ::File.file?(pathname)
        end
      end

      Fixation.paths.each do |path|
        Dir["#{path}/{**,*}/*.rb"].each do |pathname|
          FixtureContent.instance_eval(File.read(pathname)) if ::File.file?(pathname)
        end
      end

      bake_fixtures

      puts "#{Time.now} built fixtures for #{@fixture_ids.size} tables" if Fixation.trace
    end

    def load_fixture_file(filename, basename, connection)
      fixture_table = FixtureTable.new(filename, basename, connection, @loaded_at)
      @fixture_tables[fixture_table.fixture_name] = fixture_table
      @class_names[fixture_table.fixture_name] = fixture_table.class_name
    end

    def add_fixture(fixture_for, name, attributes)
      raise "Fixtures have already been compiled!  You can only call add_fixture from a file in one of the fixture directories, which is loaded on boot." if baked_fixtures?
      fixture_table = @fixture_tables[fixture_for.to_s] or raise(ArgumentError, "No fixture file for #{fixture_for}") # TODO: consider allowing this
      fixture_table.add_row(name.to_s, attributes.stringify_keys)
      name
    end

    def bake_fixtures
      @fixture_ids = {}
      @statements = {}

      @fixture_tables.each do |fixture_name, fixture_table|
        @fixture_ids[fixture_table.fixture_name] = fixture_table.fixture_ids
        @statements[fixture_table.table_name] = fixture_table.statements
      end
    end

    def baked_fixtures?
      !@fixture_ids.nil? || !@statements.nil?
    end

    def apply_fixtures(connection = ActiveRecord::Base.connection)
      connection.disable_referential_integrity do
        connection.transaction do
          apply_fixture_statements(connection)
          clear_other_tables(connection) if Fixation.clear_other_tables
        end
      end
    end

    def apply_fixture_statements(connection)
      @statements.each do |table_name, table_statements|
        table_statements.each do |statement|
          connection.execute(statement)
        end
      end
    end

    def clear_other_tables(connection)
      (connection.tables - Fixation.tables_not_to_clear - @statements.keys).each do |table_name|
        connection.execute("DELETE FROM #{connection.quote_table_name table_name}")
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
end
