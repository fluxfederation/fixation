# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'fixation/version'

Gem::Specification.new do |spec|
  spec.name          = "fixation"
  spec.version       = Fixation::VERSION
  spec.authors       = ["Will Bryant"]
  spec.email         = ["will.bryant@gmail.com"]

  spec.summary       = %q{10x faster fixture startup under spring.}
  spec.description   = %q{This gem will precompile the SQL statements needed to clear and repopulate your test tables with fixtures when the app boots under spring, so that spec startup just needs to run a small number of multi-row SQL statements to prepare for run.  This takes around 1/10th the time as a normal fixture load.}
  spec.homepage      = "https://github.com/willbryant/fixation"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
end
