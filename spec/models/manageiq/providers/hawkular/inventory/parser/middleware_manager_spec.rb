require_relative '../../middleware_manager/hawkular_helper'

describe ManageIQ::Providers::Hawkular::Inventory::Parser::MiddlewareManager do
  def inventory_object_data(inventory_object)
    inventory_object
      .data
      .slice(*inventory_object.inventory_collection.inventory_object_attributes)
  end

  let(:ems_hawkular) { ems_hawkular_fixture }
  let(:persister) { ::ManageIQ::Providers::Hawkular::Inventory::Persister::MiddlewareManager.new(ems_hawkular, ems_hawkular) }
  let(:collector_double) { instance_double('ManageIQ::Providers::Hawkular::Inventory::Collector::MiddlewareManager') }
  let(:persister_double) { instance_double('ManageIQ::Providers::Hawkular::Inventory::Persister::MiddlewareManager') }
  let(:parser) do
    parser = described_class.new
    parser.collector = collector_double
    parser.persister = persister_double
    parser
  end
  let(:stubbed_metric_data) { OpenStruct.new(:id => 'm1', :data => [{'timestamp' => 1, 'value' => 'arbitrary value'}]) }
  let(:server) do
    FactoryGirl.create(:hawkular_middleware_server,
                       :name                  => 'Local',
                       :feed                  => the_feed_id,
                       :ems_ref               => '/t;Hawkular'\
                                                 "/f;#{the_feed_id}/r;Local~~",
                       :nativeid              => 'Local~~',
                       :ext_management_system => ems_hawkular,
                       :properties            => { 'Server Status' => 'Inventory Status' })
  end

  describe 'parse_datasource' do
    it 'handles simple data' do
      # parse_datasource(server, datasource, config)
      datasource = double(:name   => 'ruby-sample-build',
                          :id     => 'datasource_id',
                          :config => {
                            'Driver Name'    => 'h2',
                            'JNDI Name'      => 'java:jboss/datasources/ExampleDS',
                            'Connection URL' => 'jdbc:h2:mem:test;DB_CLOSE_DELAY=-1;DB_CLOSE_ON_EXIT=FALSE',
                            'Enabled'        => 'true'
                          })
      parsed_datasource = {
        :name       => 'ruby-sample-build',
        :nativeid   => 'datasource_id',
        :ems_ref    => 'datasource_id',
        :properties => {
          'Driver Name'    => 'h2',
          'JNDI Name'      => 'java:jboss/datasources/ExampleDS',
          'Connection URL' => 'jdbc:h2:mem:test;DB_CLOSE_DELAY=-1;DB_CLOSE_ON_EXIT=FALSE',
          'Enabled'        => 'true'
        }
      }
      inventory_obj = persister.middleware_datasources.build(:ems_ref => datasource.id)
      parser.parse_datasource(datasource, inventory_obj)
      expect(inventory_object_data(inventory_obj)).to eq(parsed_datasource)
    end
  end

  describe 'parse_domain' do
    it 'handles simple data' do
      config = {
        'Running Mode'         => 'NORMAL',
        'Version'              => '9.0.2.Final',
        'Product Name'         => 'WildFly Full',
        'Host State'           => 'running',
        'Is Domain Controller' => 'true',
        'Name'                 => 'master',
      }
      type_id = 'Host Controller'
      feed = 'master.Unnamed%20Domain'
      id = 'domain_id'
      name = 'Unnamed Domain'
      type = OpenStruct.new(:id => type_id)
      domain = OpenStruct.new(:name   => name,
                              :feed   => feed,
                              :id     => id,
                              :config => config,
                              :type   => type)
      parsed_domain = {
        :name       => name,
        :feed       => feed,
        :type_path  => type_id,
        :nativeid   => id,
        :ems_ref    => id,
        :properties => config,
      }
      inventory_obj = persister.middleware_domains.build(:ems_ref => id)
      parser.parse_middleware_domain(domain, inventory_obj)
      expect(inventory_object_data(inventory_obj)).to eq(parsed_domain)
    end
  end

  describe 'fetch_availabilities_for' do
    let(:stubbed_resource) { OpenStruct.new(:ems_ref => '/t;hawkular/f;f1/r;stubbed_resource') }
    let(:stubbed_metric_definition) { OpenStruct.new(:path => '/t;hawkular/f;f1/r;stubbed_resource/m;m1', :hawkular_metric_id => 'm1') }

    let(:resource_1) { OpenStruct.new(:id => '/t;hawkular/f;f1/r;stubbed_resource') }
    let(:resource_2) { OpenStruct.new(:id => 'resource_2_id') }

    let(:collection) { OpenStruct.new }

    let(:metric) do
      OpenStruct.new(
        :properties => OpenStruct.new(
          :'hawkular.metric.typeId' => 'metric_type',
          :'hawkular.metric.id'     => 'm1'
        )
      )
    end

    before do
      allow(collector_double).to receive(:raw_availability_data)
        .with(%w(m1), hash_including(:order => 'DESC'))
        .and_return([stubbed_metric_data])

      allow(metric).to receive(:hawkular_id).and_return(metric.properties['hawkular.metric.id'])

      allow(resource_1).to receive(:metrics_by_type).and_return([metric])
      allow(resource_2).to receive(:metrics_by_type).and_return([metric])
      allow(collection).to receive(:find_by).and_return(OpenStruct.new(:ems_ref => 'random'))
      allow(collection).to receive(:find_by)
        .with(:ems_ref => stubbed_resource.ems_ref)
        .and_return(stubbed_resource)
    end

    def call_subject(inventory_resources, collection)
      matched_metrics = {}
      parser.fetch_availabilities_for(inventory_resources, collection, 'metric_type') do |resource, metric|
        matched_metrics[resource] = metric
      end

      matched_metrics
    end

    it 'must query resources for metrics type' do
      expect(resource_1).to receive(:metrics_by_type).with('metric_type')
      expect(resource_2).to receive(:metrics_by_type).with('metric_type')

      parser.fetch_availabilities_for([resource_1, resource_2], collection, 'metric_type') { |r, m| }
    end

    it 'must call block with missing metrics to allow caller to set defaults' do
      allow(metric).to receive(:hawkular_id).and_return('idsuffix')
      allow(collector_double).to receive(:raw_availability_data)
        .with(%w(idsuffix), hash_including(:order => 'DESC'))
        .and_return([])

      matched_metrics = call_subject([resource_1], collection)
      expect(matched_metrics).to eq(stubbed_resource => nil)
    end

    it 'must call block with matching resource and metric to allow caller to process the metric' do
      matched_metrics = call_subject([resource_1], collection)
      expect(matched_metrics).to eq(stubbed_resource => stubbed_metric_data)
    end

    it 'must call block handling a metric shared by more than one resource' do
      stubbed_resource2 = OpenStruct.new(:ems_ref => 'resource_2_id')

      allow(collection).to receive(:find_by)
        .with(:ems_ref => stubbed_resource2.ems_ref)
        .and_return(stubbed_resource2)

      matched_metrics = call_subject([resource_1, resource_2], collection)
      expect(matched_metrics).to eq(stubbed_resource => stubbed_metric_data, stubbed_resource2 => stubbed_metric_data)
    end
  end

  describe 'fetch_deployment_availabilities' do
    let(:stubbed_deployment) { OpenStruct.new(:manager_uuid => '/t;hawkular/f;f1/r;s1/r;d1') }

    before do
      deployments_collection = [stubbed_deployment]
      deployments_collection.define_singleton_method(
        :model_class,
        -> { ::ManageIQ::Providers::Hawkular::MiddlewareManager::MiddlewareDeployment }
      )
      allow(collector_double).to receive(:deployments).and_return([])
      allow(collector_double).to receive(:subdeployments).and_return([])

      allow(persister_double).to receive(:middleware_deployments).and_return(deployments_collection)
      allow(parser).to receive(:fetch_availabilities_for)
        .and_yield(stubbed_deployment, stubbed_metric_data)
    end

    it 'uses fetch_availabilities_for to fetch deployment availabilities' do
      parser.fetch_deployment_availabilities
      expect(parser).to have_received(:fetch_availabilities_for)
        .with([], [stubbed_deployment], 'Deployment Status')
    end

    it 'assigns enabled status to a deployment with "up" metric' do
      stubbed_metric_data.data.first['value'] = 'up'

      parser.fetch_deployment_availabilities
      expect(stubbed_deployment.status).to eq('Enabled')
    end

    it 'assigns disabled status to a deployment with "down" metric' do
      stubbed_metric_data.data.first['value'] = 'down'

      parser.fetch_deployment_availabilities
      expect(stubbed_deployment.status).to eq('Disabled')
    end

    it 'assigns unknown status to a deployment whose metric is something else than "up" or "down"' do
      parser.fetch_deployment_availabilities
      expect(stubbed_deployment.status).to eq('Unknown')
    end

    it 'assigns unknown status to a deployment with a missing metric' do
      allow(parser).to receive(:fetch_availabilities_for)
        .and_yield(stubbed_deployment, nil)

      parser.fetch_deployment_availabilities
      expect(stubbed_deployment.status).to eq('Unknown')
    end
  end

  describe 'fetch_server_availabilities' do
    before do
      server_collection = [server]
      server_collection.define_singleton_method(
        :model_class,
        -> { ::ManageIQ::Providers::Hawkular::MiddlewareManager::MiddlewareServer }
      )

      allow(persister_double).to receive(:middleware_servers).and_return(server_collection)
      allow(parser).to receive(:fetch_availabilities_for)
        .and_yield(server, stubbed_metric_data)
    end

    it 'uses fetch_availabilities_for to resolve server availabilities' do
      parser.fetch_server_availabilities([])
      expect(parser).to have_received(:fetch_availabilities_for)
        .with([], [server], 'Server Availability')
    end

    it 'assigns status reported by inventory to a server with "up" metric' do
      stubbed_metric_data.data.first['value'] = 'up'

      parser.fetch_server_availabilities([])

      expect(server.properties['Availability']).to eq('up')
      expect(server.properties['Calculated Server State']).to eq(server.properties['Server State'])
    end

    it 'assigns status reported by metric to a server when its availability metric is something else than "up"' do
      parser.fetch_server_availabilities([])
      expect(server.properties['Availability']).to eq('arbitrary value')
      expect(server.properties['Calculated Server State']).to eq('arbitrary value')
    end

    it 'assigns unknown status to a server with a missing metric' do
      allow(parser).to receive(:fetch_availabilities_for)
        .and_yield(server, nil)

      parser.fetch_server_availabilities([])
      expect(server.properties['Availability']).to eq('unknown')
      expect(server.properties['Calculated Server State']).to eq('unknown')
    end
  end

  describe 'fetch_domain_availabilities' do
    let(:domain) do
      FactoryGirl.create(:hawkular_middleware_server,
                         :name                  => 'Local',
                         :feed                  => the_feed_id,
                         :ems_ref               => '/t;Hawkular'\
                                                     "/f;#{the_feed_id}/r;Local~~",
                         :nativeid              => 'Local~~',
                         :ext_management_system => ems_hawkular,
                         :properties            => { 'Server Status' => 'Inventory Status' })
    end

    before do
      domains_collection = [domain]
      domains_collection.define_singleton_method(
        :model_class,
        -> { ::ManageIQ::Providers::Hawkular::MiddlewareManager::MiddlewareDomain }
      )

      allow(collector_double).to receive(:domains).and_return([])
      allow(persister_double).to receive(:middleware_domains).and_return(domains_collection)
      allow(parser).to receive(:fetch_availabilities_for)
        .and_yield(domain, stubbed_metric_data)
    end

    it 'uses fetch_availabilities_for to fetch domain availabilities' do
      parser.fetch_domain_availabilities
      expect(parser).to have_received(:fetch_availabilities_for)
        .with([], [domain], 'Domain Availability')
    end

    it 'assigns enabled status to a domain with "up" metric' do
      stubbed_metric_data.data.first['value'] = 'up'

      parser.fetch_domain_availabilities
      expect(domain.properties).to include('Availability' => 'Running')
    end

    it 'assigns disabled status to a domain with "down" metric' do
      stubbed_metric_data.data.first['value'] = 'down'

      parser.fetch_domain_availabilities
      expect(domain.properties).to include('Availability' => 'Stopped')
    end

    it 'assigns unknown status to a domain whose metric is something else than "up" or "down"' do
      parser.fetch_domain_availabilities
      expect(domain.properties).to include('Availability' => 'Unknown')
    end

    it 'assigns unknown status to a domain with a missing metric' do
      allow(parser).to receive(:fetch_availabilities_for)
        .and_yield(domain, nil)

      parser.fetch_domain_availabilities
      expect(domain.properties).to include('Availability' => 'Unknown')
    end
  end

  describe '#alternate_machine_id' do
    it 'should transform machine ID to dmidecode BIOS UUID' do
      # the /etc/machine-id is usually in downcase, and the dmidecode BIOS UUID is usually upcase
      # the alternate_machine_id should *just* swap digits, it should not handle upcase/downcase.
      # 33D1682F-BCA4-4B4C-B19E-CB47D344746C is a real BIOS UUID retrieved from a VM
      # 33d1682f-bca4-4b4c-b19e-cb47d344746c is what other providers store in the DB
      # 2f68d133a4bc4c4bb19ecb47d344746c is the machine ID for the BIOS UUID above
      # at the Middleware Provider, we get the second version, while the first is usually used by other providers
      machine_id = '2f68d133a4bc4c4bb19ecb47d344746c'
      expected = '33d1682f-bca4-4b4c-b19e-cb47d344746c'
      expect(parser.alternate_machine_id(machine_id)).to eq(expected)

      # and now we reverse the operation, just as a sanity check
      machine_id = '33d1682fbca44b4cb19ecb47d344746c'
      expected = '2f68d133-a4bc-4c4b-b19e-cb47d344746c'
      expect(parser.alternate_machine_id(machine_id)).to eq(expected)
    end

    it 'should reject id that is not 32 charasters length' do
      expect(parser.alternate_machine_id('abc123')).to be_nil
    end

    it 'should reject id with non hexadecimal characters' do
      expect(parser.alternate_machine_id('abcdef1234567890abcdef123456789P')).to be_nil
    end
  end

  describe '#dashed_machine_id' do
    it 'should reject id that is not 32 charasters length' do
      expect(parser.dashed_machine_id('abc123')).to be_nil
    end

    it 'should reject id with non hexadecimal characters' do
      expect(parser.dashed_machine_id('abcdef1234567890abcdef123456789P')).to be_nil
    end

    it 'should add dashes at standard locations' do
      expect(parser.dashed_machine_id('abcdef1234567890abcdef1234567890')).to eq('abcdef12-3456-7890-abcd-ef1234567890')
    end
  end

  describe 'swap_part' do
    it 'should swap and reverse every two bytes of a machine ID part' do
      # the /etc/machine-id is usually in downcase, and the dmidecode BIOS UUID is usually upcase
      # the alternate_machine_id should *just* swap digits, it should not handle upcase/downcase.
      # 33D1682F-BCA4-4B4C-B19E-CB47D344746C is a real BIOS UUID retrieved from a VM
      # 33d1682f-bca4-4b4c-b19e-cb47d344746c is what other providers store in the DB
      # 2f68d133a4bc4c4bb19ecb47d344746c is the machine ID for the BIOS UUID above
      # at the Middleware Provider, we get the second version, while the first is usually used by other providers
      part = '2f68d133'
      expected = '33d1682f'
      expect(parser.swap_part(part)).to eq(expected)

      # and now we reverse the operation, just as a sanity check
      part = '33d1682f'
      expected = '2f68d133'
      expect(parser.swap_part(part)).to eq(expected)
    end
  end

  describe 'associate_with_vm' do
    it 'should be able to associate with the existing vm' do
      allow(parser).to receive(:machine_id_by_feed).with(server.feed).and_return(test_machine_id)
      vm = FactoryGirl.create(:vm_redhat, :uid_ems => test_machine_id)
      parser.associate_with_vm(server, server.feed)
      expect(server.lives_on).to eq(vm)
    end

    it 'should associate to vm even if agent reports machine id withouth dashes, but vm guid is reported with dashes' do
      allow(parser).to receive(:machine_id_by_feed).with(server.feed).and_return('abcdef1234567890abcdef1234567890')
      vm = FactoryGirl.create(:vm_redhat, :uid_ems => 'abcdef12-3456-7890-abcd-ef1234567890')
      parser.associate_with_vm(server, server.feed)
      expect(server.lives_on).to eq(vm)
    end

    it 'should do nothing if the vm is not there' do
      allow(parser).to receive(:machine_id_by_feed).and_return(nil)
      parser.associate_with_vm(server, server.feed)
      expect(server.lives_on).to be_nil
    end
  end

  describe 'handle_no_machine_id' do
    it 'should_find_nil_for_nil' do
      expect(parser.find_host_by_bios_uuid(nil)).to be_nil
    end

    it 'should_alternate_nil_for_nil' do
      expect(parser.alternate_machine_id(nil)).to be_nil
    end
  end
end
