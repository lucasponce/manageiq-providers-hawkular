describe ManageIQ::Providers::Hawkular::MiddlewareManager::EventCatcher::Stream do
  let(:auth_token) do
    AuthToken.new(:name     => "jdoe",
                  :auth_key => "password",
                  :userid   => "jdoe",
                  :password => "password")
  end

  let(:metric_type_meta) { OpenStruct.new(:type => 't1', :id => 'mt1', :unit => 'unit1') }
  let(:availability_metric) { { 'id' => 'm1', 'data' => [{ 'timestamp' => 400, 'value' => 'up'}] } }
  let(:deployment_availability_metric) do
    {
      'name'       => 'm1',
      'type'       => 'Deployment Status',
      'unit'       => 'BYTES',
      'properties' => {
        'hawkular.metric.typeId' => 't1',
        'hawkular.metric.type'   => 'unit1',
        'hawkular.metric.id'     => 'm1'
      }
    }
  end
  let(:server_availability_metric) do
    {
      'name'       => 'm1',
      'type'       => 'Server Availability',
      'unit'       => 'BYTES',
      'properties' => {
        'hawkular.metric.typeId' => 't1',
        'hawkular.metric.type'   => 'unit1',
        'hawkular.metric.id'     => 'm1'
      }
    }
  end
  let(:deployment_resource) do
    ::Hawkular::Inventory::Resource.new(
      'id'      => 'r1',
      'name'    => 'foo',
      'type'    => {
        'id' => 'Deployment'
      },
      'metrics' => [deployment_availability_metric]
    )
  end
  let(:server_resource) do
    ::Hawkular::Inventory::Resource.new(
      'id'      => 'server_id',
      'name'    => 'bar',
      'type'    => {
        'id' => 'WildFly Server'
      },
      'metrics' => [server_availability_metric]
    )
  end
  let(:domain_resource) do
    ::Hawkular::Inventory::Resource.new(
      'id'      => 'server_id',
      'name'    => 'bar',
      'type'    => {
        'id' => 'Domain Host'
      },
      'config'  => {
        'Is Domain Controller' => 'true'
      },
      'metrics' => [
        {
          'name'       => 'm1',
          'type'       => 'm1',
          'unit'       => 'BYTES',
          'properties' => {
            'hawkular.metric.typeId' => 't1',
            'hawkular.metric.type'   => 'unit1',
            'hawkular.metric.id'     => 'mt1'
          }
        }
      ]
    )
  end

  let(:ems_hawkular) do
    _guid, _server, zone = EvmSpecHelper.create_guid_miq_server_zone
    FactoryGirl.create(:ems_hawkular,
                       :hostname        => 'localhost',
                       :port            => 8080,
                       :authentications => [auth_token],
                       :zone            => zone)
  end

  let(:stubbed_metrics_client) do
    client = instance_double('::Hawkular::Metrics::Client')

    allow(client).to receive_message_chain(:avail, :raw_data)
      .with(['m1'], any_args).and_return([availability_metric])

    client
  end

  let(:stubbed_inventory_client) do
    client = instance_double('::Hawkular::Inventory::Client')

    allow(client).to receive(:resources_for_type)
      .with('Deployment')
      .and_return([deployment_resource])

    allow(client).to receive(:resources_for_type)
      .with('WildFly Server')
      .and_return([server_resource])
    allow(client).to receive(:resources_for_type)
      .with('Domain WildFly Server')
      .and_return([])

    allow(client).to receive(:resources_for_type)
      .with('Domain Host')
      .and_return([domain_resource])

    client
  end

  let(:client_with_some_stubs) do
    client = ::Hawkular::Client.new(
      :entrypoint  => 'http://localhost:8080',
      :credentials => {
        :username => 'jdoe',
        :password => 'password'
      },
      :options     => { :tenant => 'hawkular' }
    )
    allow(client).to receive(:metrics).and_return(stubbed_metrics_client)
    allow(client).to receive(:inventory).and_return(stubbed_inventory_client)
    client
  end

  subject do
    allow(ems_hawkular).to receive(:connect).and_return(client_with_some_stubs)
    described_class.new(ems_hawkular)
  end

  matcher :hawkular_cp do |cp_expected|
    expected = {
      :tenant_id        => nil,
      :feed_id          => nil,
      :environment_id   => nil,
      :resource_type_id => nil,
      :metric_type_id   => nil,
      :resource_ids     => nil,
      :metric_id        => nil
    }.merge(cp_expected)
    match do |actual|
      expected.all? { |k, v| actual.send(k) == v }
    end
  end

  context "#each_batch" do
    # VCR.eject_cassette
    # VCR.turn_off!(ignore_cassettes: true)

    VCR.configure do |c|
      c.default_cassette_options = {
        :match_requests_on => [:method, VCR.request_matchers.uri_without_params(:startTime)]
      }
    end

    it "yields a valid event" do
      ems_hawkular.middleware_deployments.create(:feed => 'f1', :ems_ref => 'r1')

      # if generating a cassette the polling window is the previous 1 minute
      # TODO: Make it predictable with live tests.
      VCR.use_cassette(described_class.name.underscore.to_s,
                       :decode_compressed_response => true,
                       :record                     => :none) do
        result = []
        subject.start
        subject.each_batch do |events|
          result = events
          subject.stop
        end
        expect(result.count).to be == 2
        expect(result.find { |item| item.kind_of?(::Hawkular::Alerts::Event) }.tags['miq.event_type']).to eq 'hawkular_event.critical'
        expect(result.find { |item| item.kind_of?(Hash) && item[:association] == :middleware_deployments }).to_not be_blank
      end
    end
  end

  describe "#fetch_availabilities (servers)" do
    let!(:db_server) do
      ems_hawkular.middleware_servers.create(
        :feed       => 'f1',
        :ems_ref    => 'r1',
        :properties => {
          'Server State'            => 'running',
          'Availability'            => 'up',
          'Calculated Server State' => 'running'
        }
      )
    end
    let(:server_resource) do
      ::Hawkular::Inventory::Resource.new(
        'id'      => 'r1',
        'name'    => 'server 1',
        'type'    => { 'id' => 'type_id', 'operations' => [] },
        'config'  => { 'Server State' => 'running' },
        'metrics' => [server_availability_metric]
      )
    end

    before do
      allow(stubbed_inventory_client).to receive(:get_resource)
        .with(db_server.ems_ref, true)
        .and_return(server_resource)
    end

    it "must return updated status for server without properties hash" do
      # Set-up
      db_server.properties = nil
      db_server.save!

      # Try
      updates = subject.send(:fetch_availabilities)

      # Verify
      expect(updates).to eq(
        [{
          :ems_ref     => db_server.ems_ref,
          :association => :middleware_servers,
          :data        => {
            'Server State'            => 'running',
            'Availability'            => 'up',
            'Calculated Server State' => 'running'
          }
        }]
      )
    end

    it "must omit server with unchanged status" do
      # Try
      updates = subject.send(:fetch_availabilities)

      # Validate
      expect(updates).to be_blank
    end

    it "must set unknown status if server availability has expired or is not present" do
      # Set-up
      allow(stubbed_metrics_client).to receive_message_chain(:avail, :raw_data)
        .with(['m1'], any_args).and_return([])

      # Try
      updates = subject.send(:fetch_availabilities)

      # Verify
      expect(updates).to eq(
        [{
          :ems_ref     => db_server.ems_ref,
          :association => :middleware_servers,
          :data        => {
            'Server State'            => 'running',
            'Availability'            => 'unknown',
            'Calculated Server State' => 'unknown'
          }
        }]
      )
    end

    it "must return updated state if inventory server state has changed" do
      # Set-up
      server_resource.config['Server State'] = 'reload-required'

      # Try
      updates = subject.send(:fetch_availabilities)

      # Verify
      expect(updates).to eq(
        [{
          :ems_ref     => db_server.ems_ref,
          :association => :middleware_servers,
          :data        => {
            'Server State'            => 'reload-required',
            'Availability'            => 'up',
            'Calculated Server State' => 'reload-required'
          }
        }]
      )
    end

    it "must return updated state if availability metric has changed" do
      # Set-up
      availability_metric['data'][0]['value'] = 'down'

      # Try
      updates = subject.send(:fetch_availabilities)

      # Verify
      expect(updates).to eq(
        [{
          :ems_ref     => db_server.ems_ref,
          :association => :middleware_servers,
          :data        => {
            'Server State'            => 'running',
            'Availability'            => 'down',
            'Calculated Server State' => 'down'
          }
        }]
      )
    end
  end

  describe "#fetch_availabilities (deployments)" do
    let!(:db_deployment) { ems_hawkular.middleware_deployments.create(:feed => 'f1', :ems_ref => 'r1', :status => 'Disabled') }

    it "must return updated status for deployment whose availability has changed" do
      # Try
      updates = subject.send(:fetch_availabilities)

      # Verify
      expect(updates).to eq(
        [{
          :ems_ref     => db_deployment.ems_ref,
          :association => :middleware_deployments,
          :data        => { :status => 'Enabled' }
        }]
      )
    end

    it "must omit deployment with unchanged availability" do
      # Set-up
      availability_metric['data'][0]['value'] = 'down'

      # Try
      updates = subject.send(:fetch_availabilities)

      # Verify
      expect(updates).to be_blank
    end

    it "must set unknown status if deployment availability has expired or is not present" do
      # Set-up
      allow(stubbed_metrics_client).to receive_message_chain(:avail, :raw_data)
        .with(['m1'], any_args).and_return([])

      # Try
      updates = subject.send(:fetch_availabilities)

      # Verify
      expect(updates).to eq(
        [{
          :ems_ref     => db_deployment.ems_ref,
          :association => :middleware_deployments,
          :data        => { :status => 'Unknown' }
        }]
      )
    end
  end

  describe "#fetch_availabilities (domains)" do
    let!(:db_domain) do
      ems_hawkular.middleware_domains.create(
        :feed       => 'f1',
        :ems_ref    => '/t;hawkular/f;f1/r;resource1',
        :properties => {
          'Server State' => 'down',
          'Availability' => 'Stopped',
        }
      )
    end

    it "returns updated status for domain whose availability has changed" do
      updates = subject.send(:fetch_availabilities)

      expect(updates).to eq(
        [{
          :ems_ref     => db_domain.ems_ref,
          :association => :middleware_domains,
          :data        => { :properties => { 'Availability' => 'Running' } }
        }]
      )
    end

    it "omits domain with unchanged availability" do
      availability_metric['data'][0]['value'] = 'down'

      updates = subject.send(:fetch_availabilities)

      expect(updates).to be_blank
    end

    it "sets unknown status if domain availability has expired or is not present" do
      allow(stubbed_metrics_client).to receive_message_chain(:avail, :raw_data)
        .with(['m1'], any_args).and_return([])

      updates = subject.send(:fetch_availabilities)

      expect(updates).to eq(
        [{
          :ems_ref     => db_domain.ems_ref,
          :association => :middleware_domains,
          :data        => { :properties => { 'Availability' => 'Unknown' } }
        }]
      )
    end
  end
end
