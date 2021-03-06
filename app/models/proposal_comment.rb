class ProposalComment < ApplicationRecord
  include ActionView::Helpers::TextHelper

  has_paper_trail versions: { class_name: 'ProposalCommentVersion' }, only: [:content], on: %i[update destroy]

  belongs_to :user, class_name: 'User', inverse_of: :proposal_comments, foreign_key: :user_id
  belongs_to :contribute, class_name: 'ProposalComment', inverse_of: :replies, foreign_key: :parent_proposal_comment_id, optional: true
  has_many :replies, class_name: 'ProposalComment', inverse_of: :contribute, foreign_key: :parent_proposal_comment_id, dependent: :destroy
  has_many :repliers, -> { distinct }, class_name: 'User', through: :replies, inverse_of: :proposal_comments, source: :user
  belongs_to :proposal, class_name: 'Proposal', foreign_key: :proposal_id, counter_cache: true, inverse_of: :proposal_comments
  has_many :rankings, class_name: 'ProposalCommentRanking', dependent: :destroy, inverse_of: :proposal_comment
  has_many :rankers, through: :rankings, class_name: 'User', source: :user
  belongs_to :paragraph, optional: true, inverse_of: :proposal_comments

  has_one :integrated_contribute, class_name: 'IntegratedContribute', inverse_of: :proposal_comment, dependent: :destroy
  has_many :proposal_revisions, class_name: 'ProposalRevision', through: :integrated_contributes

  has_many :reports, class_name: 'ProposalCommentReport', foreign_key: :proposal_comment_id

  validates :content, length: { minimum: 10, maximum: CONTRIBUTE_MAX_LENGTH }

  attr_accessor :collapsed, :nickname_generated

  after_initialize :set_collapsed

  validate :check_last_comment

  scope :contributes, -> { where(parent_proposal_comment_id: nil) }
  scope :comments, -> { where.not(parent_proposal_comment_id: nil) }

  scope :unintegrated, -> { where(integrated: false) }
  scope :integrated, -> { where(integrated: true) }

  scope :noise, -> { where(noise: true) }

  scope :listable, -> { where(integrated: false, noise: false) }

  scope :unread, lambda { |user_id, proposal_id|
    where('proposal_comments.id not in (select p2.id
                                        from proposal_comments p2
                                        join proposal_comment_rankings pr on p2.id = pr.proposal_comment_id
                                        where pr.user_id = ? and p2.proposal_id = ?)',
          user_id, proposal_id)
  }

  scope :removable, -> { noisy.where(noise: false) }

  # a contribute marked more than three times as spam
  scope :spam, -> { where('grave_reports_count >= ?', CONTRIBUTE_MARKS) }

  # a contribute marked more than three times as noisy
  scope :noisy, -> { where('soft_reports_count >= ?', CONTRIBUTE_MARKS) }

  attr_accessor :section_id

  before_create :set_paragraph_id

  after_create :generate_nickname

  after_create :increment_contributes_counter_cache, if: :is_contribute?
  after_destroy :decrement_contributes_counter_cache, if: :is_contribute?

  after_commit :send_email, on: :create
  after_commit :send_update_notifications, on: :update

  def is_contribute?
    parent_proposal_comment_id.nil?
  end

  def set_paragraph_id
    self.paragraph = Paragraph.where(section_id: section_id).first
  end

  def set_collapsed
    @collapsed = false
  end

  def check_last_comment
    comments = proposal.proposal_comments.where(user_id: user_id).order('created_at DESC')
    comment = comments.first
    errors.add(:created_at, "devono passare almeno trenta secondi tra un commento e l'altro.") if LIMIT_COMMENTS && comment && ((Time.zone.now - comment.created_at) < 30.seconds)
  end

  # Used to set more tracking for akismet
  def request=(request)
    self.user_ip = request.remote_ip
    self.user_agent = request.env['HTTP_USER_AGENT']
    self.referrer = truncate(request.env['HTTP_REFERER'], length: 255)
  end

  # retrieve all the participants to this discussion
  def participants
    repliers | [user]
  end

  def has_location?
    !paragraph.nil?
  end

  def location
    ret = nil
    if paragraph
      section = paragraph.section
      ret = section.title.to_s
      ret = "#{section.solution.title_with_seq} > #{ret}" if section.solution
    end
    ret
  end

  def send_email
    NotificationProposalCommentCreate.perform_async(id)
  end

  def send_update_notifications
    NotificationProposalCommentUpdate.perform_async(id) if previous_changes.include?(:content) && previous_changes[:content].first != previous_changes[:content].last
  end

  def generate_nickname
    proposal_nickname = ProposalNickname.generate(user, proposal)
    self.nickname_generated = proposal_nickname.generated
  end

  # unintegrate the comment if it was integrated somewhere
  def unintegrate
    integrated_contribute.destroy
    update(integrated: false)
  end

  private

  def decrement_contributes_counter_cache
    add_to_contributes_counter(-1)
  end

  def increment_contributes_counter_cache
    add_to_contributes_counter(1)
  end

  def add_to_contributes_counter(num)
    proposal.update_columns(proposal_contributes_count: proposal.proposal_contributes_count + num)
  end
end
