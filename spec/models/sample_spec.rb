require 'rails_helper'

RSpec.describe Sample, type: :model do
  describe "update model" do
    before :each do
      @user = create(:user)
      @client = create(:client)
    end

    it "should not allow the state to transition to an invalid state" do
      Sample.with_user(@user) do
        @sample = create(:sample, state: Sample.states[:requested])
        @sample.state = Sample.states[:prepared]
        expect { @sample.save! }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    it "should create a valid retest" do
      Sample.with_user(@user) do
        @sample = create(:sample, state: Sample.states[:tested])
        uid = @sample.uid
        @retest = @sample.create_retest(Rerun::INCONCLUSIVE)
        expect(@sample.state).to eq "retest"
        expect(@retest.state).to eq "received"
        expect(@sample.retest).to eq @retest
        expect(@retest.persisted?).to eq true
        expect(@sample.uid).to eq @retest.uid
        expect(@retest.uid).to eq uid
        expect(@sample.client).to eq @retest.client
        expect(@sample.is_retest).to eq false
        expect(@retest.is_retest).to eq true
      end
    end

    it "should not let a sample have more than one retest" do
      Sample.with_user(@user) do
        @sample = create(:sample, state: Sample.states[:tested])
        @retest = @sample.create_retest(Rerun::INCONCLUSIVE)
        @sample.reload
        expect { @sample.create_retest(Rerun::INCONCLUSIVE) }.to raise_error "Retest already exists"
      end
    end

    it "should not let a retest be retested" do
      Sample.with_user(@user) do
        @sample = create(:sample, state: Sample.states[:tested])
        @retest = @sample.create_retest(Rerun::INCONCLUSIVE)
        expect { @retest.create_retest(Rerun::INCONCLUSIVE) }.to raise_error "Sample is a rerun"
      end
    end

    it "should create a rerun with the correct directional associations" do
      Sample.with_user(@user) do
        @sample_s = create(:sample, state: Sample.states[:tested])
        @retest = @sample_s.create_retest(Rerun::INCONCLUSIVE)
        @sample_s.reload
        expect(@retest).to_not be nil
        expect(@sample_s.retest).to eq @retest
        expect(@sample_s.retest?).to eq true
        expect(@retest.source_sample).to eq @sample_s
        expect(@sample_s.rerun.reason).to eq Rerun::INCONCLUSIVE
      end
    end

    [[false,true], [true,false]].each do |a, b|
      it "should allow the same UID if the retest flag is different" do
        Sample.with_user(@user) do
          @sample_a = create(:sample, state: Sample.states[:tested], uid: 'abc', is_retest: a)
          @sample_b_attribs = build(:sample, state: Sample.states[:tested], uid: 'abc', is_retest: b).attributes
          expect { Sample.create!(@sample_b_attribs) }.to_not raise_error
        end
      end
    end

    [false, true].each do |b|
      it "should not allow the same UID if the retest flag is the same" do
        Sample.with_user(@user) do
          @sample_a = create(:sample, state: Sample.states[:tested], uid: 'abc', is_retest: b)
          @sample_b_attribs = build(:sample, state: Sample.states[:tested], uid: 'abc', is_retest: b).attributes
          expect { Sample.create!(@sample_b_attribs) }.to raise_error ActiveRecord::RecordInvalid
        end
      end
    end

    it "should create a record with the initial state of received" do
      Sample.with_user(@user) do
        @sample = Sample.new(client: @client, state: Sample.states[:received])
        expect { @sample.save! }.to_not raise_error
        expect(@sample.state).to eq :received.to_s
        expect(@sample.records.size).to eq 1
        expect(@sample.records.last.state).to eq Sample.states[:received]
      end
    end

    it "should  allow the state to transition from commfailed to commcomplete" do
      Sample.with_user(@user) do
        @sample = create(:sample, state: Sample.states[:commfailed])
        @sample.state = Sample.states[:commcomplete]
        expect { @sample.save! }.to_not raise_error
      end
    end

    it "should allow the state to transition from communicated to commfailed" do
      Sample.with_user(@user) do
        @sample = create(:sample, state: Sample.states[:communicated])
        @sample.state = Sample.states[:commfailed]
        expect { @sample.save! }.to_not raise_error
      end
    end

    it "should preferentially select a user which is set on the instance rather than the class" do
      @other_user = create(:user)
      Sample.with_user(@user) do
        @sample = create(:sample, state: Sample.states[:communicated])
        @sample.with_user(@other_user) do |s|
          s.state = Sample.states[:commfailed]
          expect { s.save! }.to_not raise_error
          expect(s.records.last.user).to eq @other_user
        end
        expect(@sample.records.last.user).to eq @other_user
      end
    end

    it "should not require a class user to be set if an instance user is supplied" do
      @other_user = create(:user)
      Sample.with_user(@user) do
        @sample = create(:sample, state: Sample.states[:communicated])
      end
      Sample.with_user(nil) do
        @sample.with_user(@other_user) do |s|
          s.state = Sample.states[:commfailed]
          expect { s.save! }.to_not raise_error
        end
      end
      expect(@sample.records.last.user).to eq @other_user
    end

    it "should be invalid if no user has been set" do
      @other_user = create(:user)
      Sample.with_user(@user) do
        @sample = create(:sample, state: Sample.states[:communicated])
      end
      Sample.with_user(nil) do
        @sample.state = Sample.states[:commfailed]
        expect { @sample.save! }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    Sample.states.each do |key, value|
      it "should allow any state to transition from #{key} to rejected" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: value)
          @sample.state = Sample.states[:rejected]
          expect { @sample.save! }.to_not raise_error
        end
      end
    end

    it "should enqueue a rejection job on rejection" do
      Rails.application.config.send_test_results = true
      Sample.with_user(@user) do
        @sample = create(:sample)
        expect { @sample.rejected! }.to have_enqueued_job(RejectionJob)
      end
    end

    it "should not enqueue a rejection job on rejection if sending disabled" do
      Rails.application.config.send_test_results = false
      Sample.with_user(@user) do
        @sample = create(:sample)
        expect { @sample.rejected! }.to_not have_enqueued_job(RejectionJob)
      end
    end

    [:commcomplete, :commfailed].each do |state|
      it "should allow a rejected sample to transition to communication states" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :rejected)
          @sample.state = Sample.states[state]
          expect { @sample.save! }.to_not raise_error
        end
      end
    end

    Sample.states.to_a[0, (Sample.states.size-1)].each do |key, value|
      it "should allow a state to transition from #{key} to the next state" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: value)
          @sample.state = value +1
          expect { @sample.save! }.to_not raise_error
        end
      end
    end

    describe "stats" do
      it "should generate valid stats when samples are created straight at commcomplete stage" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :commcomplete, client: @client)
          @stats = Sample.stats_for(@client)
          expect(@stats.first.communicated).to eq 1
          expect(@stats.first.requested).to eq 0
          expect(@stats.first.retests).to eq 0
          expect(@stats.first.rejects).to eq 0
          expect(@stats.first.internalchecks).to eq 0
          expect(@stats.size).to eq 1
        end
      end

      it "should record the request and communication of a sample" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :received, client: @client)
          r = @sample.records.first
          r.note = 'Created from API'
          r.save!
          @sample.preparing!
          @sample.prepared!
          @sample.prepared!
          @sample.tested!
          @sample.analysed!
          @sample.communicated!
          @sample.commcomplete!
          @stats = Sample.stats_for(@client)
          expect(@stats.first.communicated).to eq 1
          expect(@stats.first.requested).to eq 1
          expect(@stats.first.retests).to eq 0
          expect(@stats.first.rejects).to eq 0
          expect(@stats.first.internalchecks).to eq 0
          expect(@stats.size).to eq 1
        end
      end

      it "should record the request and rejection of a sample" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :received, client: @client)
          r = @sample.records.first
          r.note = 'Created from API'
          r.save!
          @sample.preparing!
          @sample.rejected!
          @stats = Sample.stats_for(@client)
          expect(@stats.first.communicated).to eq 0
          expect(@stats.first.requested).to eq 1
          expect(@stats.first.retests).to eq 0
          expect(@stats.first.rejects).to eq 1
          expect(@stats.first.internalchecks).to eq 0
          expect(@stats.size).to eq 1
        end
      end

      it "should record the request and rerun of a sample" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :received, client: @client)
          r = @sample.records.first
          r.note = 'Created from API'
          r.save!
          @sample.preparing!
          @sample.retest!
          @stats = Sample.stats_for(@client)
          expect(@stats.first.communicated).to eq 0
          expect(@stats.first.requested).to eq 1
          expect(@stats.first.retests).to eq 1
          expect(@stats.first.rejects).to eq 0
          expect(@stats.first.internalchecks).to eq 0
          expect(@stats.size).to eq 1
        end
      end

      it "should not record samples that are not created from the API" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :received, client: @client)
          r = @sample.records.first
          r.note = 'Not Created from API'
          r.save!
          @stats = Sample.stats_for(@client)
          expect(@stats.first.communicated).to eq 0
          expect(@stats.first.requested).to eq 0
          expect(@stats.first.retests).to eq 0
          expect(@stats.first.rejects).to eq 0
          expect(@stats.first.internalchecks).to eq 0
          expect(@stats.size).to eq 1
        end
      end

      it "should record the communication of a retest" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :received, client: @client)
          r = @sample.records.first
          r.note = 'Created from API'
          r.save!
          @sample.preparing!
          @retest = @sample.create_retest(Rerun::POSITIVE)
          @rerun = @retest
          @rerun.preparing!
          @rerun.prepared!
          @rerun.prepared!
          @rerun.tested!
          @rerun.analysed!
          @rerun.communicated!
          @rerun.commcomplete!
          @stats = Sample.stats_for(@client)
          expect(@stats.first.communicated).to eq 1
          expect(@stats.first.requested).to eq 1
          expect(@stats.first.retests).to eq 1
          expect(@stats.first.rejects).to eq 0
          expect(@stats.first.internalchecks).to eq 0
          expect(@stats.size).to eq 1
        end
      end
    end

    describe "posthoc retests" do
      it "should create a retest of a valid communicated sample" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :received, client: @client)
          @sample.preparing!
          @sample.preparing!
          @sample.prepared!
          @sample.tested!
          @sample.analysed!
          @sample.communicated!
          @sample.commcomplete!

          @retest = @sample.create_posthoc_retest(Rerun::POSITIVE)
        end
        expect(@retest.uid).to eq @sample.uid
        expect(@retest.state).to eq "received"
        expect(@sample.state).to eq "retest"
        expect(@retest.source_sample).to eq @sample
        expect(@retest.rerun_for.source_sample).to eq @sample
      end

      it "should count a posthoc retest as a communicated sample, however the retest count should differentiate communicating and noncommunicating retests" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :received, client: @client)
          r = @sample.records.first
          r.note = 'Created from API'
          r.save!
          @sample.preparing!
          @sample.prepared!
          @sample.prepared!
          @sample.tested!
          @sample.analysed!
          @sample.communicated!
          @sample.commcomplete!
          @p_retest = @sample.create_posthoc_retest(Rerun::POSITIVE)
          @p_retest.preparing!
          @p_retest.prepared!
          @p_retest.prepared!
          @p_retest.tested!
          @p_retest.analysed!
          @p_retest.communicated!
          @p_retest.commcomplete!
          @stats = Sample.stats_for(@client)
          expect(@stats.first.communicated).to eq 1
          expect(@stats.first.requested).to eq 1
          expect(@stats.first.retests).to eq 0
          expect(@stats.first.internalchecks).to eq 1
          expect(@stats.first.rejects).to eq 0
          expect(@stats.size).to eq 1
        end
      end

      it "should count a posthoc retest as a communicated sample, however the retest count should differentiate communicating and noncommunicating retests with an internal retest too" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :received, client: @client)
          r = @sample.records.first
          r.note = 'Created from API'
          r.save!
          @sample.preparing!
          @sample.prepared!
          @sample.prepared!
          @sample.tested!
          @sample.analysed!
          @sample.communicated!
          @sample.commcomplete!
          @p_retest = @sample.create_posthoc_retest(Rerun::POSITIVE)

          @sample_2 = create(:sample, state: :received, client: @client)
          r = @sample_2.records.first
          r.note = 'Created from API'
          r.save!
          @sample_2.preparing!
          @sample_2.prepared!
          @sample_2.prepared!
          @sample_2.tested!
          @p_2_retest = @sample_2.create_retest(Rerun::POSITIVE)

          @stats = Sample.stats_for(@client)

          expect(@stats.first.communicated).to eq 1
          expect(@stats.first.requested).to eq 2
          expect(@stats.first.retests).to eq 1
          expect(@stats.first.internalchecks).to eq 1
          expect(@stats.first.rejects).to eq 0
          expect(@stats.size).to eq 1
        end
      end

      it "should not create a rerun of a sample that has not been communicated already" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :received, client: @client)
          @rerun = @sample.create_retest(Rerun::POSITIVE)
          expect { @rerun.create_posthoc_retest(Rerun::POSITIVE) }.to raise_error "Sample is a rerun"
        end
      end

      it "should not allow an internal rerun of a rerun" do
        Sample.with_user(@user) do
          @sample = create(:sample, state: :received, client: @client)
          expect {@sample.create_posthoc_retest(Rerun::POSITIVE)}.to raise_error "Sample cannot be retested unless communicated"
        end
      end
    end

    describe "validations" do
      it "should not allow duplicate ID" do
        new_sample = Sample.create(client: @client, uid: "abc")
        other_sample = Sample.new(client: @client, uid: "abc")
        expect(other_sample.save).to be false
      end

      it "should create a new UID if one is not provided" do
        new_sample = Sample.create(client: @client)
        other_sample = Sample.create(client: @client)
        expect(other_sample.uid).to_not eq new_sample.uid
      end

      it "should validate that the sample can only be one well on the same plate" do
        # this is hacky because we don't validate the changes to be added on the wells, rather make an assocation on the plate. This is brittle and relies on the awful method in the controller
        plate = build(:plate, wells: 96.times.map { |t| build(:well) })
        plate.save
        @sample = nil
        Sample.with_user(@user) do
          @sample = create(:sample)
        end
        func = lambda {
          Plate.transaction do
            @sample.plate = plate
            plate.samples << @sample
            plate.wells.first.sample = @sample
            plate.wells.second.sample = @sample
            plate.save!
          end
        }

        expect { func.call }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end
end
