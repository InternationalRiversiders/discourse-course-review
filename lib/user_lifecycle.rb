# frozen_string_literal: true
module DiscourseCourseReview
  module Shared
    def self.comment_body(value)
      body=text(value,500)
      raise Error,'回复内容至少 2 个字' if body.length<2
      body
    end
    def self.content_path(item)
      review_id=item.is_a?(Review) ? item.id : item.target_id
      "/courses?view=review&id=#{review_id}"
    end
    def self.remove_content(item)
      kind=item.class.name.demodulize
      if item.is_a?(Review)
        Comment.where(target_kind:'Review',target_id:item.id).find_each { |comment| remove_content(comment) }
      else
        Comment.where(parent_id:item.id).update_all(parent_id:nil)
      end
      # Drop every archived interaction for this item as well as the live rows.
      reaction_ids=Reaction.where(target_kind:kind,target_id:item.id).pluck(:id)
      report_ids=Report.where(target_kind:kind,target_id:item.id).pluck(:id)
      Legacy.where(target_kind:'Reaction',target_id:reaction_ids).delete_all
      Legacy.where(target_kind:'Report',target_id:report_ids).delete_all
      Reaction.where(target_kind:kind,target_id:item.id).delete_all
      Report.where(target_kind:kind,target_id:item.id).delete_all
      Legacy.where(target_kind:kind,target_id:item.id).delete_all
      item.destroy!
    end
  end
  module UserLifecycle
    def self.export(id)
      {exported_at:Time.current.iso8601,reviews:Review.where(user_id:id).as_json,comments:Comment.where(user_id:id).as_json,bookmarks:Bookmark.where(user_id:id).as_json,reactions:Reaction.where(user_id:id).as_json,reports:Report.where(user_id:id).as_json,legacy:Legacy.where("data->>'externalUserId' = ?",id.to_s).pluck(:data)}
    end
    def self.purge(id)
      return unless Review.table_exists?
      Record.transaction do
        Shared.lock("user:#{id}")
        Review.where(user_id:id).find_each { |item| Shared.remove_content(item) }
        Comment.where(user_id:id).find_each { |item| Shared.remove_content(item) }
        [Bookmark,Reaction,Report,Command,Media,Event].each { |klass| klass.where(user_id:id).delete_all }
        Legacy.where("data->>'externalUserId' = ?",id.to_s).delete_all
        Audit.where(user_id:id).update_all(user_id:Discourse.system_user.id)
        Notification.where(user_id:id,notification_type:Notification.types[:custom]).where("data::jsonb->>'river_app' = 'courses'").destroy_all
      end
    end
    def self.merge(source,target)
      return unless Review.table_exists?
      Record.transaction do
        [source.id,target.id].sort.each { |id| Shared.lock("user:#{id}") }
        Review.where(user_id:source.id).find_each do |r|
          unless Review.exists?(user_id:target.id,subject_kind:r.subject_kind,subject_id:r.subject_id)
            r.update!(user_id:target.id,anonymous:true)
          end
        end
        Comment.where(user_id:source.id).update_all(user_id:target.id,anonymous:true)
        {Bookmark=>[:group_key],Reaction=>[:target_kind,:target_id],Report=>[:target_kind,:target_id]}.each do |klass,keys|
          klass.where(user_id:source.id).find_each do |item|
            attrs=item.attributes.slice(*keys.map(&:to_s))
            item.update!(user_id:target.id) unless klass.exists?(attrs.merge(user_id:target.id))
          end
        end
        purge(source.id)
      end
    end
  end
  module Service
    def self.legacy_query(path,params={})
      path=path.sub(%r{\A/},'').delete_suffix('/')
      if path.blank?
        view=%w[reviews courses mentors].include?(params['tab']) ? params['tab'] : 'home'
        query=params.slice('q','campus','college','semester','page')
        query['school_year']=params['schoolYear'] if params['schoolYear'].present?
        return query.merge(view:view)
      end
      return {view:'mine'} if path=='me'
      if path=='admin'
        query={view:'admin',part:params['tab']=='reports' ? 'reports' : 'reviews'}
        query[:kind]='Mentor' if params['tab']=='mentors'
        query[:page]=params['page'] if params['page'].present?
        return query
      end
      kind,key=path.split('/',2)
      return {view:'teachers',q:params['q'].to_s} if kind=='teachers' && key.blank?
      case kind
      when 'courses'
        id=Legacy.find_by(source:'Course',legacy_id:key)&.target_id
        {view:'course',id:id} if id
      when 'course-groups'
        decoded=JSON.parse(Base64.urlsafe_decode64(key))
        normalized=[decoded['courseCode'].presence || decoded['classNo'].to_s.split('.').first,decoded['title'],decoded['teachers'].to_s.split(';').map(&:strip).reject(&:blank?).sort.join(';')].to_json
        course=Course.where(group_key:normalized).order(term: :desc,class_no: :asc).first
        {view:'course',id:course.id} if course
      when 'teachers'
        department,name=CGI.unescape(key).split('::',2)
        {view:'teacher',name:name,department:department} if department.present? && name.present?
      when 'mentors'
        id=Mentor.find_by(source_key:key)&.id || Legacy.find_by(source:'Mentor',legacy_id:key)&.target_id
        {view:'mentor',id:id} if id
      end
    rescue JSON::ParserError,ArgumentError
      nil
    end
  end
end
DiscourseEvent.on(:user_destroyed) { |user| DiscourseCourseReview::UserLifecycle.purge(user.id) }
DiscourseEvent.on(:user_anonymized) { |user:, **_| DiscourseCourseReview::UserLifecycle.purge(user.id) }
DiscourseEvent.on(:merging_users) { |source,target| DiscourseCourseReview::UserLifecycle.merge(source,target) }
