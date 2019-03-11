# Fixation

This gem will precompile the SQL statements needed to clear and repopulate your test tables with fixtures when the app boots under spring, so that spec startup just needs to run a small number of multi-row SQL statements to prepare for run.  This takes around 1/10th the time as a normal fixture load.

Like ActiveRecord's normal fixture implementation, Fixation will load the model classes in order to use metadata about associations and enums.  But since Fixation is run at the time spring starts, Fixation will then 'reload' rails (the same way spring does), so you can change your model classes and re-run tests without having to restart spring.

## Installation

Add this gem to your application's Gemfile:

```ruby
groups :development, :test do
  gem 'fixation'
end
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install fixation

Then, make an initializer file in config/initializers:

```ruby
if Rails.env.test? && Fixation.running_under_spring?
  Rails.application.config.after_initialize do
    Fixation.preload_for_spring
  end
end
```

Open up your spec_helper.rb, and find the current `global_fixtures` setting:

```ruby
config.global_fixtures = :all
```

Change that to [] so that ActiveRecord doesn't load the fixtures again itself, and load the Fixation module:

```ruby
config.global_fixtures = []
config.include Fixation.fixture_methods
```

Finally run `spring stop` so these changes get picked up.

## Usage

Simply run your tests under spring.

    bundle exec spring spec/models/my_spec.rb

## Limitations

You'll need to run rake tasks like `db:create` and `db:test:prepare` the normal way (without spring), because if the database doesn't exist or the schema isn't loaded, the initializer above will asplode.

Not all features of regular ActiveRecord fixtures are supported:
* HABTM support has not been implemented (does anyone use HABTM these days?)

## Multiple fixture paths

Unlike regular ActiveRecord fixtures, Fixation supports looking for fixture files in multiple paths.  It defaults to looking in `test/fixtures` and `spec/fixtures`.  You can change this in your initializer before you do the spring setup:

```ruby
if Rails.env.test?
  Fixation.paths = %w(spec/fixtures db/seeds)
end

if Rails.env.test? && Fixation.running_under_spring?
  Rails.application.config.after_initialize do
    Fixation.preload_for_spring
  end
end
```

## Included fixture file extensions

Fixation will load files with either the `.yml` or `.yml.erb` extension from the configured fixture paths. You can change this in your initializer in a similar fashion to the fixture paths:

```ruby
if Rails.env.test?
  Fixation.extensions = %w(.yml .other.extension)
end
```

## Auto-clearing other tables

By default Fixation will only reset those tables that have a fixture file, like Rails.  Optionally, you can tell it to clear all other tables so that you don't need to make empty fixture files.

```ruby
if Rails.env.test?
  Fixation.clear_other_tables = true
end
```

## Ruby fixtures

As well as traditional .yml fixture files, Fixation allows you to drop .rb files into your fixture directory.  You can then call the `add_fixture` method, passing the name of the table, the name of the fixture, and the attributes:

```ruby
10.times do |n|
  Fixation.add_fixture(:customers, "active_customer_#{n}", active: true, name: "Sue #{n}")
end
```

(You should avoid accessing your actual model classes here, since that will cause them to be auto-loaded.)

## Reversing mappings

When debugging difficult test scenarios, it can be useful to confirm which record you are looking at.  As well as the usual forward mappings from fixture name to record, Fixation supports mapping back from record or record ID to the fixture name.

For example, if `customers(:jeff)` returns a record with ID `12345678`, then `customer_fixture_name_for_id(12345678)` will return `:jeff`, as will `customer_fixture_name_for_id(Customer.find(12345678))`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/willbryant/fixation.

## Thanks

* Andy Newport (@newportandy)
* Andrew Clemons (@aclemons)

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

