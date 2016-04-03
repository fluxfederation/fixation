# Fixation

This gem will precompile the SQL statements needed to clear and repopulate your test tables with fixtures when the app boots under spring, so that spec startup just needs to run a small number of multi-row SQL statements to prepare for run.  This takes around 1/10th the time as a normal fixture load.

To avoid any problems when you change your model classes, Fixation avoids loading model classes when it reads your fixture files.  This creates some incompatibilities with normal ActiveRecord fixtures for certain use cases - see Limitations below.


## Installation

Add this line to your application's Gemfile:

```ruby
gem 'fixation'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install fixation

Then, make an initializer:

    if ENV['PRELOAD_FIXTURES'].to_i > 0 && Rails.env.test?
      Rails.application.config.after_initialize do
        Fixation.build_fixtures
      end
    end

And run `spring stop` so this gets picked up.

Finally, open up your spec_helper.rb, and find the current `global_fixtures` setting:

    config.global_fixtures = :all

Change that to [] so that ActiveRecord doesn't load the fixtures again itself, and load the Fixation module:

    config.global_fixtures = []
    config.include Fixation.fixture_methods

## Usage

Add the PRECOMPILE_FIXTURES=1 option to your spring test commands:

    PRECOMPILE_FIXTURES=1 bundle exec spring spec/models/my_spec.rb

## Limitations

PRECOMPILE_FIXTURES is not on by default in our suggested initializer above, because you don't want it set when running rake tasks like `db:create` and `db:test:prepare` - the initializer above will asplode if you do.  This is one of the biggest drawbacks of this version of the gem.

Because Fixation wants to avoid loading your model classes when the app initializes, not all features of regular ActiveRecord fixtures are supported:
* the fixture filenames must match the database table names directly - whereas ActiveRecord actually assumes the filenames are underscored versions of the model class names, and it uses that class's configured table name
* when using the identify syntax to set association foreign keys, you must use the name that corresponds to the foreign key attribute (for example, `parent: sue` if you want to set the `parent_id` field to the appropriate value for the fixture called `sue`) - whereas ActiveRecord accepts the name of the association (`lead_carer: sue`) even if it uses a different foreign key name (`belongs_to :lead_carer, :foreign_key => :parent_id`)
* HABTM support has not been implemented (does anyone use HABTM these days?)
* enums are not known

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/willbryant/fixation.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

