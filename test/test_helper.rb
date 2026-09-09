ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Temporarily set or unset environment variables for the duration of a block.
#
# The mesh hop budget is configured entirely through the environment
# (EPB_MESH_DOWNSTREAM_URL, EPB_MESH_APP_NAME), and the interesting cases are
# the unset ones -- a live budget with no downstream target has to be a loud
# 500. Tests must therefore be able to clear a variable that happens to be set
# in the shell that runs them, and put it back afterwards.
module EnvHelper
  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

# Replace a singleton method for the duration of a block, then put it back.
#
# Minitest 6 dropped minitest/mock, so Object#stub no longer exists, and the
# two collaborators these tests must keep off the network -- the EndPointBlank
# authorize call and the downstream peer -- are both reached through class
# methods. This is the smallest thing that stands in for them without adding a
# mocking library to a five-application harness.
module StubHelper
  def stubbing(object, name, implementation)
    singleton = object.singleton_class
    # The method may be inherited (from an extended module, or from Class#new).
    # Only a method the singleton class itself owns has to be handed back;
    # anything else reappears as soon as the override is removed.
    original = singleton.instance_method(name) if singleton.instance_methods(false).include?(name)

    singleton.define_method(name) { |*args, **kwargs| implementation.call(*args, **kwargs) }
    yield
  ensure
    singleton.send(:remove_method, name)
    singleton.define_method(name, original) if original
  end
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
    include EnvHelper
    include StubHelper
  end
end
