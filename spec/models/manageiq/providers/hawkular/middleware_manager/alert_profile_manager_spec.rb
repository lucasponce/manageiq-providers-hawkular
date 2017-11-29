describe ManageIQ::Providers::Hawkular::MiddlewareManager::AlertProfileManager do
  let(:client) { double('Hawkular::Alerts') }
  let(:stubbed_ems) do
    ems = instance_double('::ManageIQ::Providers::Hawkular::MiddlewareManager',
                          :alerts_client => client,
                          :id            => 5)
    allow(ems).to receive(:miq_id_prefix) { |id| id }
    ems
  end
  let(:subject) { described_class.new(stubbed_ems) }
  let(:server) do
    FactoryGirl.create(:hawkular_middleware_server, :name => 'Serv', :ems_ref => 'c00fee',
                       :feed => 'test.feed', :nativeid => 'nativeid')
  end
  let(:server2) do
    FactoryGirl.create(:hawkular_middleware_server, :name => 'Serv2', :ems_ref => 'c22fee',
                       :feed => 'feed', :nativeid => 'nativeid2')
  end
  let(:alert_id) { 2 }
  let(:group_trigger) do
    double('group_trigger', :id => 'MiQ-2', :name => 'Gtrig',
           :conditions => [
             double('condition', :data_id => 'group_data_id', :expression => '$TS(Test Metric) > 10')
           ])
  end
  let(:server2_member_trigger) { double(:id => "MiQ-2-#{server2.id}") }
  let(:expected_context_for_member_trigger) do
    {
      '$TS(Test Metric)' => 'test_metric{feed_id="test.feed"}',
      'resource_path' => 'c00fee'
    }
  end
  let!(:hawkular_alert) do
    FactoryGirl.create(:miq_alert_middleware, :id => 2)
  end

  context '#process_alert_profile' do
    it ':update_assignments' do
      # Assume alert 2 is added to profile 50, and it was already in profile 49.
      allow(client).to receive(:get_single_trigger).with('alert-2', true).and_return(group_trigger)
      allow(client).to receive(:list_triggers).with(['alert-2']).and_return([group_trigger])
      allow(group_trigger).to receive(:context).and_return('miq.alert_profiles' => '49')
      allow(group_trigger).to receive(:context=).with('miq.alert_profiles' => '49,50')
      expect(client).to receive(:update_group_trigger).with(group_trigger)

      # Assume it was already assigned to Serv2, and now it's added to Serv.
      allow(client).to receive(:list_members).with(group_trigger.id).and_return([server2_member_trigger])
      expect(subject).to receive(:create_new_member).with(group_trigger, server.id)

      subject.process_alert_profile(:update_assignments,
                                    :id => 50, :old_alerts_ids => [alert_id],
                                    :old_assignments_ids => [server2.id],
                                    :new_assignments_ids => [server.id, server2.id])
    end
  end

  it '#create_new_member' do
    allow(server).to receive(:ems_ref).and_return('c00fee')
    allow(server).to receive(:metrics_available).and_return([{'displayName' => 'Test Metric', 'expression' => 'test_metric{feed_id="test.feed"}'}])
    expect(client).to receive(:create_member_trigger).with(
      an_object_having_attributes(
        :group_id       => 'MiQ-2',
        :member_id      => "MiQ-2-#{server.id}",
        :member_name    => 'Gtrig for Serv',
        :member_context => expected_context_for_member_trigger
      )
    )

    subject.create_new_member_from_resource(group_trigger, server)
  end

  it 'calculate_member_context' do
    allow(server).to receive(:ems_ref).and_return('c00fee')
    allow(server).to receive(:metrics_available).and_return([{'displayName' => 'Test Metric', 'expression' => 'test_metric{feed_id="test.feed"}'}])
    expect(subject.calculate_member_context(server, group_trigger.conditions[0].expression)).to eq(expected_context_for_member_trigger)
  end
end
