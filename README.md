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

Then, make an initializer:

```ruby
if Rails.env.test? && Fixation.running_under_spring?
  Rails.application.config.after_initialize do
    Fixation.preload_for_spring
  end
end
```

And run `spring stop` so this gets picked up.

Finally, open up your spec_helper.rb, and find the current `global_fixtures` setting:

```ruby
config.global_fixtures = :all
```

Change that to [] so that ActiveRecord doesn't load the fixtures again itself, and load the Fixation module:

```ruby
config.global_fixtures = []
config.include Fixation.fixture_methods
```

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

## Auto-clearing other tables

By default Fixation will only reset those tables that have a fixture file, like Rails.  Optionally, you can tell it to clear all other tables so that you don't need to make empty fixture files.

```ruby
if Rails.env.test?
  Fixation.clear_other_tables = true
end
```


## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/willbryant/fixation.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

