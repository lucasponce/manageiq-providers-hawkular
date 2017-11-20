module ManageIQ::Providers
  module Hawkular
    class Inventory::Parser::MiddlewareManager < ManagerRefresh::Inventory::Parser
      include ::Hawkular::ClientUtils
      include Vmdb::Logging

      SUPPORTED_VERSIONS = %w(WF10 EAP6).freeze
      SUPPORTED_ENTITIES = ['Deployment', 'SubDeployment', 'Datasource', 'JMS Queue', 'JMS Topic'].freeze

      def initialize
        super
        @data_index = {}
        @supported_types = []
        @supported_deployments = []
        @supported_datasources = []
        SUPPORTED_VERSIONS.each do |version|
          SUPPORTED_ENTITIES.each do |entity|
            @supported_types << "#{entity} #{version}"
          end
          %w(Deployment SubDeployment).each do |deployment|
            @supported_deployments << "#{deployment} #{version}"
          end
          @supported_datasources << "Datasource #{version}"
        end
      end

      def parse
        _log.info("DELETEME parse")
        # the order of the method calls is important here, because they make use of @data_index
        fetch_oss_configuration
        fetch_agents_configuration
        fetch_middleware_servers
        fetch_domains_with_servers
        fetch_server_entities
        fetch_availability
      end

      def fetch_oss_configuration
        collector.oss.each do |os|
          @data_index.store_path(:middleware_os_config, :by_feed, os.feed, os.config)
        end
      end

      def fetch_agents_configuration
        collector.agents.each do |agent|
          @data_index.store_path(:middleware_agent_config, :by_feed, agent.feed, agent.config)
        end
      end

      def fetch_middleware_servers
        collector.eaps.each do |eap|
          server = persister.middleware_servers.find_or_build(eap.id)
          parse_middleware_server(eap, server)
          agent_config = agent_config_by_feed(eap.feed)
          ['Immutable', 'In Container'].each do |feature|
            server.properties[feature] = 'true' if agent_config.try(:[], feature) == true
          end
          if server.properties['In Container'] == 'true'
            container_id = collector.container_id(eap.feed)['Container Id']
            if container_id
              backing_ref = 'docker://' + container_id
              container = Container.find_by(:backing_ref => backing_ref)
              set_lives_on(server, container) if container
            end
          else
            associate_with_vm(server, eap.feed)
          end
        end
      end

      def set_lives_on(server, lives_on)
        server.lives_on_id = lives_on.id
        server.lives_on_type = lives_on.type
      end

      def fetch_domains_with_servers
        collector.host_controllers.each do |host_controller|
          host_controller = collector.resource_tree(host_controller.id)
          collector.domains_from_host_controller(host_controller).each do |domain|
            parsed_domain = persister.middleware_domains.find_or_build(domain.id)
            parse_middleware_domain(domain, parsed_domain)

            # add the server groups to the domain
            fetch_server_groups(parsed_domain, host_controller)

            # now it's safe to fetch the domain servers (it assumes the server groups to be already fetched)
            fetch_domain_servers(host_controller)
          end
        end
      end

      def fetch_server_groups(parsed_domain, host_controller)
        collector.server_groups_from_host_controller(host_controller).map do |group|
          parsed_group = persister.middleware_server_groups.find_or_build(group.id)
          parse_middleware_server_group(group, parsed_group)
          # TODO: remove this index. Two options for this: 1) try to find or build the ems_ref
          # of the server group. 2) add `find_by` methods to InventoryCollection class. Once this
          # is removed, the order in #parse method will no longer be needed. For now, at least
          # domains, sever groups and domain servers must be collected in order.
          @data_index.store_path(:middleware_server_groups, :by_name, parsed_group[:name], parsed_group)

          parsed_group.middleware_domain = persister.middleware_domains.lazy_find(parsed_domain[:ems_ref])
        end
      end

      def fetch_domain_servers(host_controller)
        collector.domain_servers_from_host_controller(host_controller).each do |domain_server|
          server = persister.middleware_servers.find_or_build(domain_server.id)
          parse_middleware_server(domain_server, server, true)

          associate_with_vm(server, server.feed)

          # Add the association to server group. The information about what server is in which server group is under
          # the server-config resource's configuration
          server_group_name = domain_server.config['Server Group']
          unless server_group_name.nil?
            server_group = @data_index.fetch_path(:middleware_server_groups, :by_name, server_group_name)
            server.middleware_server_group = persister.middleware_server_groups.lazy_find(server_group[:ems_ref])
          end
        end
      end

      def machine_id_by_feed(feed)
        @data_index.fetch_path(:middleware_os_config, :by_feed, feed).try(:fetch, 'Machine Id')
      end

      def agent_config_by_feed(feed)
        @data_index.fetch_path(:middleware_agent_config, :by_feed, feed)
      end

      def alternate_machine_id(machine_id)
        # See the BZ #1294461 [1] for a more complete background.
        # Here, we'll try to adjust the machine ID to the format from that bug. We expect to get a string like
        # this: 2f68d133a4bc4c4bb19ecb47d344746c . For such string, we should return
        # this: 33d1682f-bca4-4b4c-b19e-cb47d344746c .The actual BIOS UUID is probably returned in upcase, but other
        # providers store it in downcase, so, we let the upcase/downcase logic to other methods with more
        # business knowledge.
        # 1 - https://bugzilla.redhat.com/show_bug.cgi?id=1294461
        return nil if machine_id.nil? || machine_id.length != 32 || machine_id[/\H/]
        alternate = []
        alternate << swap_part(machine_id[0, 8])
        alternate << swap_part(machine_id[8, 4])
        alternate << swap_part(machine_id[12, 4])
        alternate << machine_id[16, 4]
        alternate << machine_id[20, 12]
        alternate.join('-')
      end

      # Add standard dashes to a machine GUID that doesn't have dashes.
      #
      # @param machine_id [String] the GUI to which dashes should be added. The string
      #   is validated to be 32 characters long and to only contain valid hexadecimal
      #   digits. If any validations fail, nil is returned.
      # @return [String] the GUI with dashed added at standard locations.
      def dashed_machine_id(machine_id)
        return nil if machine_id.nil? || machine_id.length != 32 || machine_id[/\H/]
        [
          machine_id[0, 8],
          machine_id[8, 4],
          machine_id[12, 4],
          machine_id[16, 4],
          machine_id[20, 12]
        ].join('-')
      end

      def swap_part(part)
        # here, we receive parts of an UUID, split into an array with 2 chars each element, and reverse the invidual
        # elements, joining and reversing the final outcome
        # for instance:
        # 2f68d133 -> ["2f", "68", "d1", "33"] -> ["f2", "86", "1d", "33"] -> f2861d33 -> 33d1682f
        part.scan(/../).collect(&:reverse).join.reverse
      end

      def find_host_by_bios_uuid(machine_id)
        return if machine_id.nil?
        identity_system = machine_id.downcase

        if identity_system
          Vm.find_by(:uid_ems => identity_system,
                     :type    => uuid_provider_types)
        end
      end

      def uuid_provider_types
        # after the PoC, we might want to test/support these extra providers:
        # ManageIQ::Providers::Openstack::CloudManager::Vm
        # ManageIQ::Providers::Vmware::InfraManager::Vm
        'ManageIQ::Providers::Redhat::InfraManager::Vm'
      end

      def fetch_server_entities
        persister.middleware_servers.each do |eap|
          eap_tree = collector.resource_tree(eap.ems_ref)
          eap_tree.children(true).each do |child|
            next unless @supported_types.include?(child.type.id)
            process_server_entity(eap, child)
          end
        end
      end

      def fetch_availability
        _log.info("DELETEME fetch_availability")
        fetch_deployment_availabilities
        fetch_server_availabilities(collector.eaps)
        fetch_server_availabilities(collector.domain_servers)
        fetch_domain_availabilities
      end

      def fetch_deployment_availabilities
        collected_deployments = collector.deployments
        collection = persister.middleware_deployments
        return if collected_deployments.empty? || collection.data.empty?
        _log.info("DELETEME fetch_deployment_availabilities collected_deployments #{collected_deployments}")
        _log.info("DELETEME fetch_deployment_availabilities collection #{collection}")
        _log.info("DELETEME fetch_deployment_availabilities collection.first #{collection.data.first}")
        metric_name = collection.data.first.model_class::AVAIL_TYPE_ID
        fetch_availabilities_for(collected_deployments,
                                 collection,
                                 metric_name) do |deployment, availability|
          deployment.status = process_deployment_availability(availability)
          _log.info("DELETEME deployment.status #{deployment.status}")
        end
        subdeployments_by_deployment_id = collector.subdeployments.group_by(&:parent_id)
        subdeployments_by_deployment_id.keys.each do |parent_id|
          deployment = collection.find_by(:ems_ref => parent_id)
          subdeployments_by_deployment_id.fetch(parent_id).each do |collected_subdeployment|
            subdeployment = collection.find_by(:ems_ref => collected_subdeployment.id)
            subdeployment.status = deployment.status
          end
        end
      end

      def fetch_server_availabilities(collected_servers)
        collection = persister.middleware_servers
        return if collected_servers.empty? || collection.data.empty?
        metric_name = collection.data.first.model_class::AVAIL_TYPE_ID
        _log.info("DELETEME fetch_server_availabilities #{collected_servers}")
        _log.info("DELETEME fetch_server_availabilities #{collection}")
        fetch_availabilities_for(collected_servers,
                                 collection,
                                 metric_name) do |server, availability|
           props = server.properties
           props['Availability'], props['Calculated Server State'] =
             process_server_availability(props['Server State'], availability)
           ## TODO Check if Calculated Server State needs additional logic
           server.properties['Calculated Server State'] = server.properties['Availability']
           _log.info("DELETEME server.properties #{server.properties}")
         end
      end

      def fetch_domain_availabilities
        collected_domains = collector.domains
        collection = persister.middleware_domains
        return if collected_domains.empty? || collection.data.empty?
        metric_name = collection.data.first.model_class::AVAIL_TYPE_ID
        _log.info("DELETEME fetch_domain_availabilities #{collected_domains}")
        _log.info("DELETEME fetch_domain_availabilities #{collection}")
        fetch_availabilities_for(collected_domains,
                                 collection,
                                 metric_name) do |domain, availability|
          domain.properties['Availability'] = process_domain_availability(availability)
          _log.info("DELETEME domain.properties #{domain.properties}")
        end
      end

      def fetch_availabilities_for(inventory_entities, entities, metric_name)
        inventory_entities.each do |inventory_entity|
          entity = entities.find_by(:ems_ref => inventory_entity.id)
          availability = nil
          availability_metric = filter_metric(inventory_entity, metric_name)
          if availability_metric
            availability = collector.raw_availability_data([availability_metric.to_h], Time.now.to_i)
            _log.info("DELETEME fetch_availabilities_for availability #{availability}")
          end
          yield(entity, availability)
        end
      end

      def process_server_entity(server, entity)
        if @supported_deployments.include?(entity.type.id)
          inventory_object = persister.middleware_deployments.find_or_build(entity.id)
          parse_deployment(entity, inventory_object)
        elsif @supported_datasources.include?(entity.type.id)
          inventory_object = persister.middleware_datasources.find_or_build(entity.id)
          parse_datasource(entity, inventory_object)
        else
          inventory_object = persister.middleware_messagings.find_or_build(entity.id)
          parse_messaging(entity, inventory_object)
        end

        inventory_object.middleware_server = persister.middleware_servers.lazy_find(server.ems_ref)
        inventory_object.middleware_server_group = server.middleware_server_group if inventory_object.respond_to?(:middleware_server_group=)
      end

      def process_server_availability(server_state, availability = nil)
        avail = if availability.first['value'] && availability.first['value'][1] == '1'
                  'Running'
                else
                  'STOPPED'
                end
        [avail, avail == 'Running' ? server_state : avail]
      end

      def process_deployment_availability(availability = nil)
        if availability.first['value'] && availability.first['value'][1] == '1'
          'Enabled'
        else
          'Disabled'
        end
      end

      def process_domain_availability(availability = nil)
        if availability.first['value'] && availability.first['value'][1] == '1'
          'Running'
        else
          'STOPPED'
        end
      end

      def parse_deployment(deployment, inventory_object)
        parse_base_item(deployment, inventory_object)
        inventory_object.name = deployment.name
        if deployment.type.id == 'SubDeployment'
          inventory_object.properties[inventory_object.model_class::PARENT_DEPLOYMENT_ID_PROPERTY] = deployment.parent_id
        end
      end

      def parse_messaging(messaging, inventory_object)
        parse_base_item(messaging, inventory_object)
        inventory_object.name = messaging.name

        inventory_object.messaging_type = messaging.type.id
        inventory_object.properties = messaging.config.except('Username', 'Password')
      end

      def parse_datasource(datasource, inventory_object)
        parse_base_item(datasource, inventory_object)
        inventory_object.name = datasource.name

        inventory_object.properties = datasource.config.except('Username', 'Password')
      end

      def parse_middleware_domain(domain, inventory_object)
        parse_base_item(domain, inventory_object)
        inventory_object.name = domain.name
        inventory_object.type_path = domain.type.id
      end

      def parse_middleware_server_group(group, inventory_object)
        parse_base_item(group, inventory_object)
        inventory_object.assign_attributes(
          :name      => group.name,
          :type_path => group.type.id,
          :profile   => group.config['Profile']
        )
      end

      def parse_middleware_server(eap, inventory_object, domain = false)
        parse_base_item(eap, inventory_object)

        not_started = domain && eap.config['Server State'] == 'STOPPED'

        hostname, product = ['Hostname', 'Product Name'].map do |x|
          not_started && eap.config[x].nil? ? _('not yet available') : eap.config[x]
        end

        attributes = {
          :name      => eap.name,
          :type_path => eap.type.id,
          :hostname  => hostname,
          :product   => product
        }

        case product
        when /wildfly/i
          attributes[:type] = 'ManageIQ::Providers::Hawkular::MiddlewareManager::MiddlewareServerWildfly'
        when /eap/i
          attributes[:type] = 'ManageIQ::Providers::Hawkular::MiddlewareManager::MiddlewareServerEap'
        end

        inventory_object.assign_attributes(attributes)
      end

      def associate_with_vm(server, feed)
        # Add the association to vm instance if there is any
        machine_id =  machine_id_by_feed(feed)
        host_instance = find_host_by_bios_uuid(machine_id) ||
                        find_host_by_bios_uuid(alternate_machine_id(machine_id)) ||
                        find_host_by_bios_uuid(dashed_machine_id(machine_id))
        set_lives_on(server, host_instance) if host_instance
      end

      private

      def parse_base_item(item, inventory_object)
        inventory_object.nativeid = item.id
        inventory_object[:properties] = item.config if item.respond_to?(:config)
        inventory_object[:feed] = item.feed if item.respond_to?(:feed)
      end

      def filter_metric(inventory_item, metric_name)
        selected_metric = nil
        inventory_item.metrics.each do |metric|
          next unless metric.name.eql?(metric_name)
          selected_metric = metric
          break
        end
        selected_metric
      end
    end
  end
end
