# frozen_string_literal: true
require_relative '../lib/catalog_importer'
raw=File.binread(ARGV.fetch(0));sha=Digest::SHA256.hexdigest(raw)
apply=ENV['COURSES_CATALOG_APPLY']=='1'
abort 'Checksum confirmation required' if apply && sha!=ENV['COURSES_CATALOG_SHA256']
actor=User.find(Integer(ENV.fetch('COURSES_CATALOG_ACTOR_ID')))
result=DiscourseCourseReview::CatalogImporter.run(JSON.parse(raw),actor:actor,apply:apply)
puts JSON.pretty_generate(result.merge(sha256:sha))
