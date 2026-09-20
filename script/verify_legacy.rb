# frozen_string_literal: true
# Read-only reconciliation immediately after import and before allowing edits.
raw=File.binread(ARGV.fetch(0));payload=JSON.parse(raw)
raise 'Wrong source' unless payload['project']=='course-review' && payload['format']=='riverside-community-v1'
a=DiscourseCourseReview;tables=payload.fetch('tables');report={verified:true,sha256:Digest::SHA256.hexdigest(raw)}
ActiveRecord::Base.transaction do
  ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY')
  archive=a::Legacy.all.index_by { |l| [l.source,l.legacy_id] }
  live={ 'Course'=>a::Course.all.index_by(&:id),'Mentor'=>a::Mentor.all.index_by(&:id),'Review'=>a::Review.all.index_by(&:id),'Comment'=>a::Comment.all.index_by(&:id),'Reaction'=>a::Reaction.all.index_by(&:id),'Report'=>a::Report.all.index_by(&:id),'Bookmark'=>a::Bookmark.all.index_by(&:id) }
  checks=0
  fetch=lambda { |source,id| l=archive.fetch([source,id.to_s]);live.fetch(l.target_kind).fetch(l.target_id) }
  eq=lambda { |actual,expected,label| raise "Mismatch: #{label}" unless actual==expected;checks+=1 }
  stamp=lambda do |item,row|
    {'createdAt'=>:created_at,'updatedAt'=>:updated_at}.each do |old,key|
      next unless row[old]
      raise "Timestamp mismatch: #{key}" unless (item.public_send(key)-Time.iso8601(row[old])).abs<0.001
      checks+=1
    end
  end
  tables.each do |source,rows|
    rows.each do |row|
      legacy=archive.fetch([source,row.fetch('id')]);eq.call(legacy.data,row,"#{source} archive")
      item=fetch.call(source,row['id']);stamp.call(item,row)
      if source=='Course'
        {'class_no'=>'classNo','code'=>'courseCode','title'=>'title','teachers'=>'teachers','campus'=>'campus','department'=>'openingDepartment'}.each { |key,old| eq.call(item.public_send(key),row[old],"Course #{key}") }
        eq.call(item.term,row['term'] || '', 'Course term')
        eq.call(item.details,row.except('rawJson').transform_keys(&:underscore),'Course metadata')
        eq.call(item.group_key,a::Service.group_key(item),'Course grouping')
      elsif source=='Mentor'
        %w[name department].each { |key| eq.call(item.public_send(key),row[key],"Mentor #{key}") }
        eq.call(item.source_key,row['sourceKey'],'Mentor source key')
        eq.call(item.details,row.transform_keys(&:underscore),'Mentor metadata')
      elsif %w[Review MentorReview].include?(source)
        course=source=='Review';kind=course ? 'Course' : 'Mentor';subject=fetch.call(kind,row[course ? 'courseId' : 'mentorId'])
        eq.call(item.subject_kind,kind,'Review kind');eq.call(item.subject_id,subject.id,'Review subject');eq.call(item.user_id,Integer(row['externalUserId'],10),'Review owner')
        eq.call(item.status,row['hidden'] ? 'hidden' : 'visible','Review visibility');eq.call(item.anonymous,row['anonymous'],'Review anonymity')
        {'body'=>'content','advice'=>'advice','term_taken'=>'termTaken','take_again'=>'takeAgain','hidden_reason'=>'hiddenReason'}.each { |key,old| eq.call(item.public_send(key),row[old],"Review #{key}") }
        fields=course ? {'overall'=>'overallRating','course'=>'courseRating','teacher'=>'teacherRating','difficulty'=>'difficulty','grading'=>'gradingFairness'} : {'overall'=>'overallRating','guidance'=>'guidanceRating','communication'=>'communicationRating'}
        eq.call(item.scores,fields.transform_values { |key| row[key] },'Review scores')
      elsif source=='CourseBookmark'
        decoded=JSON.parse(Base64.urlsafe_decode64(row['courseGroupKey']))
        key=[decoded['courseCode'].presence || decoded['classNo'].to_s.split('.').first,decoded['title'],decoded['teachers'].to_s.split(';').map(&:strip).reject(&:blank?).sort.join(';')].to_json
        eq.call(item.group_key,key,'Bookmark key');eq.call(item.user_id,Integer(row['externalUserId'],10),'Bookmark owner')
        raise 'Bookmark has no matching course' unless a::Course.exists?(group_key:key)
      else
        prefix=source.start_with?('Mentor') ? 'MentorReview' : 'Review'
        eq.call(item.user_id,Integer(row['externalUserId'],10),"#{source} owner")
        if source.end_with?('Comment')
          eq.call(item.body,row['content'],'Comment body');eq.call(item.anonymous,row['anonymous'],'Comment anonymity')
          eq.call(item.target_id,fetch.call(prefix,row['reviewId']).id,'Comment review')
          eq.call(item.status,row['hidden'] ? 'hidden' : 'visible','Comment visibility')
          eq.call(item.parent_id,row['parentId'] && fetch.call(prefix+'Comment',row['parentId']).id,'Reply parent')
        else
          comment=row.key?('commentId');target=fetch.call(comment ? prefix+'Comment' : prefix,row[comment ? 'commentId' : 'reviewId'])
          eq.call(item.target_kind,comment ? 'Comment' : 'Review','Interaction kind');eq.call(item.target_id,target.id,'Interaction target')
          if source.end_with?('Report')
            eq.call(item.reason,row['reason'],'Report reason');eq.call(item.handled_at.present?,row['handled'],'Report handled')
          else
            value=source.end_with?('Dislike') || row['type']=='DISLIKE' ? -1 : 1
            eq.call(item.value,value,'Reaction value')
          end
        end
      end
    end
  end
  expected={'Course'=>tables['Course'].size,'Mentor'=>tables['Mentor'].size,'Review'=>tables['Review'].size+tables['MentorReview'].size,'Comment'=>tables['ReviewComment'].size+tables['MentorReviewComment'].size,'Bookmark'=>tables['CourseBookmark'].size,'Reaction'=>tables.select { |name,_| name.end_with?('Like','Dislike','Reaction') }.values.sum(&:size),'Report'=>tables.select { |name,_| name.end_with?('Report') }.values.sum(&:size)}
  expected.each { |name,count| eq.call(live[name].size,count,"#{name} count") }
  eq.call(a::Event.count,0,'No imported notifications');eq.call(a::Command.count,0,'No imported commands')
  report.merge!(field_checks:checks,source_counts:tables.transform_values(&:size),target_counts:live.transform_values(&:size),anonymous_reviews:a::Review.where(anonymous:true).count,hidden_reviews:a::Review.where(status:'hidden').count,events:0,commands:0)
end
puts JSON.pretty_generate(report)
