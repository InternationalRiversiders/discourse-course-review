# frozen_string_literal: true
module DiscourseCourseReview
  module Service
    COURSE_SCORES={'overall'=>'综合评分','course'=>'课程体验','teacher'=>'教学质量','difficulty'=>'课程难度','grading'=>'给分友好'}.freeze
    MENTOR_SCORES={'overall'=>'综合评分','guidance'=>'指导质量','communication'=>'沟通体验'}.freeze
    STATUS={'visible'=>'公开','hidden'=>'已隐藏','deleted'=>'已删除'}.freeze
    def self.targets = {'Review'=>Review,'Comment'=>Comment}
    def self.group_key(course)
      [course.code.presence || course.class_no.split('.').first,course.title,course.teachers.split(';').map(&:strip).reject(&:blank?).sort.join(';')].to_json
    end
    def self.teachers(course)
      names=course.teachers.split(';').map(&:strip).reject(&:blank?)
      departments=course.details['teacher_departments'].to_s.split(',').map(&:strip).reject(&:blank?)
      titles=course.details['teacher_titles'].to_s.split(',').map(&:strip).reject(&:blank?)
      names.each_with_index.map { |name,i| {name:name,department:departments[i] || departments.first || '未知院系',title:titles[i]} }
    end
    def self.visible_target!(item,user)
      raise Discourse::InvalidAccess unless item.status=='visible'
      raise Discourse::InvalidAccess if item.is_a?(Comment) && !Review.exists?(id:item.target_id,status:'visible')
    end
    def self.rating(value) = value.nil? ? '暂无' : format('%.1f',value.to_f.to_r.round(1))
    def self.stats(reviews,labels)
      values=reviews.pluck(:scores)
      labels.map do |key,label|
        scores=values.filter_map { |s| s[key]&.to_f }
        {label:label,value:rating(scores.empty? ? nil : scores.sum/scores.size)}
      end + [{label:'评价数量',value:values.size}]
    end
    def self.term_label(term)
      m=term.to_s.match(/\A(\d{4}-\d{4})-([12])\z/)
      m ? "#{m[1]} 学年#{m[2]=='1' ? '第一' : '第二'}学期" : term.presence || '未填写学期'
    end
    def self.score_hint(key)
      {'overall'=>'整体体验','course'=>'内容质量','teacher'=>'授课表达','difficulty'=>'越高越难','grading'=>'越高越友好','guidance'=>'越高越认可指导方式','communication'=>'越高越容易沟通'}[key]
    end
    def self.term_options(selected)
      years=(2015..[2027,Time.current.year+1].max).to_a.reverse
      values=([selected]+years.flat_map { |year| ["#{year}-#{year+1}-2","#{year}-#{year+1}-1"] }).compact.reject(&:blank?).uniq
      [['','未填写']]+values.map { |term| [term,term_label(term)] }
    end
    def self.review_form(user,kind,item)
      existing=Review.find_by(subject_kind:kind,subject_id:item.id,user_id:user.id)
      labels=kind=='Course' ? COURSE_SCORES : MENTOR_SCORES
      fields=labels.map { |key,label| Ui.field(key,label,(existing&.scores&.[](key) || '').to_s,type:'rating',required:true).merge(hint:score_hint(key)) }
      fields += [Ui.field('body','评价内容（至少 10 字）',existing&.body,type:'textarea',required:true).merge(minlength:10,maxlength:2000),Ui.field('advice','给后来者的建议',existing&.advice,type:'textarea').merge(maxlength:1000)]
      if kind=='Course'
        fields += [Ui.field('term_taken','修读学期',existing&.term_taken || item.term,type:'select',options:term_options(existing&.term_taken || item.term)),Ui.field('take_again','是否愿意再次选择',existing&.take_again.nil? ? '' : existing.take_again.to_s,type:'select',options:[['','不确定'],['true','愿意'],['false','不愿意']])]
      end
      fields << Ui.field('anonymous','匿名发布',existing&.anonymous,type:'checkbox')
      data={'kind'=>kind,'id'=>item.id,'expected_version'=>existing&.updated_at&.iso8601(6)}
      form=Ui.form(existing ? '更新我的评价' : '分享你的体验','review',fields,data,button:existing ? '更新评价' : '发布评价')
      form[:confirm]='你已评价过这个对象，确认用当前内容更新原评价？' if existing
      form[:note]='这条评价已被隐藏；修改不会自动恢复公开。' if existing&.status=='hidden'
      form
    end
    def self.subject(review)
      (review.subject_kind=='Course' ? Course : Mentor).find_by(id:review.subject_id)
    end
    def self.review_card(review,user,interaction:true)
      labels=review.subject_kind=='Course' ? COURSE_SCORES : MENTOR_SCORES
      item=subject(review)
      query={'view'=>review.subject_kind=='Course' ? 'course' : 'mentor','id'=>review.subject_id}
      reaction=Shared.reactions(review,user)
      count=Comment.where(target_kind:'Review',target_id:review.id,status:'visible').count
      author=review.anonymous ? nil : Shared.forum_user(review.user_id)
      card=Ui.card("review-#{review.id}",item.is_a?(Course) ? item.title : item&.name,review.body,
        type:'review',tag:review.anonymous ? '匿名评价' : (author ? nil : '已注销用户'),forum_user:author,
        subtitle:review.subject_kind=='Course' ? "#{item&.teachers} · #{term_label(review.term_taken)} · #{item&.class_no}" : item&.department,
        created_at:review.created_at.iso8601,advice:review.advice,
        author_name:review.anonymous ? '匿名评价' : (author ? author[:username] : '已注销用户'),
        subject_meta:review.subject_kind=='Course' ? [item&.teachers,item&.class_no].compact.join(' · ') : item&.department,
        study_term:review.subject_kind=='Course' ? term_label(review.term_taken) : nil,
        take_again:review.take_again,discussion_count:count,subject_query:query,
        metrics:labels.map { |key,label| {label:label,value:rating(review.scores[key])} },
        links:[Ui.link('查看详情',query),Ui.link("讨论 · #{count}",{'view'=>'review','id'=>review.id})])
      card[:details]=[{label:'再次选择',value:review.take_again ? '愿意' : '不愿意'}] unless review.take_again.nil?
      if review.status!='visible'
        card[:status]=STATUS[review.status];card[:hidden_reason]=review.hidden_reason
      elsif interaction
        ui=Shared.interaction_ui(review,user,comments:true,anonymous:true)
        card.merge!(ui.slice(:actions,:forms))
      end
      if user.id==review.user_id
        card[:mine]=true
        card[:links] << Ui.link('编辑我的评价',query)
      end
      card
    end
    def self.course_card(rows,user,popularity:nil)
      c=rows.first
      reviews=Review.where(subject_kind:'Course',subject_id:rows.map(&:id),status:'visible')
      card=Ui.card("course-#{c.id}",c.title,"#{c.code} · #{c.teachers}",type:'course',tag:c.campus,
        subtitle:"#{rows.size} 个教学班 · #{rows.map(&:term).reject(&:blank?).uniq.first(3).join(' / ')}",
        metrics:stats(reviews,{'overall'=>'综合评分'}),links:[Ui.link('课程详情',{'view'=>'course','id'=>c.id})])
      card[:badge]="近期 #{popularity} 条评价" if popularity
      card
    end
    def self.mentor_card(m)
      Ui.card("mentor-#{m.id}",m.name,m.details['research_direction'],type:'mentor',tag:m.details['title'],subtitle:m.department,
        metrics:stats(Review.where(subject_kind:'Mentor',subject_id:m.id,status:'visible'),{'overall'=>'综合评分'}),links:[Ui.link('导师详情',{'view'=>'mentor','id'=>m.id})])
    end
    def self.paginate(out,query,total,limit)
      pages=[(total.to_f/limit).ceil,1].max
      page=[[query['page'].to_i,1].max,pages].min
      base=query.slice('view','q','campus','term','college','school_year','semester','id','name','department','kind','status','part')
      base['view']=out[:view]
      out[:pagination]={page:page,pages:pages,total:total}
      out[:previous]=base.merge('page'=>page-1) if page>1
      out[:next]=base.merge('page'=>page+1) if page<pages
      (page-1)*limit
    end
    def self.recent(scope) = scope.order(created_at: :desc,id: :desc)
    def self.state(user,query)
      Access.check!(user)
      tabs=[['home','首页'],['reviews','课程评价'],['courses','课程列表'],['teachers','任课教师'],['mentors','导师评价'],['mine','我的评价与收藏']]
      tabs << ['admin','管理'] if Access.admin?(user)
      out=Ui.shell(user,query,tabs,empty_title:'还没有相关内容',empty_text:'试试其他关键词，或分享你的第一条评价。')
      out[:readonly]=SiteSetting.courses_read_only
      out[:sections]=[]
      q=query['q'].to_s.strip
      raise Error,'搜索关键词最多 100 字' if q.length>100
      case out[:view]
      when 'home'
        return state(user,query.merge('view'=>'courses')) if %w[q campus term college school_year semester].any? { |key| query[key].present? }
        out[:filters]=Catalog.filters(query)
        out[:stats]=[{label:'课程组合',value:Course.distinct.count(:group_key)},{label:'教学班',value:Course.count},{label:'课程评价',value:Review.where(subject_kind:'Course',status:'visible').count},{label:'导师',value:Mentor.count}]
        latest=recent(Review.where(subject_kind:'Course',status:'visible'))
        ids=latest.limit(240).pluck(:subject_id)
        counts=ids.tally
        grouped=Catalog.listing(Course.where(id:ids.uniq)).order(term: :desc,class_no: :asc).to_a.group_by(&:group_key).values
        popular=Catalog.chinese_order(grouped) { |rows| rows.first.title }.each_with_index.sort_by { |rows,index| [-rows.sum { |c| counts[c.id] || 0 },index] }.first(8).map(&:first)
        out[:sections] << {id:'popular-courses',title:'热门课程',description:'最近 240 条公开课程评价中的讨论热度',cards:popular.map { |rows| course_card(rows,user,popularity:rows.sum { |c| counts[c.id] || 0 }) },more:Ui.link('全部课程',{'view'=>'courses'})}
        out[:sections] << {id:'recent-reviews',title:'最新课程评价',cards:latest.limit(10).map { |r| review_card(r,user) },more:Ui.link('全部评价',{'view'=>'reviews'})}
        mentor_ids=Review.where(subject_kind:'Mentor',status:'visible').group(:subject_id).order(Arel.sql('COUNT(*) DESC'),:subject_id).limit(8).count.keys
        mentors=Mentor.where(id:mentor_ids).index_by(&:id)
        out[:sections] << {id:'popular-mentors',title:'热门导师',cards:mentor_ids.filter_map { |id| mentors[id] && mentor_card(mentors[id]) },more:Ui.link('导师库',{'view'=>'mentors'})}
        out[:sections] << {id:'recent-mentor-reviews',title:'最新导师评价',cards:recent(Review.where(subject_kind:'Mentor',status:'visible')).limit(5).map { |r| review_card(r,user) }}
      when 'courses'
        groups=Catalog.groups(query);offset=paginate(out,query,groups.size,40)
        out[:filters]=Catalog.filters(query)
        out[:stats]=[{label:'课程组合',value:groups.size},{label:'教学班',value:groups.sum(&:size)}]
        out[:cards]=groups.slice(offset,40).to_a.map { |rows| course_card(rows,user) }
        if q.present?
          identities=Catalog.listing(Course.where('teachers ILIKE ?', "%#{ActiveRecord::Base.sanitize_sql_like(q)}%")).flat_map { |c| teachers(c) }.select { |t| t[:name]==q }.uniq { |t| [t[:name],t[:department]] }
          unless identities.empty?
            out[:sections] << {id:'matching-teachers',title:'同名任课教师',cards:identities.map { |t| Ui.card([t[:department],t[:name]].join(':'),t[:name],t[:department],links:[Ui.link('查看该教师的所有授课与评价',{'view'=>'teacher','name'=>t[:name],'department'=>t[:department]})]) }}
          end
        end
      when 'reviews'
        scope=Review.where(status:'visible',subject_kind:'Course')
        out[:filters]=Catalog.filters(query)
        if %w[q campus term college school_year semester].any? { |k| query[k].present? }
          scope=scope.where(subject_id:Catalog.course_scope(query).select(:id))
        end
        offset=paginate(out,query,scope.count,20)
        out[:cards]=recent(scope).offset(offset).limit(20).map { |r| review_card(r,user) }
      when 'teachers','teacher'
        courses=Catalog.listing.order(term: :desc,class_no: :asc).to_a
        if out[:view]=='teacher'
          selected=courses.select { |c| teachers(c).any? { |t| t[:name]==query['name'] && t[:department]==query['department'] } }
          raise Discourse::NotFound if selected.empty?
          reviews=Review.where(subject_kind:'Course',subject_id:selected.map(&:id),status:'visible')
          out[:note]="#{query['department']} · #{query['name']}。评分汇总该教师参与授课的教学班。"
          out[:stats]=stats(reviews,COURSE_SCORES)
          groups=selected.group_by(&:group_key).values
          out[:sections] << {id:'teacher-courses',title:'任课课程',cards:groups.map { |rows| course_card(rows,user) }}
          offset=paginate(out,query,reviews.count,20)
          out[:cards]=recent(reviews).offset(offset).limit(20).map { |r| review_card(r,user) }
        else
          identities={}
          courses.each { |c| teachers(c).each { |t| key=[t[:name],t[:department]]; entry=(identities[key] ||= t.merge(count:0));entry[:count]+=1 } }
          rows=identities.values.select { |t| q.blank? || [t[:name],t[:department],t[:title]].join(' ').downcase.include?(q.downcase) }
          rows=Catalog.chinese_order(rows) { |t| t[:name] }
          out[:filters]=[Ui.field('q','教师姓名或院系',q)]
          offset=paginate(out,query,rows.size,40)
          out[:cards]=rows.slice(offset,40).to_a.map { |t| Ui.card([t[:name],t[:department]].join(':'),t[:name],t[:department],subtitle:"#{t[:title]} · #{t[:count]} 个教学班",links:[Ui.link('授课与评价',{'view'=>'teacher','name'=>t[:name],'department'=>t[:department]})]) }
        end
      when 'mentors'
        scope=Catalog.search(Mentor.all,q,["name","department","details->>'title'","details->>'research_direction'"])
        scope=scope.where(department:query['college']) if query['college'].present?
        out[:filters]=Catalog.filters(query,mentor:true)
        offset=paginate(out,query,scope.count,40)
        out[:cards]=Catalog.mentor_order(scope,q).offset(offset).limit(40).map { |m| mentor_card(m) }
      when 'course','mentor'
        kind=out[:view]=='course' ? 'Course' : 'Mentor'
        item=(kind=='Course' ? Course : Mentor).find(Shared.id(query['id']))
        rows=kind=='Course' ? Course.where(group_key:item.group_key).order(term: :desc,class_no: :asc).to_a : [item]
        reviews=Review.where(subject_kind:kind,subject_id:rows.map(&:id),status:'visible')
        out[:stats]=stats(reviews,kind=='Course' ? COURSE_SCORES : MENTOR_SCORES)
        out[:note]=kind=='Course' ? "评分汇总同课程、同教师的各学期教学班。当前评价教学班：#{item.class_no} / #{term_label(item.term)}。" : '导师评价独立于任课教师的课程评价。'
        if kind=='Course'
          selected=Ui.card('detail',item.title,item.teachers,type:'detail',subtitle:"#{item.code} · #{term_label(item.term)} · #{item.campus}",details:course_details(item),links:teachers(item).map { |t| Ui.link("#{t[:name]} · #{t[:department]}",{'view'=>'teacher','name'=>t[:name],'department'=>t[:department]}) },actions:[Ui.action(Bookmark.exists?(user_id:user.id,group_key:item.group_key) ? '取消收藏' : '收藏课程','bookmark',{'id'=>item.id})])
          out[:sections] << {id:'course-information',title:'课程信息',cards:[selected]}
          out[:sections] << {id:'offerings',title:'教学班',cards:rows.map { |c| Ui.card("offering-#{c.id}","#{c.class_no} · #{term_label(c.term)}",format_schedule(c),type:'offering',tag:c.id==item.id ? '当前教学班' : c.campus,details:[{label:'容量',value:c.details['capacity']},{label:'地点',value:c.details['location']}].reject { |d| d[:value].blank? },links:[Ui.link('选择此教学班并评价',{'view'=>'course','id'=>c.id})]) }}
        else
          out[:sections] << {id:'mentor-information',title:'导师信息',cards:[mentor_detail(item)]}
        end
        offset=paginate(out,query,reviews.count,20)
        out[:cards]=recent(reviews).offset(offset).limit(20).map { |r| review_card(r,user) }
        out[:forms]=[review_form(user,kind,item)] unless out[:readonly]
      when 'review'
        review=Review.find(Shared.id(query['id']))
        raise Discourse::InvalidAccess unless review.status=='visible' || review.user_id==user.id || Access.admin?(user)
        card=review_card(review,user,interaction:review.status=='visible')
        card[:links].reject! { |l| l[:query]['view']=='review' }
        out[:cards]=[card]
        if review.status=='visible'
          comments=Comment.where(target_kind:'Review',target_id:review.id,status:'visible').order(:created_at,:id)
          offset=paginate(out,query,comments.count,50)
          out[:sections] << {id:'comments',title:'讨论',cards:comments.offset(offset).limit(50).map { |c| comment_card(c,user) }}
        end
      when 'mine'
        part=%w[reviews comments bookmarks].include?(query['part']) ? query['part'] : 'reviews'
        out[:filters]=[Ui.field('q','搜索我的内容',q),Ui.field('part','内容类型',part,type:'select',options:[['reviews','我的评价'],['comments','我的评论'],['bookmarks','我的收藏']])]
        if part=='reviews'
          scope=Review.where(user_id:user.id).where.not(status:'deleted')
          scope=scope.where('body ILIKE ?',"%#{ActiveRecord::Base.sanitize_sql_like(q)}%") if q.present?
          offset=paginate(out,query,scope.count,20)
          out[:cards]=recent(scope).offset(offset).limit(20).map do |r|
            c=review_card(r,user,interaction:false);c[:status]=STATUS[r.status];c[:actions]=[Ui.action('删除评价','delete_own',{'kind'=>'Review','id'=>r.id}).merge(confirm:'删除评价也会删除其讨论，确定继续？')];c
          end
        elsif part=='comments'
          scope=Comment.where(user_id:user.id).where.not(status:'deleted')
          scope=scope.where('body ILIKE ?',"%#{ActiveRecord::Base.sanitize_sql_like(q)}%") if q.present?
          offset=paginate(out,query,scope.count,30)
          out[:cards]=recent(scope).offset(offset).limit(30).map { |c| comment_card(c,user,personal:true) }
        else
          scope=Bookmark.where(user_id:user.id)
          scope=scope.where('group_key ILIKE ?',"%#{ActiveRecord::Base.sanitize_sql_like(q)}%") if q.present?
          offset=paginate(out,query,scope.count,30)
          out[:cards]=scope.order(created_at: :desc,id: :desc).offset(offset).limit(30).map do |b|
            course=Catalog.listing(Course.where(group_key:b.group_key)).order(term: :desc,class_no: :asc).first
            card=course ? course_card(Catalog.listing(Course.where(group_key:course.group_key)).order(term: :desc,class_no: :asc).to_a,user) : Ui.card("bookmark-#{b.id}",'课程已不在目录中')
            card[:actions]=[Ui.action('取消收藏','remove_bookmark',{'id'=>b.id})];card
          end
        end
        out[:export_url]='/courses/export'
      when 'admin'
        Access.check!(user,admin:true)
        admin_state(out,user,query)
      else
        raise Discourse::NotFound
      end
      if out[:readonly]
        (out[:cards]+out[:sections].flat_map { |s| s[:cards] }).each { |c| c[:actions]=[];c[:forms]=[] }
        out[:forms]=[]
      end
      out
    end
    def self.format_schedule(item)
      value=item.details['schedule_info'].presence || item.details['class_time'].presence
      return '暂无排课信息' unless value
      item.teachers.blank? ? value : value.split(/\s*,\s*/).map(&:strip).reject(&:blank?).join("\n")
    end
    def self.course_details(item)
      labels={'category'=>'课程类别','credits'=>'学分','opening_department'=>'开课学院','teacher_departments'=>'教师院系','teacher_titles'=>'教师职称','grade'=>'年级','education_level'=>'培养层次','student_category'=>'学生类别','major'=>'专业','enrolled'=>'已选人数','capacity'=>'容量','schedule_info'=>'排课信息','weeks'=>'周次','period'=>'节次','weekly_hours'=>'周学时','total_hours'=>'总学时','classroom_type'=>'教室类型','class_time'=>'上课时间','location'=>'上课地点','assessment'=>'考核方式','exam_time'=>'考试时间','language'=>'授课语言','class_name'=>'教学班名称'}
      labels.filter_map { |key,label| value=key=='schedule_info' && item.details[key].present? ? format_schedule(item) : item.details[key]; {label:label,value:value} unless value.nil? || value=='' }
    end
    def self.mentor_detail(item)
      raw=JSON.parse(item.details['raw_json'].presence || '{}') rescue {}
      details=[{label:'学院',value:item.department},{label:'职称',value:item.details['title']}]
      {'specialTitle'=>'特称','degree'=>'学位','attribute'=>'属性','email'=>'邮箱'}.each { |key,label| details << {label:label,value:raw[key]} }
      biography=raw['biography'].presence || raw['academicExperience']
      areas=Array(raw['researchAreas']).map { |r| [r['major'],r['direction'],r['admissionCategory']].compact.join(' · ') }.join("\n")
      body=[item.details['research_direction'],biography,areas.presence && "招生方向\n#{areas}"].compact.reject(&:blank?).join("\n\n")
      url=item.details['profile_url'];external=url.to_s.match?(%r{\Ahttps?://}i) ? [{label:'学校官网介绍',url:url}] : []
      email=raw['email'].to_s.strip
      external << {label:'发邮件',url:"mailto:#{email}"} if email.match?(/\A[^@\s<>]+@[^@\s<>]+\z/)
      Ui.card('detail',item.name,body,type:'detail',subtitle:item.source_key,details:details.reject { |d| d[:value].blank? },external_links:external)
    end
    def self.comment_card(c,user,personal:false)
      parent=c.parent_id && Comment.find_by(id:c.parent_id,status:'visible')
      card=Ui.card("comment-#{c.id}",c.anonymous ? '匿名回复' : Shared.user_name(c.user_id),c.body,type:'comment',author_title:true,forum_user:c.anonymous ? nil : Shared.forum_user(c.user_id),created_at:c.created_at.iso8601,
        subtitle:parent ? "回复 #{parent.anonymous ? '匿名' : Shared.user_name(parent.user_id)}：#{parent.body.truncate(80)}" : nil)
      if personal
        card[:status]=STATUS[c.status];card[:hidden_reason]=c.hidden_reason
        card[:links]=[Ui.link('查看讨论',{'view'=>'review','id'=>c.target_id})]
        card[:actions]=[Ui.action('删除评论','delete_own',{'kind'=>'Comment','id'=>c.id}).merge(confirm:'确定删除这条评论？')]
      elsif c.status=='visible'
        card.merge!(Shared.interaction_ui(c,user).slice(:actions,:forms,:metrics))
        fields=[Ui.field('body','回复内容（至少 2 字）',nil,type:'textarea',required:true).merge(minlength:2,maxlength:500),Ui.field('anonymous','匿名回复',false,type:'checkbox')]
        card[:forms].unshift(Ui.form('回复这条评论','comment',fields,{'kind'=>'Review','id'=>c.target_id,'parent_id'=>c.id},button:'发布回复'))
      end
      card
    end
    def self.admin_state(out,user,query)
      part=%w[reviews comments reports catalog audits].include?(query['part']) ? query['part'] : 'reviews'
      out[:filters]=[Ui.field('q','搜索内容',query['q']),Ui.field('part','管理项目',part,type:'select',options:[['reviews','评价'],['comments','评论'],['reports','举报'],['catalog','目录维护'],['audits','处理记录']]),Ui.field('kind','评价类别',query['kind'].to_s,type:'select',options:[['','全部'],['Course','课程'],['Mentor','导师']]),Ui.field('status','状态',query['status'].to_s,type:'select',options:[['','全部'],['visible','公开'],['hidden','隐藏']])]
      out[:stats]=[{label:'公开课程评价',value:Review.where(subject_kind:'Course',status:'visible').count},{label:'公开导师评价',value:Review.where(subject_kind:'Mentor',status:'visible').count},{label:'隐藏评价',value:Review.where(status:'hidden').count},{label:'待处理举报',value:Report.where(handled_at:nil).count}]
      if %w[reviews comments].include?(part)
        scope=(part=='reviews' ? Review : Comment).where.not(status:'deleted')
        scope=scope.where(status:query['status']) if %w[visible hidden].include?(query['status'])
        if %w[Course Mentor].include?(query['kind'])
          scope=part=='reviews' ? scope.where(subject_kind:query['kind']) : scope.where(target_id:Review.where(subject_kind:query['kind']).select(:id))
        end
        scope=scope.where('body ILIKE ?',"%#{ActiveRecord::Base.sanitize_sql_like(query['q'])}%") if query['q'].present?
        offset=paginate(out,query,scope.count,40)
        out[:cards]=recent(scope).offset(offset).limit(40).map do |item|
          card=part=='reviews' ? review_card(item,user,interaction:false) : comment_card(item,user,personal:true)
          card[:status]=STATUS[item.status];card[:hidden_reason]=item.hidden_reason;card[:forms]=[Ui.moderate_form(item)];card[:actions]=[];card
        end
      elsif part=='reports'
        scope=Report.where(handled_at:nil);offset=paginate(out,query,scope.count,40)
        out[:cards]=recent(scope).offset(offset).limit(40).map do |report|
          item=targets[report.target_kind]&.find_by(id:report.target_id)
          Ui.card("report-#{report.id}",'待处理举报',item&.body || '内容已删除',type:'report',subtitle:report.reason,forms:item ? [Ui.moderate_form(item)] : [],actions:[Ui.action('标记已处理','resolve_report',{'id'=>report.id})])
        end
      elsif part=='catalog'
        out[:forms]=[Ui.form('新增或更新教学班','course',[Ui.field('class_no','课程序号',nil,required:true),Ui.field('code','课程代码',nil,required:true),Ui.field('title','课程名称',nil,required:true),Ui.field('teachers','教师（分号分隔）',nil,required:true),Ui.field('term','学期'),Ui.field('campus','校区'),Ui.field('department','院系')]),Ui.form('新增导师','mentor',[Ui.field('name','导师姓名',nil,required:true),Ui.field('department','院系'),Ui.field('research_direction','研究方向',nil,type:'textarea')])]
      else
        scope=Audit.all;offset=paginate(out,query,scope.count,40)
        out[:cards]=recent(scope).offset(offset).limit(40).map { |a| Ui.card("audit-#{a.id}","#{a.action} · #{a.target_kind} ##{a.target_id}",a.reason,created_at:a.created_at.iso8601) }
      end
    end
    def self.call(user,operation,data)
      Access.check!(user)
      raise Error,'当前为只读预览，暂不接受修改' if SiteSetting.courses_read_only
      interaction=Shared.interaction(user,operation,data);return interaction if interaction
      case operation
      when 'review'
        kind=data['kind'];raise Error,'无效评价对象' unless %w[Course Mentor].include?(kind)
        item=(kind=='Course' ? Course : Mentor).find(Shared.id(data['id']))
        labels=kind=='Course' ? COURSE_SCORES : MENTOR_SCORES
        scores=labels.keys.to_h do |key|
          value=Float(data[key]);raise Error,'评分应为 0.5 至 5，步进 0.5' unless value.finite? && value.between?(0.5,5) && (value*2)%1==0
          [key,value]
        end
        body=Shared.text(data['body'],2000);raise Error,'评价内容至少 10 个字' if body.length<10
        Shared.lock("review:#{kind}:#{item.id}:#{user.id}")
        review=Review.find_or_initialize_by(subject_kind:kind,subject_id:item.id,user_id:user.id)
        if review.persisted? && data['expected_version']!=review.updated_at.iso8601(6)
          raise Error,'这条评价已经更新，请刷新页面后再确认修改'
        end
        review.update!(scores:scores,body:body,advice:Shared.text(data['advice'],1000,required:false),term_taken:kind=='Course' ? Shared.text(data['term_taken'],100,required:false) : nil,take_again:kind=='Course' && data['take_again'].present? ? Shared.bool(data['take_again']) : nil,anonymous:Shared.bool(data['anonymous']))
        {query:{view:'review',id:review.id},message:'评价已保存'}
      when 'bookmark'
        c=Course.find(Shared.id(data['id']));Shared.lock("bookmark:#{user.id}:#{c.group_key}")
        scope=Bookmark.where(user_id:user.id,group_key:c.group_key);scope.exists? ? scope.delete_all : scope.create!;{}
      when 'remove_bookmark'
        Bookmark.where(id:Shared.id(data['id']),user_id:user.id).delete_all;{}
      when 'course'
        Access.check!(user,admin:true)
        c=Course.find_or_initialize_by(class_no:Shared.text(data['class_no'],100),term:Shared.text(data['term'],100,required:false))
        old_key=c.group_key
        c.update!(code:Shared.text(data['code'],100),title:Shared.text(data['title'],200),teachers:Shared.text(data['teachers'],500),campus:Shared.text(data['campus'],100,required:false),department:Shared.text(data['department'],200,required:false))
        if old_key.present? && old_key!=c.group_key && !Course.exists?(group_key:old_key)
          Bookmark.where(group_key:old_key).find_each do |b|
            Bookmark.exists?(user_id:b.user_id,group_key:c.group_key) ? b.destroy! : b.update!(group_key:c.group_key)
          end
        end
        Shared.audit(user,'course_saved',c,'管理员维护教学班');{}
      when 'mentor'
        Access.check!(user,admin:true)
        m=Mentor.create!(name:Shared.text(data['name'],100),department:Shared.text(data['department'],200,required:false),details:{research_direction:Shared.text(data['research_direction'],2000,required:false)})
        Shared.audit(user,'mentor_created',m,'管理员维护导师');{}
      else raise Error,'未知操作'
      end
    end
  end
end
