# frozen_string_literal: true
module DiscourseCourseReview
  %w[Course Mentor Review Bookmark].each do |name|
    klass = Class.new(Record)
    klass.table_name = "river_courses_#{name.underscore.pluralize}"
    const_set(name, klass)
  end
  class Course
    before_validation do
      self.group_key = Service.group_key(self)
    end
  end

  module Catalog
    ALIASES = {'计院'=>%w[计算机科学与工程学院 计算机], '信通'=>%w[信息与通信工程学院 通信], '经管'=>%w[经济与管理学院 管理], '数院'=>%w[数学科学学院 数学], '物院'=>%w[物理学院 物理], '电工'=>%w[电子科学与工程学院 电子], '自动化'=>['自动化工程学院'], '光电'=>['光电科学与工程学院'], '外国语'=>['外国语学院'], '马院'=>['马克思主义学院']}.freeze
    def self.normalize(value)
      value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[\s,，;；\/／\\|｜·・\-—_()（）\[\]【】{}《》<>:：.。"'“”‘’]+/, '')
    end
    def self.terms(query)
      ([normalize(query)] + query.to_s.split(/\s+/).map { |s| normalize(s) } + ALIASES.fetch(normalize(query), [])).reject(&:blank?).uniq
    end
    def self.search(scope, query, fields)
      return scope if query.blank?
      text = "concat_ws(' ', #{fields.join(', ')})"
      conditions = ["#{text} ILIKE :whole", "word_similarity(:query, #{text}) > 0.22"]
      bind = {whole: "%#{ActiveRecord::Base.sanitize_sql_like(query)}%", query: query}
      pieces=terms(query)
      if pieces.any?
        conditions << '(' + pieces.each_with_index.map { |p,i| bind["word#{i}".to_sym]="%#{ActiveRecord::Base.sanitize_sql_like(p)}%"; "#{text} ILIKE :word#{i}" }.join(' AND ') + ')'
      end
      chars=normalize(query).chars.select { |c| c.match?(/[\u3400-\u9fff]/) }
      if chars.size.between?(2,8)
        conditions << '(' + chars.uniq.each_with_index.map { |char,i| bind["char#{i}".to_sym]="%#{char}%"; "#{text} ILIKE :char#{i}" }.join(' AND ') + ')'
      end
      similarities=scope.klass==Mentor ? {'name'=>0.18,'department'=>0.18} : {'title'=>0.18,'teachers'=>0.18,'code'=>0.3,'class_no'=>0.3}
      similarities.each { |field,threshold| conditions << "similarity(#{field}, :query) > #{threshold}" }
      scope.where(conditions.join(' OR '), **bind)
    end
    def self.mentor_order(scope,query)
      return scope.order(:department,:source_key,:id) if query.blank?
      q=ActiveRecord::Base.connection.quote(query)
      text="concat_ws(' ',name,department,details->>'title',details->>'research_direction')"
      scope.order(Arel.sql("GREATEST(similarity(name,#{q}),similarity(department,#{q}),word_similarity(#{q},#{text})) DESC"),:department,:source_key,:id)
    end
    def self.course_scope(query)
      scope=Course.all
      scope=scope.where(campus:query['campus']) if query['campus'].present?
      scope=scope.where(term:query['term']) if query['term'].present?
      if query['school_year'].present?
        term=query['school_year'].to_s
        scope=query['semester'].present? ? scope.where(term:"#{term}-#{query['semester']}") : scope.where('term LIKE ?',"#{ActiveRecord::Base.sanitize_sql_like(term)}-%")
      elsif %w[1 2].include?(query['semester'])
        scope=scope.where('term LIKE ?',"%-#{query['semester']}")
      end
      if query['college'].present?
        scope=scope.where("department = :college OR details->>'teacher_departments' ILIKE :pattern",college:query['college'],pattern:"%#{ActiveRecord::Base.sanitize_sql_like(query['college'])}%")
      end
      search(scope,query['q'].to_s.strip,["title","code","class_no","teachers","department","details->>'teacher_departments'","details->>'category'","details->>'major'"])
    end
    def self.listing(scope=Course.all)
      scope.select(:id,:class_no,:code,:title,:teachers,:term,:campus,:department,:group_key,
        Arel.sql("jsonb_build_object('teacher_departments',details->'teacher_departments','teacher_titles',details->'teacher_titles','credits',details->'credits','category',details->'category','major',details->'major') AS details"))
    end
    def self.score(course,query)
      q=normalize(query);return 1 if q.blank?
      [[course.title,1000,860,760],[course.code,720,680,620],[course.class_no,700,660,610],[course.teachers,650,610,560],[course.details['teacher_departments'],460,420,380],[course.department,430,390,350],[course.details['category'],320,290,260],[course.details['major'],90,80,70]].sum do |value,exact,prefix,contains|
        v=normalize(value)
        if v.blank? then 0
        elsif v==q then exact
        elsif v.start_with?(q) then prefix
        elsif v.include?(q) then contains
        elsif terms(q).size>1 && terms(q).all? { |t| v.include?(t) } then (contains*0.86).round
        elsif q.size>=2 && v.match?(Regexp.new(q.chars.map { |c| Regexp.escape(c) }.join('.*'))) then (contains*0.56).round
        else 0
        end
      end
    end
    # Match the old browser's zh-CN alphabetical tie-breaks instead of Unicode order.
    def self.chinese_order(rows)
      return rows if rows.empty?
      collation = ActiveRecord::Base.connection.select_value("SELECT collname FROM pg_collation WHERE collname='zh-x-icu'")
      return rows.sort_by { |row| yield(row).to_s } unless collation
      names=rows.map { |row| yield(row).to_s }.to_json
      sql="SELECT ordinality FROM jsonb_array_elements_text(#{ActiveRecord::Base.connection.quote(names)}::jsonb) WITH ORDINALITY ORDER BY value COLLATE \"zh-x-icu\", ordinality"
      ActiveRecord::Base.connection.select_values(sql).map { |position| rows[position.to_i-1] }
    end
    def self.groups(query)
      groups=listing(course_scope(query)).order(term: :desc,class_no: :asc).to_a.group_by(&:group_key).values
      chinese_order(groups) { |rows| rows.first.title }.each_with_index.sort_by { |rows,index| [-rows.map { |r| score(r,query['q']) }.max,index] }.map(&:first)
    end
    def self.filter(name,label,value,values)
      Ui.field(name,label,value.to_s,type:'select',options:[['','全部']]+values.compact.reject(&:blank?).uniq.map { |s| [s,s] })
    end
    def self.filters(query,mentor:false)
      fields=[Ui.field('q',mentor ? '导师、研究方向或学院' : '课程、教师、课程序号或关键词',query['q'])]
      departments=(mentor ? Mentor : Course).where.not(department:nil).distinct.order(:department).pluck(:department)
      fields << filter('college','学院',query['college'],departments)
      unless mentor
        campuses=Course.distinct.pluck(:campus).compact
        preferred=['清水河校区','沙河校区','海南国际教育创新区']
        fields << filter('campus','校区',query['campus'],preferred.select { |s| campuses.include?(s) }+(campuses-preferred).sort)
        years=Course.distinct.pluck(:term).filter_map { |s| s.to_s[/\A\d{4}-\d{4}/] }.uniq.sort.reverse
        fields << filter('school_year','学年',query['school_year'],years)
        fields << Ui.field('semester','学期',query['semester'].to_s,type:'select',options:[['','全部'],['1','第一学期'],['2','第二学期']])
      end
      fields
    end
  end
end
