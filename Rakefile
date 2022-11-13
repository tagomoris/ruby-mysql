# @example
#   rake spec
#
# environments:
# * MYSQL_SERVER    - default: 'localhost'
# * MYSQL_USER      - default: 'root'
# * MYSQL_PASSWORD  - default: 'secret'
# * MYSQL_DATABASE  - default: 'test_for_mysql_ruby'
# * MYSQL_PORT      - default: 3306
# * MYSQL_SOCKET    - defualt: '/tmp/mysql.sock'
#
# or edit spec/config.rb
#

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[spec rubocop]
