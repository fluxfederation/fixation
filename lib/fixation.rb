require 'erb'
require 'yaml'
require 'set'
require 'active_support/dependencies'
require 'active_record/errors'
require_relative "fixation/version"
require_relative "fixation/fixture_table"
require_relative "fixation/fixtures"

module Fixation
  # The list of paths to look in to find .yml fixture files.
  cattr_accessor :paths
  self.paths = %w(test/fixtures spec/fixtures)

  # Set to true to clear any tables found in the database that do *not* have a fixture file.
  cattr_accessor :clear_other_tables

  # Set to the list of tables you don't want to clear (if clear_other_tables is turned on).
  # Defaults to just schema_migrations.
  cattr_accessor :tables_not_to_clear
  self.tables_not_to_clear = %w(schema_migrations)

  # Set to true to log some debugging information to stdout.
  cattr_accessor :trace

  def self.build_fixtures
    @fixtures = Fixtures.new
    @fixtures.compile_fixture_files
  end

  def self.apply_fixtures
    build_fixtures unless @fixtures
    @fixtures.apply_fixtures
  end

  def self.fixture_methods
    build_fixtures unless @fixtures
    @fixtures.fixture_methods
  end

  def self.add_fixture(fixture_for, name, attributes)
    @fixtures.add_fixture(fixture_for, name, attributes)
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
