# frozen_string_literal: true
module DiscourseCourseReview
  class CatalogImporter
    def self.run(payload,actor:,apply:false)
      raise Discourse::InvalidAccess unless Access.admin?(actor)
      raise Error,'目录文件格式不符' unless payload['format']=='riverside-course-catalog-v1'
      raise Error,'请先开启课程只读模式，再更新目录' if apply && !SiteSetting.courses_read_only
      result={courses_created:0,courses_updated:0,mentors_created:0,mentors_updated:0,apply:apply}
      Record.transaction do
        Shared.lock('catalog-import')
        Array(payload['courses']).each do |row|
          item=Course.find_or_initialize_by(class_no:Shared.text(row['classNo'],100),term:row['term'].to_s)
          result[item.new_record? ? :courses_created : :courses_updated]+=1
          old_key=item.group_key
          item.update!(code:Shared.text(row['courseCode'],100),title:Shared.text(row['title'],200),teachers:Shared.text(row['teachers'],500,required:false),campus:row['campus'],department:row['openingDepartment'],details:row.except('rawJson').transform_keys(&:underscore))
          if old_key.present? && old_key!=item.group_key && !Course.exists?(group_key:old_key)
            Bookmark.where(group_key:old_key).find_each do |b|
              Bookmark.exists?(user_id:b.user_id,group_key:item.group_key) ? b.destroy! : b.update!(group_key:item.group_key)
            end
          end
        end
        Array(payload['mentors']).each do |row|
          item=Mentor.find_or_initialize_by(source_key:Shared.text(row['sourceKey'],100))
          result[item.new_record? ? :mentors_created : :mentors_updated]+=1
          item.update!(name:Shared.text(row['name'],100),department:row['department'],details:row.transform_keys(&:underscore))
        end
        Audit.create!(user_id:actor.id,action:'catalog_import',reason:'管理员导入课程与导师目录',details:result) if apply
        raise ActiveRecord::Rollback unless apply
      end
      result
    end
  end
end
