Gem::Specification.new do |spec|
  spec.name          = "fosm-async"
  spec.version       = "0.1.0"
  spec.authors       = [ "Inloop Studio" ]
  spec.email         = [ "team@inloop.studio" ]
  spec.summary       = "Fiber-based async transitions for FOSM"
  spec.description   = "Optional extension gem for FOSM that adds fiber-based concurrent transition processing"
  spec.homepage      = "https://github.com/inloopstudio-team/fosm-async"
  spec.license       = "MIT"

  spec.files         = Dir["lib/**/*", "README.md"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "fosm-rails", "~> 0.2"
  spec.add_dependency "async", "~> 2.0"
  spec.add_dependency "async-http", "~> 0.60"

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
