require_relative 'lib/mysql'

Gem::Specification.new do |s|
  s.name = 'ruby-mysql'
  s.version = Mysql::VERSION
  s.summary = 'MySQL connector'
  s.authors = ['Tomita Masahiro']
  s.description = 'This is MySQL connector. pure Ruby version'
  s.email = 'tommy@tmtm.org'
  s.homepage = 'http://gitlab.com/tmtms/ruby-mysql'
  s.files = ['README.md', 'CHANGELOG.md'] + Dir.glob('lib/**/*.rb')
  s.license = 'MIT'
  s.required_ruby_version = '>= 2.6.0'
  s.metadata['homepage_uri'] = 'http://gitlab.com/tmtms/ruby-mysql'
  s.metadata['documentation_uri'] = 'https://www.rubydoc.info/gems/ruby-mysql'
  s.metadata['source_code_uri'] = 'http://gitlab.com/tmtms/ruby-mysql'
  s.metadata['rubygems_mfa_required'] = 'true'
  s.add_development_dependency 'power_assert'
  s.add_development_dependency 'rspec'
  s.add_development_dependency 'rubocop'
end
