# frozen_string_literal: true
require 'digest'
module DiscourseCourseReview
  class Importer
    def initialize(payload, directory: nil, allow_unmapped: false)
      @payload=payload;@tables=payload.fetch('tables');@directory=directory;@allow_unmapped=allow_unmapped;@unmapped=[];@media_cache={}
      raise Error,'导出文件格式或项目不符' unless payload['format']=='riverside-community-v1' && payload['project']=='course-review'
    end
    def rows(name) = @tables[name] || []
    def ref(name,id,optional:false)
      return nil if id.nil? && optional
      value=Legacy.find_by(source:name,legacy_id:id.to_s)&.target_id
      raise Error,"缺少关联：#{name}/#{id}" unless value || optional
      value
    end
    def user(id,optional:false)
      return nil if id.nil? && optional
      uid=Integer(id.to_s,10) rescue nil
      raise Error,"论坛用户不存在：#{id}" unless uid && User.exists?(uid)
      uid
    end
    def local_user(id,optional:false)
      return nil if id.nil? && optional
      row=rows('User').find { |u| u['id'].to_s==id.to_s }
      raise Error,"本地用户不存在：#{id}" unless row
      if @payload['project']=='seek'
        verified_mapping=@payload.fetch('user_mapping',{})[id.to_s]
        return user(verified_mapping) if verified_mapping
        key=row['providerUserKey'].to_s
        if key.start_with?('discourse:')
          return user(key.split(':',2)[1])
        end
        @unmapped<<id.to_s unless @unmapped.include?(id.to_s)
        raise Error,"旧账号 #{id} 尚未关联论坛；请提供验证后的映射，或显式允许保留无主历史内容" unless @allow_unmapped
        return nil
      end
      user(row.fetch('externalUserId'))
    end
    def stamp(row)
      %w[createdAt updatedAt].each_with_object({}) do |key,h|
        h[key=='createdAt' ? :created_at : :updated_at]=Time.iso8601(row[key]) if row[key].present?
      end
    end
    def put(source,row,klass,attrs)
      item=klass.create!(stamp(row).merge(attrs))
      Legacy.find_by!(source:source,legacy_id:row.fetch('id').to_s).update!(target_kind:klass.name.demodulize,target_id:item.id)
      item
    end
    def status(row)
      value=row['status'].to_s.downcase
      return value if %w[visible hidden deleted].include?(value)
      row['hidden'] || row['hiddenAt'] ? 'hidden' : 'visible'
    end
    def images(values,uid)
      values=JSON.parse(values) if values.is_a?(String)
      Array(values).map do |name|
        next @media_cache[name] if @media_cache.key?(name)
        entry=Array(@payload['media']).find { |m| m['name']==name }
        raise Error,"缺少图片文件：#{name}" unless entry && @directory
        root=File.realpath(@directory);path=File.realpath(File.join(root,entry.fetch('file')))
        raise Error,'图片路径越界' unless path.start_with?(root+'/')
        raw=File.binread(path);raise Error,'图片校验和不符' unless Digest::SHA256.hexdigest(raw)==entry['sha256']
        bytes=Shared.image(raw)
        raise Error,'压缩后图片超过 1MB' if bytes.bytesize>1.megabyte
        # Unmapped public food images are attributed to the system, not an arbitrary member.
        media=Media.create!(user_id:uid || Discourse.system_user.id,token:SecureRandom.hex(24),bytes:bytes,size:bytes.bytesize)
        @media_cache[name]=media.id
      end
    end
    def run(sha:,apply:false,expected_sha:nil)
      raise Error,'正式导入需要匹配的 SHA256' if apply && sha!=expected_sha
      raise Error,'正式导入前请关闭插件' if apply && SiteSetting.courses_enabled
      result=nil
      Record.transaction do
        Shared.lock('legacy-import')
        existing=Legacy.find_by(source:'__manifest',legacy_id:sha)
        if existing
          result={already_imported:true,sha256:sha,counts:existing.data['counts']};next
        end
        tables=ActiveRecord::Base.connection.tables.grep(/\Ariver_courses_/)
        occupied=tables.any? { |table| ActiveRecord::Base.connection.select_value("SELECT EXISTS(SELECT 1 FROM #{ActiveRecord::Base.connection.quote_table_name(table)})") }
        raise Error,'目标插件已有业务数据，请使用空的隔离目标演练' if occupied
        @tables.each do |source,records|
          raise Error,'记录列表无效' unless records.is_a?(Array)
          records.each { |row| Legacy.create!(source:source,legacy_id:row.fetch('id',row['key']).to_s,data:row) }
        end
        import_domain
        counts=tables.to_h { |table| [table,ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{ActiveRecord::Base.connection.quote_table_name(table)}").to_i] }
        # No old event is delivered by importing; notifications remain in the archive.
        result={sha256:sha,apply:apply,source_counts:@tables.transform_values(&:size),counts:counts,unmapped_accounts:@unmapped}
        Legacy.create!(source:'__manifest',legacy_id:sha,data:result)
        ActiveRecord::Base.connection.execute('SET CONSTRAINTS ALL IMMEDIATE')
        raise ActiveRecord::Rollback unless apply
      end
      result
    end
    def import_interactions(review_sources)
      review_sources.each do |source,target_source|
        rows(source+'Like').each { |row| import_reaction(source+'Like',row,target_source,row['reviewId'],1) }
        rows(source+'Dislike').each { |row| import_reaction(source+'Dislike',row,target_source,row['reviewId'],-1) }
        pending=rows(source+'Comment').dup
        until pending.empty?
          progress=false
          pending.delete_if do |row|
            parent=row['parentId'];next false if parent && !Legacy.find_by(source:source+'Comment',legacy_id:parent.to_s)&.target_id
            review=Review.find(ref(target_source,row['reviewId']))
            put(source+'Comment',row,Comment,{user_id:user(row['externalUserId']),target_kind:'Review',target_id:review.id,parent_id:parent ? ref(source+'Comment',parent) : nil,anonymous:!!row['anonymous'],body:row['content'],status:status(row)})
            progress=true;true
          end
          raise Error,'评论父子关系有缺失或循环' unless progress
        end
        rows(source+'CommentReaction').each { |row| import_reaction(source+'CommentReaction',row,source+'Comment',row['commentId'],row['type']=='DISLIKE' ? -1 : 1) }
        [source+'Report',source+'CommentReport'].each do |rsource|
          rows(rsource).each do |row|
            comment=rsource.end_with?('CommentReport')
            put(rsource,row,Report,{user_id:user(row['externalUserId']),target_kind:comment ? 'Comment' : 'Review',target_id:ref(comment ? source+'Comment' : target_source,row[comment ? 'commentId' : 'reviewId']),reason:row['reason'],handled_at:row['handled'] ? Time.current : nil})
          end
        end
      end
    end
    def import_reaction(source,row,target_source,target_id,value)
      target=Legacy.find_by!(source:target_source,legacy_id:target_id.to_s)
      uid=row.key?('externalUserId') ? user(row['externalUserId']) : local_user(row['userId'])
      return unless uid # Explicit allow_unmapped only; original record retained in Legacy.
      item=Reaction.find_or_initialize_by(user_id:uid,target_kind:target.target_kind,target_id:target.target_id)
      raise Error,'同一用户对同一内容有冲突的赞踩记录' if item.persisted? && item.value!=value
      item.update!(stamp(row).merge(value:value))
      Legacy.find_by!(source:source,legacy_id:row['id'].to_s).update!(target_kind:'Reaction',target_id:item.id)
    end
  end
end

module DiscourseCourseReview
  class Importer
    def import_domain
      rows('Course').each { |r| put('Course',r,Course,{class_no:r['classNo'],code:r['courseCode'],title:r['title'],teachers:r['teachers'],term:r['term'] || '',campus:r['campus'],department:r['openingDepartment'],details:r.except("rawJson").transform_keys { |k| k.underscore }}) }
      rows('Mentor').each { |r| put('Mentor',r,Mentor,{name:r['name'],department:r['department'],source_key:r['sourceKey'],details:r.transform_keys { |k| k.underscore }}) }
      {'Review'=>['Course','courseId',{'overall'=>'overallRating','course'=>'courseRating','teacher'=>'teacherRating','difficulty'=>'difficulty','grading'=>'gradingFairness'}],'MentorReview'=>['Mentor','mentorId',{'overall'=>'overallRating','guidance'=>'guidanceRating','communication'=>'communicationRating'}]}.each do |source,(kind,id_key,scores)|
        rows(source).each do |r|
          values=scores.transform_values { |key| Float(r.fetch(key)) }
          raise Error,'旧评价评分超出有效范围' unless values.values.all? { |v| v.finite? && v.between?(0.5,5) && (v*2)%1==0 }
          put(source,r,Review,{subject_kind:kind,subject_id:ref(kind,r[id_key]),user_id:user(r['externalUserId']),status:status(r),hidden_reason:r['hiddenReason'],anonymous:!!r['anonymous'],scores:values,body:r['content'],advice:r['advice'],term_taken:r['termTaken'],take_again:r['takeAgain']})
        end
      end
      import_interactions([['Review','Review'],['MentorReview','MentorReview']])
      rows('CourseBookmark').each do |r|
        decoded=JSON.parse(Base64.urlsafe_decode64(r['courseGroupKey']))
        key=[decoded['courseCode'] || decoded['classNo'].to_s.split('.').first,decoded['title'],decoded['teachers'].to_s.split(';').map(&:strip).reject(&:blank?).sort.join(';')].to_json
        put('CourseBookmark',r,Bookmark,{user_id:user(r['externalUserId']),group_key:key})
      end
    end
  end
end
