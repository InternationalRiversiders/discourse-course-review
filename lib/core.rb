# frozen_string_literal: true
require "digest"
require "tempfile"
require "vips"
module DiscourseCourseReview
  class Error < StandardError; end
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end
  %w[Command Event Audit Legacy Media Reaction Report Comment].each do |name|
    klass = Class.new(Record)
    klass.table_name = "river_courses_#{name.underscore.pluralize}"
    klass.table_name = "river_courses_media" if name == "Media"
    const_set(name, klass)
  end
  module Access
    def self.admin?(user)
      user && user.active? && !user.suspended? && (user.admin? || user.in_any_groups?(SiteSetting.courses_admin_groups.split("|").map(&:to_i)))
    end
    def self.member?(user)
      user && user.active? && !user.suspended? && (admin?(user) || user.in_any_groups?(SiteSetting.courses_allowed_groups.split("|").map(&:to_i)))
    end
    def self.check!(user, admin: false)
      raise Discourse::InvalidAccess unless SiteSetting.courses_enabled && (admin ? admin?(user) : member?(user))
    end
  end
  module Shared
    def self.text(value, max = 4000, required: true)
      text = value.to_s.strip
      raise Error, "请填写必填内容" if required && text.empty?
      raise Error, "内容超过 #{max} 字限制" if text.length > max
      text
    end
    def self.id(value)
      number = Integer(value.to_s, 10) rescue nil
      raise Error, "无效的编号" unless number && number > 0
      number
    end
    def self.bool(value) = value == true || value.to_s == "true" || value.to_s == "1"
    def self.lock(key)
      number = Digest::SHA256.digest("river_courses:#{key}").unpack1("q>")
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{number})")
    end
    def self.command(user, operation, data, key)
      Access.check!(user)
      raise Error, "请求编号缺失" unless key.to_s.match?(/\A[\w-]{8,100}\z/)
      fingerprint = Digest::SHA256.hexdigest([operation, data.to_h.deep_sort.to_json].join(":")) if data.respond_to?(:deep_sort)
      fingerprint ||= Digest::SHA256.hexdigest([operation, canonical(data)].to_json)
      Record.transaction do
        lock("user:#{user.id}")
        lock("command:#{user.id}:#{key}")
        existing = Command.find_by(user_id: user.id, key: key)
        if existing
          raise Error, "请求编号已用于其他操作" unless existing.fingerprint == fingerprint
          next existing.result
        end
        result = yield || {}
        Command.create!(user_id: user.id, key: key, fingerprint: fingerprint, result: result)
        result
      end
    end
    def self.canonical(value)
      case value
      when Hash then value.keys.map(&:to_s).sort.to_h { |key| [key, canonical(value[key])] }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end
    def self.audit(actor, action, item, reason, details = {})
      Audit.create!(user_id: actor.id, action: action, target_kind: item.class.name.demodulize, target_id: item.id, reason: text(reason, 500), details: details)
    end
    def self.notify(user_id, text, path = "/courses", key:)
      return unless user_id && User.exists?(user_id)
      Event.create_or_find_by!(key: key) { |e| e.user_id = user_id; e.text = text; e.path = path }
    end
    def self.deliver
      return unless SiteSetting.courses_enabled && !SiteSetting.courses_read_only
      Event.where(notification_id: nil).order(:id).limit(100).each do |event|
        event.with_lock do
          next if event.notification_id
          next unless User.exists?(event.user_id)
          n = Notification.create!(user_id: event.user_id, notification_type: Notification.types[:custom], skip_send_email: true,
            data: { river_app: "courses", river_text: event.text, river_path: event.path, river_icon: "graduation-cap", message: "courses", display_username: "", topic_title: event.text }.to_json)
          event.update!(notification_id: n.id)
        end
      rescue => e
        Rails.logger.warn("courses notification #{event.id}: #{e.class}")
      end
    end
    def self.user_name(id) = User.find_by(id: id)&.username || "已注销用户"
    def self.image(bytes)
      signature = bytes.byteslice(0,12)
      valid = signature&.start_with?("\xFF\xD8\xFF".b, "\x89PNG\r\n\x1A\n".b, "GIF87a".b, "GIF89a".b) || (signature&.start_with?("RIFF") && signature.byteslice(8,4)=="WEBP")
      raise Error, "只支持 JPEG、PNG、GIF 或 WebP 图片" unless valid
      image=Vips::Image.new_from_buffer(bytes,"",access: :sequential)
      raise Error,"图片尺寸过大" if image.width*image.height>30_000_000
      image=image.autorot
      ratio=[1200.0/image.width,1200.0/image.height,1].min
      image=image.resize(ratio) if ratio<1
      image=image.flatten(background: [255,255,255]) if image.has_alpha?
      image.jpegsave_buffer(Q:78,strip:true)
    end
    def self.media_ids(user, values)
      ids = Array(values).map { |v| id(v) }.uniq
      raise Error, "最多上传 6 张图片" if ids.size > 6
      raise Error, "图片不属于你或已不存在" unless Media.where(id: ids, user_id: user.id).count == ids.size
      ids
    end
    def self.media_urls(ids) = Array(ids).map { |id| "/courses/media/#{id}" }
    def self.reactions(item, user)
      scope = Reaction.where(target_kind: item.class.name.demodulize, target_id: item.id)
      { likes: scope.where(value: 1).count, dislikes: scope.where(value: -1).count, reaction: user && scope.find_by(user_id: user.id)&.value }
    end
    def self.react(user, item, value)
      raise Error, "内容不可用" if item.respond_to?(:status) && item.status != "visible"
      value = Integer(value.to_s, 10) rescue nil
      raise Error, "无效的反馈" unless [-1,0,1].include?(value)
      lock("reaction:#{item.class.name}:#{item.id}:#{user.id}")
      scope = Reaction.where(target_kind: item.class.name.demodulize, target_id: item.id, user_id: user.id)
      value.to_i == 0 ? scope.delete_all : scope.first_or_initialize.update!(value: value.to_i)
      if value.to_i == 1 && item.respond_to?(:user_id) && item.user_id && item.user_id != user.id
        notify(item.user_id, "你的内容收到新的赞", content_path(item), key: "like:#{item.class.name}:#{item.id}:#{user.id}")
      end
      {}
    end
    def self.report(user, item, reason)
      report=Report.find_or_initialize_by(user_id: user.id, target_kind: item.class.name.demodulize, target_id: item.id)
      report.update!(reason:text(reason,240))
      {}
    end
    def self.comments(kind, id, user)
      Comment.where(target_kind: kind, target_id: id, status: "visible").order(:id).limit(300).map do |c|
        { id: c.id, parent_id: c.parent_id, body: c.body, author: c.anonymous ? "匿名" : user_name(c.user_id), mine: user&.id == c.user_id, created_at: c.created_at, images: media_urls(c.media_ids), rating: c.rating }.merge(reactions(c,user))
      end
    end
    def self.comment(user, item, data)
      raise Error, "内容不可用" if item.respond_to?(:status) && item.status != "visible"
      kind = item.class.name.demodulize
      parent = data["parent_id"].present? ? Comment.find(id(data["parent_id"])) : nil
      raise Error, "回复不属于当前内容" if parent && (parent.target_kind != kind || parent.target_id != item.id || parent.status != "visible")
      c = Comment.create!(user_id: user.id, target_kind: kind, target_id: item.id, parent_id: parent&.id, body: comment_body(data["body"]), anonymous: bool(data["anonymous"]), media_ids: [], rating: nil)
      recipients = [parent&.user_id, item.respond_to?(:user_id) ? item.user_id : nil].compact.uniq - [user.id]
      recipients.each { |uid| notify(uid, "你的内容有新的回复", content_path(item), key: "comment:#{c.id}:#{uid}") }
      { id: c.id }
    end
    def self.admin_state(user)
      Access.check!(user, admin: true)
      { reports: Report.where(handled_at: nil).order(id: :desc).limit(100).as_json(only: %i[id target_kind target_id reason created_at]),
        audits: Audit.order(id: :desc).limit(50).as_json(only: %i[id user_id action target_kind target_id reason created_at]),
        pending_notifications: Event.where(notification_id: nil).count }
    end
  end
  class MainController < ::ApplicationController
    requires_plugin "discourse-course-review"
    skip_before_action :check_xhr, only: [:index, :export, :legacy]
    before_action :enabled!
    rescue_from Error, ArgumentError do |error|
      render_json_dump({ errors: [error.message] }, status: 422)
    end
    def index
      Access.check!(current_user)
      render "default/empty"
    end
    def state
      Access.check!(current_user)
      response.headers["Cache-Control"] = "no-store"
      render_json_dump(Service.state(current_user, params.to_unsafe_h))
    end
    def mutate
      Access.check!(current_user)
      raise Error, "当前为只读预览，暂不接受修改" if SiteSetting.courses_read_only
      RateLimiter.new(current_user, "courses-write", 40, 1.minute).performed!
      data = params.fetch(:data, ActionController::Parameters.new).permit!.to_h
      result = Shared.command(current_user, params.require(:operation).to_s, data, params.require(:request_id)) do
        Service.call(current_user, params[:operation].to_s, data)
      end
      Shared.deliver
      render_json_dump(result)
    end
    def export
      Access.check!(current_user)
      response.headers["Cache-Control"] = "private, no-store"
      send_data(JSON.pretty_generate(UserLifecycle.export(current_user.id)), type:"application/json", disposition:"attachment", filename:"my-course-reviews.json")
    end
    def legacy
      Access.check!(current_user)
      path=params[:path].to_s
      query=Service.legacy_query(path,params.to_unsafe_h)
      raise Discourse::NotFound unless query
      redirect_to("/courses?#{query.to_query}")
    end
    private
    def enabled!
      raise Discourse::NotFound unless SiteSetting.courses_enabled
    end
  end
end
module ::Jobs
  class DiscourseCourseReviewTick < ::Jobs::Scheduled
    every 1.minute
    def execute(args)
      return unless SiteSetting.courses_enabled
      DistributedMutex.synchronize("courses-tick") do
        DiscourseCourseReview::Service.tick if DiscourseCourseReview::Service.respond_to?(:tick)
        DiscourseCourseReview::Shared.deliver
      end
    end
  end
end

module DiscourseCourseReview

  module Ui
    def self.field(name, label, value = nil, type: "text", options: nil, required: false)
      { name: name, label: label, value: value, type: type, options: options&.map { |v| v.is_a?(Array) ? { value: v[0], label: v[1] } : { value: v, label: v } }, required: required }
    end
    def self.form(title, operation, fields, data = {}, button: "保存", danger: false)
      { key: [operation, title, data.to_json].join(":"), title: title, operation: operation, fields: fields, data: data, button: button, danger: danger }
    end
    def self.card(id, title, body = nil, **rest)
      { id: id.to_s, title: title, body: body }.merge(rest)
    end
    def self.action(label, operation, data = {}) = { label: label, operation: operation, data: data }
    def self.link(label, query) = { label: label, query: query }
    def self.shell(user, query, tabs, **rest)
      { title: "选课指南", intro: "来自同学的经验，让每一次选择更有把握。", view: query["view"].presence || tabs.first[0], member: Access.member?(user), admin: Access.admin?(user),
        tabs: tabs.map { |id,label| { id: id, label: label } }, cards: [], forms: [], stats: [], filters: [], **rest }
    end
    def self.moderate_form(item)
      form("内容管理", "moderate", [field("status","处理方式","hidden",type:"select",options:[["hidden","隐藏"],["visible","恢复"],["deleted","删除"]]),field("reason","处理理由",nil,required:true)], { "kind"=>item.class.name.demodulize,"id"=>item.id },button:"确认处理")
    end
    def self.admin_cards(user)
      state = Shared.admin_state(user)
      state[:reports].map do |r|
        card("report-#{r['id']}","待处理举报",r['reason'],subtitle:"#{r['target_kind']} ##{r['target_id']}",
          actions:[action("标记已处理","resolve_report",{"id"=>r['id']})])
      end + state[:audits].map { |a| card("audit-#{a['id']}","#{a['action']} · #{a['target_kind']} ##{a['target_id']}",a['reason'],subtitle:a['created_at']) }
    end
  end

end

module DiscourseCourseReview
  module Shared
    def self.interaction(user, operation, data)
      case operation
      when 'react','report','comment','delete_own','moderate'
        klass=Service.targets[data['kind']]
        raise Error,'无效内容类型' unless klass
        item=klass.lock.find(id(data['id']))
        if operation=='moderate'
          Access.check!(user,admin:true)
          status=data['status'];raise Error,'无效状态' unless %w[visible hidden deleted].include?(status)
          audit(user,status,item,data['reason'])
          if status=='deleted'
            parent_query=item.is_a?(Review) ? {view:'admin'} : {view:'review',id:item.target_id}
            remove_content(item)
            return {query:parent_query}
          end
          item.update!(status:status,hidden_reason:status=='hidden' ? text(data['reason'],500) : nil)
          Report.where(target_kind:item.class.name.demodulize,target_id:item.id,handled_at:nil).update_all(handled_at:Time.current)
          notify(item.user_id,'你的内容有新的管理处理，请查看详情',content_path(item),key:"moderate:#{item.class.name}:#{item.id}:#{item.updated_at.to_f}") if item.user_id
          return {}
        end
        Service.visible_target!(item,user) unless operation == 'delete_own' && item.user_id == user.id
        case operation
        when 'react' then react(user,item,data['value'])
        when 'report' then report(user,item,data['reason'])
        when 'comment' then comment(user,item,data)
        when 'delete_own'
          raise Discourse::InvalidAccess unless item.user_id==user.id
          query=item.is_a?(Review) ? {view:'mine'} : {view:'review',id:item.target_id}
          remove_content(item);{query:query}
        end
      when 'resolve_report'
        Access.check!(user,admin:true)
        r=Report.find(id(data['id']));r.update!(handled_at:Time.current)
        audit(user,'resolve_report',r,'举报已处理')
        notify(r.user_id,'你的举报已处理',key:"report-resolved:#{r.id}")
        {}
      else nil
      end
    end
    def self.interaction_ui(item,user,comments: false,anonymous: false,images: false)
      data={'kind'=>item.class.name.demodulize,'id'=>item.id}
      reaction=reactions(item,user)
      actions=[];forms=[]
      if Access.member?(user)
        actions=[Ui.action("赞 #{reaction[:likes]}",'react',data.merge('value'=>reaction[:reaction]==1 ? 0 : 1)),Ui.action("踩 #{reaction[:dislikes]}",'react',data.merge('value'=>reaction[:reaction]==-1 ? 0 : -1))]
        if comments
          fields=[Ui.field('body','写下回复（至少 2 字）',nil,type:'textarea',required:true).merge(minlength:2,maxlength:500)]
          fields<<Ui.field('anonymous','匿名回复',false,type:'checkbox') if anonymous
          fields<<Ui.field('images','上传图片',nil,type:'upload') if images
          forms<<Ui.form('参与讨论','comment',fields,data,button:'发布回复')
        end
        forms<<Ui.form('举报','report',[Ui.field('reason','举报理由',nil,required:true).merge(maxlength:240)],data,button:'提交举报')
        actions<<Ui.action('删除我的内容','delete_own',data).merge(confirm:'删除后无法恢复，确定继续？') if item.respond_to?(:user_id) && item.user_id==user.id
        forms<<Ui.moderate_form(item) if Access.admin?(user)
      end
      {actions:actions,forms:forms,metrics:[{label:'赞',value:reaction[:likes]},{label:'踩',value:reaction[:dislikes]}]}
    end
    def self.comment_cards(item,user,anonymous:false,images:false)
      kind=item.class.name.demodulize
      Comment.where(target_kind:kind,target_id:item.id,status:'visible').order(:id).limit(300).map do |c|
        ui=interaction_ui(c,user)
        if Access.member?(user)
          fields=[Ui.field('body','回复内容',nil,type:'textarea',required:true)]
          fields<<Ui.field('anonymous','匿名回复',false,type:'checkbox') if anonymous
          ui[:forms].unshift(Ui.form(nil,'comment',fields,{'kind'=>kind,'id'=>item.id,'parent_id'=>c.id},button:'回复'))
        end
        Ui.card("comment-#{c.id}",c.anonymous ? '匿名' : user_name(c.user_id),c.body,subtitle:"#{c.parent_id ? "回复 ##{c.parent_id} · " : ''}#{c.created_at.strftime('%Y-%m-%d %H:%M')}",images:media_urls(c.media_ids),**ui)
      end
    end
  end

end
