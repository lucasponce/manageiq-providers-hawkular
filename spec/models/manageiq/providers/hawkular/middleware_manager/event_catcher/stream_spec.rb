require_relative '../../middleware_manager/hawkular_helper'

describe ManageIQ::Providers::Hawkular::MiddlewareManager::EventCatcher::Stream do
  let(:ems_hawkular) { ems_hawkular_fixture }

  let(:availability_metric) do
    { 'metric' => {'__name__' => 'availability'}, 'value' => [123, '1'] }
  end

  let(:deployment_availability_metric) do
    {
      'displayName' => 'Deployment Status',
      'family'      => 'wildfly_deployment_availability',
      'unit'        => 'NONE',
      'expression'  => 'wildfly_deployment_availability{feed_id=\"f1\",deployment=\"dp1.ear\"}',
      'labels'      => {
        'feed_id'    => 'f1',
        'deployment' => 'dp1.ear'
      }
    }
  end

  let(:server_availability_metric) do
    {
      'displayName' => 'Server Availability',
      'family'      => 'wildfly_server_availability',
      'unit'        => 'NONE',
      'expression'  => 'wildfly_server_availability{feed_id=\"f1\"}',
      'labels'      => {
        'feed_id' => 'f1'
      }
    }
  end

  let(:domain_availability_metric) do
    {
      'displayName' => 'Domain Host Availability',
      'family'      => 'wildfly_domain_host_availability',
      'unit'        => 'NONE',
      'expression'  => 'wildfly_domain_host_availability{feed_id=\"f1\"}',
      'labels'      => {
        'feed_id' => 'f1'
      }
    }
  end

  let(:deployment_resource) do
    ::Hawkular::Inventory::Resource.new(
      'id'       => 'deployment1',
      'name'     => 'dp1.ear',
      'feedId'   => 'f1',
      'type'     => {'id' => 'Deployment WF10'},
      'parentId' => 'server1',
      'metrics'  => [deployment_availability_metric]
    )
  end

  let(:server_resource) do
    ::Hawkular::Inventory::Resource.new(
      'id'      => 'server1',
      'name'    => 'Server Number One',
      'feedId'  => 'f1',
      'type'    => { 'id' => 'WildFly Server WF10' },
      'metrics' => [server_availability_metric]
    )
  end

  let(:domain_host_resource) do
    ::Hawkular::Inventory::Resource.new(
      'id'       => 'domain1',
      'parentId' => 'hc1',
      'feedId'   => 'f1',
      'name'     => 'domain1 controller',
      'type'     => {'id' => 'Domain Host WF10'},
      'config'   => {
        'Host State'           => 'running',
        'Is Domain Controller' => 'true',
        'UUID'                 => 'uuid1',
        'Name'                 => 'domain1 controller'
      },
      'metrics'  => [domain_availability_metric]
    )
  end

  let(:collector) do
    ManageIQ::Providers::Hawkular::Inventory::Collector::MiddlewareManager
      .new(ems_hawkular, ems_hawkular)
      .tap do |collector|
        allow(collector).to receive(:resources_for) do |arg|
          case arg
          when 'Deployment WF10'
            [deployment_resource]
          when 'WildFly Server WF10'
            [server_resource]
          when 'Domain Host WF10'
            [domain_host_resource]
          else
            []
          end
        end

        allow(collector).to receive(:raw_availability_data)
          .with(any_args)
          .and_return([availability_metric])
      end
  end

  subject do
    described_class.new(ems_hawkular, collector)
  end

  matcher :hawkular_cp do |cp_expected|
    expected = {
      :tenant_id        => nil,
      :feed_id          => nil,
      :environment_id   => nil,
      :resource_type_id => nil,
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
      ems_hawkular.middleware_deployments.create(:feed => 'f1', :ems_ref => 'deployment1')

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
        :ems_ref    => 'server1',
        :properties => {
          'Server State'            => 'running',
          'Availability'            => 'Running',
          'Calculated Server State' => 'running'
        }
      )
    end
    let(:server_resource) do
      ::Hawkular::Inventory::Resource.new(
        'id'      => 'server1',
        'feed_id' => 'f1',
        'name'    => 'server 1',
        'type'    => { 'id' => 'type_id' },
        'config'  => { 'Server State' => 'running' },
        'metrics' => [server_availability_metric]
      )
    end

    before do
      allow(collector).to receive(:resource) do
        server_resource
      end
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
            'Availability'            => 'Running',
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
      allow(collector).to receive(:raw_availability_data)
        .with(any_args)
        .and_return([])

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
            'Availability'            => 'Running',
            'Calculated Server State' => 'reload-required'
          }
        }]
      )
    end

    it "must return updated state if availability metric has changed" do
      # Set-up
      availability_metric['value'][1] = '0'

      # Try
      updates = subject.send(:fetch_availabilities)

      # Verify
      expect(updates).to eq(
        [{
          :ems_ref     => db_server.ems_ref,
          :association => :middleware_servers,
          :data        => {
            'Server State'            => 'running',
            'Availability'            => 'STOPPED',
            'Calculated Server State' => 'STOPPED'
          }
        }]
      )
    end
  end

  describe "#fetch_availabilities (deployments)" do
    let!(:db_deployment) do
      ems_hawkular.middleware_deployments.create(
        :feed    => 'f1',
        :ems_ref => 'deployment1',
        :status  => 'Disabled'
      )
    end

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
      availability_metric['value'][1] = '0'

      # Try
      updates = subject.send(:fetch_availabilities)

      # Verify
      expect(updates).to be_blank
    end

    it "must set unknown status if deployment availability has expired or is not present" do
      # Set-up
      allow(collector).to receive(:raw_availability_data)
        .with(any_args)
        .and_return([])

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
        :ems_ref    => 'domain1',
        :properties => {
          'Server State' => 'down',
          'Availability' => 'STOPPED',
        }
      )
    end

    before do
      allow(collector).to receive(:resource) do
        domain_host_resource
      end
    end

    it "returns updated status for domain whose availability has changed" do
      # Set-up
      db_domain.properties = nil
      db_domain.save!

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
      availability_metric['value'][1] = '0'

      updates = subject.send(:fetch_availabilities)

      expect(updates).to be_blank
    end

    it "sets unknown status if domain availability has expired or is not present" do
      allow(collector).to receive(:raw_availability_data)
        .with(any_args)
        .and_return([])

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
