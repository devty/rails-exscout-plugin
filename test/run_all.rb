#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs the whole suite in one process.
#
#   ruby test/run_all.rb
#
# Minitest is a Ruby default gem, so this needs no Gemfile and installs nothing
# into the repo under analysis -- the same promise the analyzers themselves make.

Dir[File.join(__dir__, 'test_*.rb')].sort.each { |f| require f }
