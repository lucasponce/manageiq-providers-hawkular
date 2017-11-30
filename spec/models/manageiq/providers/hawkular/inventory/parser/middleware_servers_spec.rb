require_relative '../../middleware_manager/hawkular_helper'

describe ManageIQ::Providers::Hawkular::Inventory::Parser::MiddlewareServers do
  let(:ems_hawkular) { ems_hawkular_fixture }
  let(:poss_resource) do
    Hawkular::Inventory::Resource.new(
      'id'     => 'os1',
      'feedId' => 'feed1',
      'type'   => { 'id' => 'Platform_Operating System' },
      'config' => {
        'Container Id' => 'uuid_cont1',
        'Machine Id'   => nil
      }
    )
  end
  let(:agent_resource) do
    Hawkular::Inventory::Resource.new(
      'id'     => 'javaagent1',
      'feedId' => 'feed1',
      'type'   => { 'id' => 'Hawkular WildFly Agent' },
      'config' => {
        'Immutable'    => 'false',
        'In Container' => 'true'
      }
    )
  end
  let(:eap_properties_hash) do
    {
      'Suspend State'  => 'RUNNING',
      'Bound Address'  => '127.0.0.1',
      'Running Mode'   => 'NORMAL',
      'Home Directory' => '/opt/jboss/wildfly',
      'Version'        => '11.0.0.Final',
      'Node Name'      => 'server1',
      'Server State'   => 'running',
      'Product Name'   => 'WildFly Full',
      'Hostname'       => 'standalone',
      'UUID'           => 'uuid_server1',
      'Name'           => 'Server Number One'
    }
  end
  let(:eap_resource) do
    Hawkular::Inventory::Resource.new(
      'id'         => 'server1',
      'name'       => 'Server Number One',
      'feedId'     => 'feed1',
      'type'       => { 'id'         => 'WildFly Server',
                        'properties' => {} },
      'metrics'    => [{ 'name'       => 'Server Availability',
                         'type'       => 'Server Availability',
                         'properties' => {
                           'hawkular-services.monitoring-type' => 'remote',
                           'hawkular.metric.typeId'            => 'Server Availability~Server Availability',
                           'hawkular.metric.type'              => 'AVAILABILITY',
                           'hawkular.metric.id'                => 'server1_avail_metric'
                         }}],
      'properties' => {},
      'config'     => eap_properties_hash
    )
  end
  let(:metric_data) { OpenStruct.new(:id => 'server1_avail_metric', :data => [{'timestamp' => 1, 'value' => 'arbitrary value'}]) }
  let(:collector) do
    ManageIQ::Providers::Hawkular::Inventory::Collector::MiddlewareManager
      .new(ems_hawkular, ems_hawkular)
      .tap do |collector|
        allow(collector).to receive(:oss).and_return([poss_resource])
        allow(collector).to receive(:agents).and_return([agent_resource])
        allow(collector).to receive(:eaps).and_return([eap_resource])
        allow(collector).to receive(:raw_availability_data)
          .with(%w(server1_avail_metric), hash_including(:order => 'DESC'))
          .and_return([metric_data])
      end
  end
  let(:persister) do
    ManageIQ::Providers::Hawkular::Inventory::Persister::MiddlewareManager
      .new(ems_hawkular, ems_hawkular)
  end
  subject(:parser) do
    described_class.new.tap do |parser|
      parser.collector = collector
      parser.persister = persister
    end
  end

  def parsed_server
    persister.middleware_servers.data.first
  end

  delegate :data, :to => :parsed_server, :prefix => true

  it 'parses a basic server' do
    parser.parse
    expect(persister.middleware_servers.size).to eq(1)
    expect(parsed_server_data).to include(
      :name      => 'Server Number One',
      :nativeid  => 'server1',
      :ems_ref   => 'server1',
      :feed      => 'feed1',
      :hostname  => 'standalone',
      :product   => 'WildFly Full',
      :type_path => 'WildFly Server'
    )
    expect(parsed_server.properties).to include(eap_properties_hash)
    expect(parsed_server.properties).to include('In Container' => 'true')
    expect(parsed_server.properties).to_not include('Immutable')
  end

  it 'assigns status reported by inventory to a server with "up" metric' do
    metric_data.data.first['value'] = 'up'

    parser.parse
    expect(parsed_server.properties['Availability']).to eq('up')
    expect(parsed_server.properties['Calculated Server State']).to eq(parsed_server.properties['Server State'])
  end

  it 'assigns status reported by metric to a server when its availability metric is something else than "up"' do
    parser.parse
    expect(parsed_server.properties['Availability']).to eq('arbitrary value')
    expect(parsed_server.properties['Calculated Server State']).to eq('arbitrary value')
  end

  it 'assigns unknown status to a server with a missing metric' do
    allow(collector).to receive(:raw_availability_data)
      .with(%w(server1_avail_metric), hash_including(:order => 'DESC'))
      .and_return([])

    parser.parse
    expect(parsed_server.properties['Availability']).to eq('unknown')
    expect(parsed_server.properties['Calculated Server State']).to eq('unknown')
  end

  it 'associates the underlying container' do
    container = FactoryGirl.create(:container, :backing_ref => 'docker://uuid_cont1', :type => 'Container')

    parser.parse
    expect(parsed_server.lives_on_id).to eq(container.id)
    expect(parsed_server.lives_on_type).to eq('Container')
  end

  it 'associates no container if Agent does not provide Container Id' do
    poss_resource.config.delete('Container Id')

    parser.parse
    expect(parsed_server.lives_on_id).to be_blank
    expect(parsed_server.lives_on_type).to be_blank
  end

  describe 'VM resolution' do
    let!(:vm) { FactoryGirl.create(:vm_redhat, :uid_ems => 'abcdef12-3456-7890-abcd-ef1234567890') }

    before do
      agent_resource.config.delete('In Container')
    end

    def try_and_test_vm_association
      parser.parse
      expect(parsed_server.lives_on_id).to eq(vm.id)
      expect(parsed_server.lives_on_type).to eq(vm.type)
    end

    it 'associates no underlying machine if VM is not in MiQ inventory' do
      poss_resource.config['Machine Id'] = '0000xyz'

      parser.parse
      expect(parsed_server.lives_on_id).to be_blank
      expect(parsed_server.lives_on_type).to be_blank
    end

    it 'associates no underlying machine if Agent does not provide Machine Id' do
      poss_resource.config.delete('Machine Id')

      parser.parse
      expect(parsed_server.lives_on_id).to be_blank
      expect(parsed_server.lives_on_type).to be_blank
    end

    it 'associates VM with matching UID regardless of UID format' do
      poss_resource.config['Machine Id'] = 'uid'
      vm.uid_ems = 'uid'
      vm.save

      try_and_test_vm_association
    end

    it 'associates VM even if agent reports a GUID without dashes' do
      poss_resource.config['Machine Id'] = 'abcdef1234567890abcdef1234567890'
      try_and_test_vm_association
    end

    it 'associates VM even if agent reports a GUID without dashes and the underlying machine has a bugged kernel' do
      poss_resource.config['Machine Id'] = '12efcdab56349078abcdef1234567890'
      try_and_test_vm_association
    end
  end
end
