require_relative '../../middleware_manager/hawkular_helper'

describe ManageIQ::Providers::Hawkular::Inventory::Parser::MiddlewareDomains do
  let(:ems_hawkular) { ems_hawkular_fixture }
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
          'children' => []
        }
      ]
    )
  end
  let(:collector) do
    ManageIQ::Providers::Hawkular::Inventory::Collector::MiddlewareManager
      .new(ems_hawkular, ems_hawkular)
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

  it 'parses a basic domain' do
    allow(collector).to receive(:host_controllers).and_return([controller_with_tree])
    allow(collector).to receive(:resource_tree).with('hc1').and_return(controller_with_tree)
    allow(collector).to receive(:domains).and_return([])

    parser.parse
    expect(persister.middleware_domains.data.first.data).to include(
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
end
