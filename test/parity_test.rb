# frozen_string_literal: true
abort 'Disposable course test database only' unless ENV['RIVER_DISPOSABLE']=='1' && GlobalSetting.db_name=='river_community_test'
require 'minitest/autorun'
require_relative '../lib/catalog_importer'
class CourseParityTest < Minitest::Test
  A=DiscourseCourseReview
  def setup
    tables=ActiveRecord::Base.connection.tables.grep(/\Ariver_courses_/)
    ActiveRecord::Base.connection.execute('TRUNCATE '+tables.map { |t| ActiveRecord::Base.connection.quote_table_name(t) }.join(',')+' RESTART IDENTITY CASCADE')
    @group=Group.find_or_create_by!(name:'course_test_members')
    @alice=user('course_alice');@bob=user('course_bob');@admin=user('course_admin',admin:true);@outsider=user('course_outsider')
    [@alice,@bob].each { |u| @group.add(u);u.reload }
    SiteSetting.courses_enabled=true;SiteSetting.courses_read_only=false;SiteSetting.courses_allowed_groups=@group.id.to_s
    @course=A::Course.create!(code:'CS101',class_no:'CS101.01',title:'数据结构',teachers:'李老师;王老师',term:'2026-2027-1',campus:'清水河校区',department:'计算机科学与工程学院',details:{teacher_departments:'计算机科学与工程学院,数学科学学院',teacher_titles:'教授,副教授',credits:3,location:'教学楼',capacity:100})
    @other=A::Course.create!(code:'CS101',class_no:'CS101.02',title:'数据结构',teachers:'王老师;李老师',term:'2025-2026-2',campus:'沙河校区',department:'计算机科学与工程学院')
    @mentor=A::Mentor.create!(name:'示例导师',department:'计算机科学与工程学院',source_key:'M101',details:{title:'教授',research_direction:'机器学习',profile_url:'https://example.edu/mentor',raw_json:{degree:'博士',biography:'导师简介',researchAreas:[{major:'计算机',direction:'人工智能',admissionCategory:'硕士'}]}.to_json})
  end
  def user(name,admin:false)
    User.find_by(username:name) || User.create!(username:name,email:"#{name}@example.invalid",password:SecureRandom.hex(32),active:true,approved:true,admin:admin)
  end
  def command(user,op,data={},key:SecureRandom.uuid,**extra)
    data=data.merge(extra).deep_stringify_keys
    A::Shared.command(user,op,data,key) { A::Service.call(user,op,data) }
  end
  def review(user=@alice,item=@course,**attrs)
    command(user,'review',{kind:item.is_a?(A::Course) ? 'Course' : 'Mentor',id:item.id,overall:4.5,course:4,teacher:5,difficulty:3,grading:4,guidance:4,communication:4,body:'这是至少十个字的真实测试评价内容。',anonymous:true}.merge(attrs))
    A::Review.find_by!(user_id:user.id,subject_id:item.id,subject_kind:item.is_a?(A::Course) ? 'Course' : 'Mentor')
  end
  def state(query={},as:@alice,**extra) = A::Service.state(as,query.merge(extra).deep_stringify_keys)
  def test_card_identity_and_study_metadata_preserve_anonymity
    r=review(term_taken:'2025-2026-2',take_again:'false')
    card=A::Service.review_card(r,@bob)
    assert_equal '匿名评价',card[:author_name]
    assert_nil card[:forum_user]
    refute_includes card.to_json,@alice.username
    assert_equal '2025-2026 学年第二学期',card[:study_term]
    assert_equal false,card[:take_again]
    assert_equal({'view'=>'course','id'=>@course.id},card[:subject_query])
    r.update!(anonymous:false)
    card=A::Service.review_card(r,@bob)
    assert_equal @alice.username,card[:author_name]
    assert_equal @alice.username,card[:forum_user][:username]
    assert_includes card[:subject_meta],@course.class_no
  end
  def test_default_home_popularity_is_not_import_order
    older=review;older.update_columns(created_at:2.days.ago)
    newer=review(@bob,@other);newer.update_columns(created_at:1.day.ago)
    # Imported IDs deliberately do not imply chronological order.
    oldest=review(@admin,@course);oldest.update_columns(created_at:3.days.ago)
    home=state
    assert_equal 'home',home[:view]
    popular=home[:sections].find { |s| s[:id]=='popular-courses' }
    assert_equal 1,popular[:cards].size
    assert_equal '近期 3 条评价',popular[:cards].first[:badge]
    assert_equal "review-#{newer.id}",home[:sections].find { |s| s[:id]=='recent-reviews' }[:cards].first[:id]
  end
  def test_filters_grouping_aliases_and_metadata
    assert_equal @course.group_key,@other.group_key
    assert_equal 1,state(view:'courses')[:pagination][:total]
    assert_equal 1,state(view:'courses',q:'计院')[:pagination][:total]
    assert_equal 1,state(view:'courses',q:'数结')[:pagination][:total]
    assert_equal 1,state(view:'courses',q:'CS101.01')[:pagination][:total]
    assert_equal 0,state(view:'courses',q:'不存在')[:pagination][:total]
    rows=state(view:'courses',campus:'沙河校区',school_year:'2025-2026',semester:'2')
    assert_equal 1,rows[:stats].find { |s| s[:label]=='教学班' }[:value]
    detail=state(view:'course',id:@course.id)
    assert_equal 2,detail[:sections].find { |s| s[:id]=='offerings' }[:cards].size
    assert_includes detail.to_json,'教学楼'
    assert_includes detail.to_json,'教师职称'
    assert_equal '5.0',A::Service.rating(5)
    assert_equal '4.3',A::Service.rating(4.25)
    assert_equal '4.3',A::Service.rating(4.35) # Match JavaScript toFixed for binary floats.
    assert_equal 'matching-teachers',state(view:'courses',q:'李老师')[:sections].first[:id]
  end
  def test_mentor_details_and_separate_scores
    r=review(@alice,@mentor)
    s=state(view:'mentor',id:@mentor.id)
    assert_includes s.to_json,'导师简介';assert_includes s.to_json,'人工智能'
    assert_equal %w[overall guidance communication].sort,r.scores.keys.sort
    assert_equal 1,state(view:'mentors',q:'机器学习')[:pagination][:total]
    refute s[:forms].first[:fields].any? { |f| f[:name]=='take_again' }
  end
  def test_review_validation_update_confirmation_and_stale_edit
    assert_raises(A::Error) { review(body:'短评') }
    assert_raises(A::Error) { review(overall:4.2) }
    r=review
    assert_raises(A::Error) { review(body:'另外一次没有确认的评价文本内容。') }
    form=state(view:'course',id:@course.id)[:forms].first
    assert form[:confirm]
    version=r.updated_at.iso8601(6)
    updated=review(expected_version:version,body:'这是确认更新后的第二条评价内容。')
    assert_equal r.id,updated.id
    assert_equal 1,A::Review.count
    assert_raises(A::Error) { review(expected_version:version) }
  end
  def test_delete_allows_new_review_and_detaches_child_comment
    r=review
    command(@bob,'comment',kind:'Review',id:r.id,body:'第一条评论',anonymous:true)
    parent=A::Comment.last
    command(@alice,'comment',kind:'Review',id:r.id,parent_id:parent.id,body:'回复这条评论')
    child=A::Comment.last
    command(@bob,'delete_own',kind:'Comment',id:parent.id)
    assert_nil child.reload.parent_id
    command(@alice,'delete_own',kind:'Review',id:r.id)
    assert_equal 0,A::Comment.count
    refute A::Review.exists?(r.id)
    refute_equal r.id,review.id
  end
  def test_hidden_review_remains_hidden_when_owner_edits
    r=review
    command(@admin,'moderate',kind:'Review',id:r.id,status:'hidden',reason:'需要核实')
    assert_equal '需要核实',r.reload.hidden_reason
    assert_raises(Discourse::InvalidAccess) { state({view:'review',id:r.id},as:@bob) }
    assert_includes state(view:'mine').to_json,'需要核实'
    review(expected_version:r.updated_at.iso8601(6),body:'隐藏以后本人修改的评价内容。')
    assert_equal 'hidden',r.reload.status
    assert_equal 0,state(view:'reviews')[:pagination][:total]
    command(@admin,'moderate',kind:'Review',id:r.id,status:'visible',reason:'核实完成')
    assert_nil r.reload.hidden_reason
  end
  def test_anonymous_reply_reactions_and_notification_paths
    r=review
    assert_raises(A::Error) { command(@bob,'comment',kind:'Review',id:r.id,body:'短') }
    command(@bob,'comment',kind:'Review',id:r.id,body:'这是匿名回复',anonymous:true)
    c=A::Comment.last
    command(@bob,'react',kind:'Review',id:r.id,value:1)
    command(@bob,'react',kind:'Review',id:r.id,value:-1)
    assert_equal 1,A::Reaction.count
    assert_equal(-1,A::Reaction.first.value)
    text=state({view:'review',id:r.id},as:@outsider) rescue nil
    assert_nil text
    text=state({view:'review',id:r.id},as:@admin).to_json
    refute_includes text,@alice.username;refute_includes text,@bob.username
    A::Event.find_each { |e| assert_equal "/courses?view=review&id=#{r.id}",e.path }
    command(@bob,'delete_own',kind:'Comment',id:c.id)
  end
  def test_report_admin_can_see_and_moderate_target
    r=review
    command(@bob,'report',kind:'Review',id:r.id,reason:'请核实内容')
    command(@bob,'report',kind:'Review',id:r.id,reason:'补充核实理由')
    assert_equal 1,A::Report.count
    assert_equal '补充核实理由',A::Report.first.reason
    cards=state({view:'admin',part:'reports'},as:@admin)[:cards]
    assert_equal r.body,cards.first[:body]
    assert_equal 'moderate',cards.first[:forms].first[:operation]
    assert_raises(Discourse::InvalidAccess) { command(@bob,'moderate',kind:'Review',id:r.id,status:'hidden',reason:'越权') }
    command(@admin,'moderate',kind:'Review',id:r.id,status:'hidden',reason:'核实中')
    assert_equal 0,A::Report.where(handled_at:nil).count
  end
  def test_mine_bookmarks_comments_and_pagination
    r=review
    command(@alice,'bookmark',id:@course.id)
    assert_equal 1,state(view:'mine',part:'bookmarks')[:cards].size
    command(@alice,'bookmark',id:@other.id)
    assert_equal 0,A::Bookmark.count
    command(@alice,'comment',kind:'Review',id:r.id,body:'我的评论内容')
    assert_equal 1,state(view:'mine',part:'comments')[:cards].size
    44.times { |i| A::Mentor.create!(name:"分页导师 #{i}") }
    page=state(view:'mentors',page:2)
    assert_equal 5,page[:cards].size;assert page[:previous];refute page[:next]
  end
  def test_readonly_guard_no_mutations_or_events
    r=review;before=A::Command.count
    SiteSetting.courses_read_only=true
    assert_raises(A::Error) { command(@alice,'bookmark',id:@course.id) }
    assert_equal before,A::Command.count
    detail=state(view:'course',id:@course.id)
    assert_empty detail[:forms]
    assert detail[:sections].flat_map { |s| s[:cards] }.all? { |c| c[:actions].empty? && c[:forms].empty? }
    A::Shared.notify(@alice.id,'只读模式事件',key:'readonly-test')
    A::Shared.deliver
    assert_nil A::Event.last.notification_id
  end
  def test_lifecycle_purges_import_archive_even_disabled
    r=review
    command(@bob,'comment',kind:'Review',id:r.id,body:'另一人的回复')
    A::Legacy.create!(source:'Review',legacy_id:'original',target_kind:'Review',target_id:r.id,data:{externalUserId:@alice.id.to_s,forumUsername:@alice.username})
    SiteSetting.courses_enabled=false
    DiscourseEvent.trigger(:user_anonymized,user:@alice)
    assert_equal 0,A::Review.count;assert_equal 0,A::Comment.count;assert_equal 0,A::Legacy.count
  end
  def test_merge_keeps_target_review_and_anonymizes_transferred_content
    source=review;target=review(@bob)
    command(@alice,'comment',kind:'Review',id:target.id,body:'待迁移的评论内容')
    DiscourseEvent.trigger(:merging_users,@alice,@bob)
    refute A::Review.exists?(source.id);assert A::Review.exists?(target.id)
    comment=A::Comment.first
    assert_equal @bob.id,comment.user_id;assert comment.anonymous
  end
  def test_legacy_links_and_export_are_owner_scoped
    assert_equal({view:'mine'},A::Service.legacy_query('me/'))
    r=review;review(@bob,@mentor)
    A::Legacy.create!(source:'Course',legacy_id:'legacy-course',target_kind:'Course',target_id:@course.id,data:{})
    assert_equal({view:'course',id:@course.id},A::Service.legacy_query('courses/legacy-course'))
    encoded=Base64.urlsafe_encode64({courseCode:@course.code,title:@course.title,teachers:'王老师;李老师'}.to_json,padding:false)
    assert_equal @course.id,A::Service.legacy_query("course-groups/#{encoded}")[:id]
    assert_nil A::Service.legacy_query('course-groups/invalid')
    exported=A::UserLifecycle.export(@alice.id)
    assert_equal [r.id],exported[:reviews].map { |x| x['id'] }
  end
  def test_catalog_refresh_preserves_reviews_and_requires_readonly
    r=review
    payload={'format'=>'riverside-course-catalog-v1','courses'=>[{'classNo'=>@course.class_no,'courseCode'=>@course.code,'title'=>@course.title,'teachers'=>@course.teachers,'term'=>@course.term,'campus'=>'更新校区','credits'=>4}], 'mentors'=>[{'sourceKey'=>@mentor.source_key,'name'=>@mentor.name,'department'=>'更新学院','title'=>'教授'}]}
    result=A::CatalogImporter.run(payload,actor:@admin)
    assert_equal 1,result[:courses_updated]
    assert_equal '清水河校区',@course.reload.campus
    assert_raises(A::Error) { A::CatalogImporter.run(payload,actor:@admin,apply:true) }
    assert_raises(Discourse::InvalidAccess) { A::CatalogImporter.run(payload,actor:@alice) }
    SiteSetting.courses_read_only=true
    A::CatalogImporter.run(payload,actor:@admin,apply:true)
    assert_equal '更新校区',@course.reload.campus
    assert_equal @course.id,r.reload.subject_id
    assert_equal '更新学院',@mentor.reload.department
    assert_equal 1,A::Audit.where(action:'catalog_import').count
  end
  def test_final_parity_empty_ratings_limits_terms_search_and_legacy_filters
    form=state(view:'course',id:@course.id)[:forms].first
    assert form[:fields].select { |f| f[:type]=='rating' }.all? { |f| f[:value]=='' }
    assert_equal '越高越难',form[:fields].find { |f| f[:name]=='difficulty' }[:hint]
    assert_equal "周一\n周二",A::Service.format_schedule(A::Course.new(teachers:'示例',details:{schedule_info:'周一, 周二'}))
    assert_equal 'select',form[:fields].find { |f| f[:name]=='term_taken' }[:type]
    assert_raises(A::Error) { review(overall:0) }
    r=review
    assert_raises(A::Error) { command(@bob,'comment',kind:'Review',id:r.id,body:'字'*501) }
    assert_raises(A::Error) { command(@bob,'report',kind:'Review',id:r.id,reason:'字'*241) }
    assert_equal 0,A::Report.count
    @course.update!(details:@course.details.merge(category:'通识选修',major:'计算机'))
    assert_operator A::Catalog.score(@course,'通识'),:>,0
    assert_equal 1000,A::Catalog.score(@course,'数据结构')
    assert_equal 1,state(view:'courses',q:'院计')[:pagination][:total]
    assert_equal({view:'mentors','q'=>'机器学习','college'=>'计算机学院','page'=>'2','school_year'=>'2025-2026'},A::Service.legacy_query('',{'tab'=>'mentors','q'=>'机器学习','college'=>'计算机学院','page'=>'2','schoolYear'=>'2025-2026'}))
    assert_equal({view:'home'},A::Service.legacy_query('',{'tab'=>'https://evil.invalid'}))
    A::Mentor.create!(name:'机器学习研究员',department:'其他学院',source_key:'M102')
    assert state(view:'mentors',q:'机器学习')[:cards].any? { |c| c[:title]=='机器学习研究员' }
  end
  def test_request_id_replay_and_cross_thread_reply
    r=review;other=review(@bob,@mentor)
    key=SecureRandom.uuid
    2.times { command(@bob,'comment',{kind:'Review',id:r.id,body:'同一个请求只创建一次'},key:key) }
    assert_equal 1,A::Comment.count
    assert_raises(A::Error) { command(@bob,'comment',kind:'Review',id:other.id,parent_id:A::Comment.first.id,body:'回复到错误的讨论') }
    assert_raises(A::Error) { command(@bob,'comment',{kind:'Review',id:r.id,body:'不同的内容不能复用编号'},key:key) }
  end
end
