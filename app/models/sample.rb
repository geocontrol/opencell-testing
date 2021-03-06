require 'ostruct'
class Sample < ApplicationRecord
  extend BarcodeModule

  barcode_for :uid
  belongs_to :client
  has_many :records, dependent: :destroy
  has_one :well, dependent: :nullify
  has_one :rerun, class_name: "Rerun", foreign_key: :sample_id
  has_one :rerun_for, class_name: "Rerun", foreign_key: :retest_id
  has_one :source_sample, through: :rerun_for, class_name: "Sample"
  has_one :retest, through: :rerun, class_name: "Sample", foreign_key: :retest
  belongs_to :plate, optional: true
  validate :unique_well_in_plate?, on: :update, if: :well_id_changed?
  validate :check_valid_transition?, on: :update, if: :state_changed?
  validates_uniqueness_of :uid, scope: :is_retest
  has_one :test_result, through: :well

  before_create :set_uid, unless: :uid?
  before_create :set_creation_record
  before_update :set_change_record, if: :state_changed?

  enum state: { requested: 0, dispatched: 1, received: 2, preparing: 3, prepared: 4, tested: 5, analysed: 6, communicated: 7, commcomplete: 8, commfailed: 9, rejected: 10, retest: 11  }

  scope :is_requested, -> { where(state: Sample.states[:requested]) }
  scope :is_dispatched, -> { where(state: Sample.states[:dispatched]) }
  scope :is_received, -> { where(state: Sample.states[:received]) }
  scope :is_preparing, -> { where(state: Sample.states[:preparing]) }
  scope :is_prepared, -> { where(state: Sample.states[:prepared]) }
  scope :is_tested, -> { where(state: Sample.states[:tested]) }
  scope :is_analysed, -> { where(state: Sample.states[:analysed]) }
  scope :is_communicated, -> { where(state: Sample.states[:communicated]) }

  after_update :send_notification_after_analysis, if: :communicated?
  after_update :send_rejection, if: :rejected?

  CONTROL_CODE = 1234

  def self.block_user
    @with_user
  end

  def self.with_user(user, &block)
    @with_user = user
    begin
      yield block
    ensure
      @with_user = nil
    end
  end

  def with_user(user, &block)
    @with_user = user
    begin
      yield(self) if block_given?
    ensure
      @with_user = nil
    end
  end

  def rerun_for?
    rerun_for.present?
  end

  def create_retest(reason)
    raise "Retest already exists".freeze if rerun.present?
    raise "Sample is a rerun".freeze if is_retest

    self.transaction do
      attribs = attributes.merge!(state: Sample.states[:received], is_retest: true).except!("id")
      update(state: Sample.states[:retest])
      Rerun.create(source_sample: self, retest_attributes: attribs, reason: reason)
      save!
    end
    retest
  end

  def create_posthoc_retest(reason)
    # what conditions can we not create a retest?
    # sample should be commcomplete already, should the client be selected here.. the client is a retest client and the reason determines why.. 
    raise "Retest already exists".freeze if rerun.present?
    raise "Sample is a rerun".freeze if is_retest
    raise "Sample cannot be retested unless communicated" unless commcomplete?

    retest_client = Client.find_by(name: Client::INTERNAL_RERUN_NAME)

    if(retest_client.nil?)
      retest_client = Client.create!(name: Client::INTERNAL_RERUN_NAME, api_key: SecureRandom.base64(16), notify: false)
    end

    self.transaction do
      attribs = attributes.merge!(state: Sample.states[:received], is_retest: true, client_id: retest_client.id).except!("id")
      update(state: Sample.states[:retest])
      r = Rerun.create(source_sample: self, retest_attributes: attribs, reason: reason)
      save!
    end
    retest
  end

  def self.tested_last_week
    samples = Sample
        .select('date(samples.created_at) as created_date, count(samples.id) as count')
        .where('samples.state >= ? and samples.created_at >= ?', Sample.states[:tested], 7.days.ago.beginning_of_day)
        .group("date(samples.created_at)")
        .order('created_date DESC')
    unless samples.any?
      return self.dummy
    end
    samples
  end

  def self.total_tests
    where('samples.state >= ?', Sample.states[:analysed]).count
  end

  def self.requested_last_week
    # all samples that were created in the last week
    samples = Sample
        .select("date(samples.created_at) as created_date, count(samples.id) as count")
        .where('samples.created_at >= ?', 7.days.ago.beginning_of_day)
        .group("date(samples.created_at)")
        .order('created_date DESC')
    unless samples.any?
      return self.dummy
    end
    samples
  end

  def self.failure_rate_last_week
    samples = Sample
        .select("date(samples.created_at) as created_date, cast(count(CASE WHEN samples.state = #{Sample.states[:rejected]} THEN 1 END) as decimal) / count(*) as count")
        .where('samples.created_at >= ?', 7.days.ago.beginning_of_day)
        .group("date(samples.created_at)")
        .order('created_date DESC')
    unless samples.any?
      return self.dummy
    end
    samples
  end

  def self.stats_for(client)
    received = Sample.states[:received]
    commcomplete = Sample.states[:commcomplete]
    retest = Sample.states[:retest]
    reject = Sample.states[:rejected]

    query = <<-SQL
      select
      foo.date,
      count(case when foo.states @> ARRAY[#{received}] and foo.notes @> array['Created from API']::varchar[] then 1 else null end) as requested,
      count(case when foo.states @> ARRAY[#{commcomplete}] and not foo.states @> ARRAY[#{reject}] then 1 else null end) as communicated,
      count(case when foo.states @> ARRAY[#{reject}] then 1 else null end) as rejects,
      count(case when foo.states @> ARRAY[#{retest}] and not foo.states @> ARRAY[#{[reject]}] and not foo.states @> ARRAY[#{[commcomplete]}] then 1 else null end) as retests,
      count(case when foo.states @> ARRAY[#{retest}] and not foo.states @> ARRAY[#{reject}] and foo.states @> ARRAY[#{[commcomplete, retest].join(',')}] then 1 else null end) as internalchecks
      from (
        select date(r.updated_at) as date, r.sample_id as sample_id, array_agg(r.state) as states, array_agg(r.note) as notes
        from public.records r
        inner join public.samples s on sample_id = s.id
        where s.client_id = #{client.id}
        and r.state in(#{[received, commcomplete, retest, reject].join(',')})
        and s.control = false
        group by date(r.updated_at), r.sample_id ) as foo
      group by foo.date
      order by foo.date desc
    SQL

    results = ActiveRecord::Base.connection.execute(query)
    results.map { |r| OpenStruct.new(r) }.map { |i| Stat.new(i) }
  end

  private

  def unique_well_in_plate?
    return if plate.nil? or !well_id_changed?

    matched = plate.samples.find_by(id: id)
    return unless matched

    errors.add(:well, 'Sample exists in another well on this plate')
  end

  def self.dummy
    [{ count: 0 }, { count: 0 }]
  end

  def send_notification_after_analysis
    ResultNotifyJob.perform_later(self, Sample.block_user) if ( self.saved_change_to_state? && self.communicated? && Rails.application.config.send_test_results)
  end

  def send_rejection
    RejectionJob.perform_later(self, @with_user) if ( self.saved_change_to_state? && Rails.application.config.send_test_results)
  end

  def set_uid
    self.uid = SecureRandom.base64(14)
  end

  def check_valid_transition?
    valid =  valid_transition? state_was
    return if valid

    errors.add(:sample, "Cannot transition from #{state_was.to_s} to #{state.to_s}")
  end

  def valid_transition? previous_state
    return true if Sample.states.to_hash[state] == Sample.states[:rejected] || Sample.states.to_hash[state] == Sample.states[:retest]
    return true if Sample.states.to_hash[state] == Sample.states[:commfailed] && Sample.states[previous_state] == Sample.states[:communicated]
    return true if Sample.states.to_hash[state] == Sample.states[:commcomplete] && Sample.states[previous_state] == Sample.states[:commfailed]
    return true if Sample.states.to_hash[state] == Sample.states[:commcomplete] && Sample.states[previous_state] == Sample.states[:rejected]
    return true if Sample.states.to_hash[state] == Sample.states[:commfailed] && Sample.states[previous_state] == Sample.states[:rejected]

    state_value = Sample.states[previous_state]
    (Sample.states[state] - state_value) == 1
  end

  def set_creation_record
    record_user = @with_user || Sample.block_user
    records << Record.new(user: record_user, note: "Sample Created from LIMS", state: Sample.states[state])
  end

  def set_change_record
    record_user = @with_user || Sample.block_user
    records << Record.new(user: record_user, note: nil, state: Sample.states[state])
  end
  class Stat
    attr_reader :requested, :communicated, :retests, :rejects, :date, :internalchecks
    def initialize(args)
      @requested = args.requested
      @communicated = args.communicated
      @retests = args.retests
      @rejects = args.rejects
      @internalchecks = args.internalchecks
      @date = args.date
    end
  end
end
