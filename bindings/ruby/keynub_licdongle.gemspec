# frozen_string_literal: true

require_relative 'lib/keynub_licdongle/version'

Gem::Specification.new do |spec|
  spec.name = 'keynub_licdongle'
  spec.version = KeyNubLicDongle::VERSION
  spec.summary = 'Ruby binding for the KeyNub USB-C license dongle'
  spec.description = <<~TEXT
    Talks to a KeyNub USB-C license dongle: authenticity verification, an
    encrypted session, licence records, monotonic counters, and envelope
    encryption bound to the dongle. Built on Fiddle from Ruby's standard library,
    so it needs no gems and no compiler.
  TEXT
  spec.authors = ['KeyNub']
  # A built gem carries the native library in vendor/, which is under
  # BINARY-LICENSE.txt rather than Apache-2.0.
  spec.licenses = ['Apache-2.0', 'LicenseRef-KeyNub-Binary']
  spec.homepage = 'https://github.com/AB-KeyNub/KeyNub-SDK'
  spec.required_ruby_version = '>= 3.0'

  spec.files = Dir['lib/**/*.rb'] + Dir['vendor/*'] +
               %w[README.md LICENSE BINARY-LICENSE.txt NOTICE THIRD-PARTY-NOTICES.txt].select { |f| File.exist?(f) }
  spec.require_paths = ['lib']

  # No runtime dependencies, deliberately. Fiddle is stdlib; a licensing gem is
  # the last place a customer wants a dependency that could be substituted.
  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'rubygems_mfa_required' => 'true'
  }
end
