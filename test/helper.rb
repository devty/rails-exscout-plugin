# frozen_string_literal: true

# Shared test bootstrap.
#
# Both scripts guard their CLI behind `if __FILE__ == $PROGRAM_NAME`, so a plain
# require loads the library without running main. Minitest ships with Ruby as a
# default gem, so the suite honours the plugin's own promise: no Gemfile, no
# bundler, nothing to install.

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
require File.join(ROOT, 'scripts', 'build_index')
require File.join(ROOT, 'scripts', 'analyze_domain')

module FixtureRepo
  # Writes a throwaway repo and yields its path. Files are given as a
  # relative-path => source hash; parent directories are created as needed.
  def with_repo(files)
    Dir.mktmpdir('extract-scout-test') do |dir|
      files.each do |rel, source|
        abs = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, source)
      end
      yield dir
    end
  end

  # Parse a source string with no disk involved.
  def refs_for(source)
    ExtractScout::FileAnalyzer.new('t.rb', source).analyze.refs
  end

  def kinds_for(source)
    refs_for(source).map { |r| [r.const, r.kind] }
  end

  def consts_for(source)
    refs_for(source).map(&:const)
  end

  # Constants recorded on one specific line. Multi-line macros mean a whole-file
  # assertion can be satisfied by a neighbouring declaration, which hides the
  # very edge under test.
  def consts_on_line(source, line)
    refs_for(source).select { |r| r.line == line }.map(&:const)
  end
end
