class CheckGroups
  include ProposalsHelper
  include Rails.application.routes.url_helpers
  include Sidekiq::Worker
  sidekiq_options queue: :low_priority

  def perform(*_args)
    Group.joins(:participants).
      where(status: 'active').
      where(['groups.created_at < ?', 7.days.ago]).
      group('groups.id').
      having('count(users.*) < 2').readonly(false).each do |group|
      ResqueMailer.few_users_a(group.id).deliver_later
      group.update_attribute(:status, Group::STATUS_FEW_USERS_A)
      group.update_attribute(:status_changed_at, Time.zone.now)
    end
  end
end
