# frozen_string_literal: true
module ::DiscourseCourseReview
  class Engine < ::Rails::Engine
    engine_name "discourse-course-review"
    isolate_namespace ::DiscourseCourseReview
    config.root = File.expand_path("..", __dir__)
  end
end
