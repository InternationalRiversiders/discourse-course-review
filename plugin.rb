# frozen_string_literal: true
# name: discourse-course-review
# about: 选课指南 — Riverside native community application
# version: 0.1.0
# authors: Riverside
# required_version: 2026.9.0-latest

enabled_site_setting :courses_enabled
register_asset "stylesheets/courses.scss"
%w[graduation-cap thumbs-up thumbs-down comment pen trash-can flag shield-halved bookmark check].each { |name| register_svg_icon name }
require_relative "lib/engine"
after_initialize do
  require_relative "lib/core"
  require_relative "lib/catalog"
  require_relative "lib/business"
  require_relative "lib/importer"
  require_relative "lib/user_lifecycle"
  add_to_serializer(:current_user, :courses_member) { SiteSetting.courses_enabled && DiscourseCourseReview::Access.member?(object) }

  Discourse::Application.routes.append { mount DiscourseCourseReview::Engine, at: "/courses" }
end
