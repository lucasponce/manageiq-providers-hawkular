require_relative '../../middleware_manager/hawkular_helper'

describe ManageIQ::Providers::Hawkular::Inventory::Parser::MiddlewareDomains do
  let(:ems_hawkular) { ems_hawkular_fixture }
  let(:metric_data) do
    { 'metric' => {'__name__' => 'wildfly_domain_host_availability'}, 'value' => [123, 'arbitrary value'] }
  end
  let(:controller_with_tree) do
    Hawkular::Inventory::Resource.new(
      'id'       => 'hc1',
      'feedId'   => 'feed1',
      'name'     => 'Local',
      'type'     => {'id' => 'Host Controller WF10'},
      'config'   => {
        'Version'         => '11.0.0.Final',
        'Local Host Name' => 'master',
        'Product Name'    => 'WildFly Full',
        'Process Type'    => 'Host Controller WF10'
      },
      'children' => [
        {
          'id'       => 'host_master',
          'parentId' => 'hc1',
          'feedId'   => 'feed1',
          'name'     => 'master',
          'type'     => {'id' => 'Domain Host WF10'},
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
              'displayName' => 'Domain Host Availability',
              'family'      => 'wildfly_domain_host_availability',
              'unit'        => 'NONE',
              'expression'  => 'wildfly_domain_host_availability{feed_id=\"feed1\"}',
              'labels'      => {
                'feed_id' => 'feed1'
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
          .with(array_including(hash_including('displayName' => 'Domain Host Availability')), any_args)
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
      :type_path  => 'Domain Host WF10',
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

  it 'assigns Running status to a domain with "up" metric' do
    metric_data['value'][1] = '1'

    parser.parse
    expect(parsed_domain.properties).to include('Availability' => 'Running')
  end

  it 'assigns STOPPED status to a domain with "down" metric' do
    metric_data['value'][1] = '0'

    parser.parse
    expect(parsed_domain.properties).to include('Availability' => 'STOPPED')
  end

  it 'assigns Unknown status to a domain with a missing metric' do
    allow(collector).to receive(:raw_availability_data)
      .with(array_including(hash_including('displayName' => 'Domain Host Availability')), any_args)
      .and_return([])

    parser.parse
    expect(parsed_domain.properties).to include('Availability' => 'Unknown')
  end
end
