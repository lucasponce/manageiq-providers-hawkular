require_relative '../../middleware_manager/hawkular_helper'

describe ManageIQ::Providers::Hawkular::Inventory::Parser::MiddlewareDomains do
  let(:ems_hawkular) { ems_hawkular_fixture }
  let(:metric_data) { OpenStruct.new(:id => 'host_master_avail', :data => [{'timestamp' => 1, 'value' => 'arbitrary value'}]) }
  let(:controller_with_tree) do
    Hawkular::Inventory::Resource.new(
      'id'       => 'hc1',
      'feedId'   => 'feed1',
      'name'     => 'Local DMR',
      'type'     => {'id' => 'Host Controller'},
      'config'   => {
        'Version'         => '11.0.0.Final',
        'Local Host Name' => 'master',
        'Product Name'    => 'WildFly Full',
        'Process Type'    => 'Domain Controller'
      },
      'children' => [
        {
          'id'       => 'host_master',
          'feedId'   => 'feed1',
          'name'     => 'master',
          'type'     => {'id' => 'Domain Host'},
          'config'   => {
            'Suspend State'        => nil,
            'Running Mode'         => 'NORMAL',
            'Version'              => '11.0.0.Final',
            'Server State'         => nil,
            'Product Name'         => 'WildFly Full',
            'Host State'           => 'running',
            'Is Domain Controller' => 'true',
            'UUID'                 => 'uuid1',
            'Name'                 => 'master'
          },
          'metrics'  => [
            {
              'name'       => 'Domain Availability',
              'type'       => 'Domain Availability',
              'properties' => {
                'hawkular-services.monitoring-type' => 'remote',
                'hawkular.metric.typeId'            => 'Domain Availability~Domain Availability',
                'hawkular.metric.type'              => 'AVAILABILITY',
                'hawkular.metric.id'                => 'host_master_avail'
              }
            }
          ],
          'children' => []
        }
      ]
    )
  end
  let(:collector) do
    ManageIQ::Providers::Hawkular::Inventory::Collector::MiddlewareManager
      .new(ems_hawkular, ems_hawkular)
      .tap do |collector|
        allow(collector).to receive(:host_controllers).and_return([controller_with_tree])
        allow(collector).to receive(:resource_tree).with('hc1').and_return(controller_with_tree)
        allow(collector).to receive(:domains).and_return([controller_with_tree.children.first])
        allow(collector).to receive(:raw_availability_data)
          .with(%w(host_master_avail), hash_including(:order => 'DESC'))
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

  def parsed_domain
    persister.middleware_domains.data.first
  end

  delegate :data, :to => :parsed_domain, :prefix => true

  it 'parses a basic domain' do
    parser.parse
    expect(parsed_domain_data).to include(
      :name       => 'master',
      :feed       => 'feed1',
      :type_path  => 'Domain Host',
      :nativeid   => 'host_master',
      :ems_ref    => 'host_master',
      :properties => include(
        'Running Mode'         => 'NORMAL',
        'Version'              => '11.0.0.Final',
        'Product Name'         => 'WildFly Full',
        'Host State'           => 'running',
        'Is Domain Controller' => 'true',
        'Name'                 => 'master',
      )
    )
  end

  it 'assigns enabled status to a domain with "up" metric' do
    metric_data.data.first['value'] = 'up'

    parser.parse
    expect(parsed_domain.properties).to include('Availability' => 'Running')
  end

  it 'assigns disabled status to a domain with "down" metric' do
    metric_data.data.first['value'] = 'down'

    parser.parse
    expect(parsed_domain.properties).to include('Availability' => 'Stopped')
  end

  it 'assigns disabled status to a domain with "down" metric' do
    metric_data.data.first['value'] = 'down'

    parser.parse
    expect(parsed_domain.properties).to include('Availability' => 'Stopped')
  end

  it 'assigns unknown status to a domain whose metric is something else than "up" or "down"' do
    parser.parse
    expect(parsed_domain.properties).to include('Availability' => 'Unknown')
  end

  it 'assigns unknown status to a domain with a missing metric' do
    allow(collector).to receive(:raw_availability_data)
      .with(%w(host_master_avail), hash_including(:order => 'DESC'))
      .and_return([])

    parser.parse
    expect(parsed_domain.properties).to include('Availability' => 'Unknown')
  end
end
