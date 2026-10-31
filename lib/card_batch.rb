# frozen_string_literal: true
module DiscourseCourseReview
  # Request-local data: never cache identities or permissions between viewers.
  class CardBatch
    def initialize(reviews, user)
      @subjects = {}
      reviews.group_by(&:subject_kind).each do |kind, rows|
        model = kind == 'Course' ? Course : Mentor
        model.where(id: rows.map(&:subject_id)).each { |item| @subjects[[kind, item.id]] = item }
      end
      @authors = User.where(id: reviews.reject(&:anonymous).map(&:user_id)).index_by(&:id)
      ids = reviews.map(&:id)
      @comments = Comment.where(target_kind: 'Review', target_id: ids, status: 'visible').group(:target_id).count
      reactions = Reaction.where(target_kind: 'Review', target_id: ids)
      @counts = reactions.group(:target_id, :value).count
      @mine = user ? reactions.where(user_id: user.id).pluck(:target_id, :value).to_h : {}
    end

    def subject(review) = @subjects[[review.subject_kind, review.subject_id]]
    def author(review) = review.anonymous ? nil : @authors[review.user_id]
    def comments(review) = @comments.fetch(review.id, 0)
    def reactions(review)
      {likes: @counts.fetch([review.id, 1], 0), dislikes: @counts.fetch([review.id, -1], 0), reaction: @mine[review.id]}
    end
  end
end

module DiscourseCourseReview
  class CommentBatch < CardBatch
    def initialize(comments,user)
      @parents=Comment.where(id:comments.map(&:parent_id).compact,status:'visible').index_by(&:id)
      visible_authors=(comments+@parents.values).reject(&:anonymous).map(&:user_id)
      @authors=User.where(id:visible_authors).index_by(&:id)
      reactions=Reaction.where(target_kind:'Comment',target_id:comments.map(&:id))
      @counts=reactions.group(:target_id,:value).count
      @mine=user ? reactions.where(user_id:user.id).pluck(:target_id,:value).to_h : {}
    end
    def parent(comment) = @parents[comment.parent_id]
  end
end
