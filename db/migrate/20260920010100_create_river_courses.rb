# frozen_string_literal: true
class CreateRiverCourses < ActiveRecord::Migration[7.2]
  def change
    create_table :river_courses_commands do |t|
      t.bigint :user_id, null: false
      t.string :key, null: false
      t.string :fingerprint, null: false
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :river_courses_commands, [:user_id, :key], unique: true
    create_table :river_courses_events do |t|
      t.bigint :user_id, null: false
      t.string :key, null: false
      t.string :text, null: false
      t.string :path, null: false
      t.bigint :notification_id
      t.timestamps
    end
    add_index :river_courses_events, :key, unique: true
    create_table :river_courses_audits do |t|
      t.bigint :user_id, null: false
      t.string :action, null: false
      t.string :target_kind
      t.bigint :target_id
      t.string :reason, null: false
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
    create_table :river_courses_legacies do |t|
      t.string :source, null: false
      t.string :legacy_id, null: false
      t.string :target_kind
      t.bigint :target_id
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end
    add_index :river_courses_legacies, [:source, :legacy_id], unique: true
    create_table :river_courses_media do |t|
      t.bigint :user_id, null: false
      t.string :token, null: false
      t.binary :bytes, null: false
      t.integer :size, null: false
      t.timestamps
    end
    add_index :river_courses_media, :token, unique: true
    create_table :river_courses_reactions do |t|
      t.bigint :user_id, null: false
      t.string :target_kind, null: false
      t.bigint :target_id, null: false
      t.integer :value, null: false
      t.timestamps
    end
    add_index :river_courses_reactions, [:user_id, :target_kind, :target_id], unique: true, name: 'river_courses_reaction_unique'
    add_check_constraint :river_courses_reactions, 'value IN (-1,1)', name: 'river_courses_reaction_value'
    create_table :river_courses_reports do |t|
      t.bigint :user_id, null: false
      t.string :target_kind, null: false
      t.bigint :target_id, null: false
      t.string :reason, null: false
      t.datetime :handled_at
      t.timestamps
    end
    add_index :river_courses_reports, [:user_id, :target_kind, :target_id], unique: true, name: 'river_courses_report_unique'
    create_table :river_courses_comments do |t|
      t.bigint :user_id, null: false
      t.string :target_kind, null: false
      t.bigint :target_id, null: false
      t.bigint :parent_id
      t.text :body, null: false
      t.boolean :anonymous, null: false, default: false
      t.string :status, null: false, default: 'visible'
      t.decimal :rating, precision: 3, scale: 1
      t.jsonb :media_ids, null: false, default: []
      t.timestamps
    end
    add_index :river_courses_comments, [:target_kind, :target_id, :id], name: 'river_courses_comment_target'
    add_foreign_key :river_courses_comments, :river_courses_comments, column: :parent_id
    add_check_constraint :river_courses_comments, 'rating IS NULL OR (rating >= 0.5 AND rating <= 5)', name: 'river_courses_comment_rating'
    create_table :river_courses_courses do |t|
      t.string :class_no, null: false
      t.string :code, null: false
      t.string :title, null: false
      t.string :teachers, null: false
      t.string :term, null: false, default: ''
      t.string :campus
      t.string :department
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
    add_index :river_courses_courses, [:class_no,:term], unique:true
    create_table :river_courses_mentors do |t|
      t.string :name, null:false
      t.string :department
      t.string :source_key
      t.jsonb :details, null:false, default:{}
      t.timestamps
    end
    add_index :river_courses_mentors, :source_key, unique:true
    create_table :river_courses_reviews do |t|
      t.string :subject_kind, null:false
      t.bigint :subject_id, null:false
      t.bigint :user_id, null:false
      t.string :status, null:false, default:'visible'
      t.boolean :anonymous, null:false, default:false
      t.jsonb :scores, null:false, default:{}
      t.text :body, null:false
      t.text :advice
      t.string :term_taken
      t.boolean :take_again
      t.timestamps
    end
    add_index :river_courses_reviews, [:subject_kind,:subject_id,:user_id], unique:true, name:'river_courses_review_unique'
    create_table :river_courses_bookmarks do |t|
      t.bigint :user_id, null:false
      t.string :group_key, null:false
      t.timestamps
    end
    add_index :river_courses_bookmarks, [:user_id,:group_key], unique:true
  end
end
