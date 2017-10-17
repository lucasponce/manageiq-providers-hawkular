module ManageIQ::Providers
  module Hawkular
    class Inventory::Parser::MiddlewareManager < ManagerRefresh::Inventory::Parser
      include ::Hawkular::ClientUtils

      def initialize
        super
        @data_index = {}
      end

      def parse
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
          agent_config = @data_index.fetch_path(:middleware_agent_config, :by_feed, eap.feed)
          ['Immutable', 'In Container'].each do |feature|
            server.properties[feature] = 'true' if agent_config[feature] == true
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
          collector.domains(host_controller).each do |domain|
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
        collector.server_groups(host_controller).map do |group|
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
        collector.domain_servers(host_controller).each do |domain_server|
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
            next unless ['Deployment', 'Datasource', 'JMS Queue', 'JMS Topic'].include? child.type.id
            process_server_entity(eap, child)
          end
        end
      end

      def fetch_availability
        feeds_of_interest = persister.middleware_servers.to_a.map(&:feed).uniq
        fetch_server_availabilities(feeds_of_interest)
        fetch_deployment_availabilities(feeds_of_interest)
        fetch_domain_availabilities(feeds_of_interest)
      end

      def fetch_deployment_availabilities(feeds)
        collection = persister.middleware_deployments
        fetch_availabilities_for(feeds, collection, collection.model_class::AVAIL_TYPE_ID) do |deployment, availability|
          deployment.status = process_deployment_availability(availability.try(:[], 'data').try(:first))
        end
      end

      def fetch_server_availabilities(feeds)
        collection = persister.middleware_servers
        fetch_availabilities_for(feeds, collection, collection.model_class::AVAIL_TYPE_ID) do |server, availability|
          props = server.properties

          props['Availability'], props['Calculated Server State'] =
            process_server_availability(props['Server State'], availability.try(:[], 'data').try(:first))
        end
      end

      def fetch_domain_availabilities(feeds)
        collection = persister.middleware_domains
        fetch_availabilities_for(feeds, collection, collection.model_class::AVAIL_TYPE_ID) do |domain, availability|
          domain.properties['Availability'] =
            process_domain_availability(availability.try(:[], 'data').try(:first))
        end
      end

      def fetch_availabilities_for(feeds, collection, metric_type_id)
        resources_by_metric_id = {}
        metric_id_by_resource_path = {}

        feeds.each do |feed|
          status_metrics = collector.metrics_for_metric_type(feed, metric_type_id)
          status_metrics.each do |status_metric|
            status_metric_path = ::Hawkular::Inventory::CanonicalPath.parse(status_metric.path)
            # By dropping metric_id from the canonical path we end up with the resource path
            resource_path = ::Hawkular::Inventory::CanonicalPath.new(
              :tenant_id    => status_metric_path.tenant_id,
              :feed_id      => status_metric_path.feed_id,
              :resource_ids => status_metric_path.resource_ids
            )
            metric_id_by_resource_path[URI.decode(resource_path.to_s)] = status_metric.hawkular_metric_id
          end
        end

        collection.each do |item|
          yield item, nil

          path = URI.decode(item.try(:resource_path_for_metrics) ||
            item.try(:model_class).try(:resource_path_for_metrics, item) ||
            item.try(:ems_ref) ||
            item.manager_uuid)
          next unless metric_id_by_resource_path.key? path
          metric_id = metric_id_by_resource_path[path]
          resources_by_metric_id[metric_id] = [] unless resources_by_metric_id.key? metric_id
          resources_by_metric_id[metric_id] << item
        end

        unless resources_by_metric_id.empty?
          availabilities = collector.raw_availability_data(resources_by_metric_id.keys,
                                                           :limit => 1, :order => 'DESC')
          availabilities.each do |availability|
            resources_by_metric_id[availability['id']].each do |resource|
              yield resource, availability
            end
          end
        end
      end

      def process_entity_with_config(server, entity, inventory_object, continuation)
        send(continuation, entity, inventory_object, entity.config)
      end

      def process_server_entity(server, entity)
        if entity.type.id == 'Deployment'
          inventory_object = persister.middleware_deployments.find_or_build(entity.id)
          parse_deployment(entity, inventory_object)
        elsif entity.type.id == 'Datasource'
          inventory_object = persister.middleware_datasources.find_or_build(entity.id)
          process_entity_with_config(server, entity, inventory_object, :parse_datasource)
        else
          inventory_object = persister.middleware_messagings.find_or_build(entity.id)
          process_entity_with_config(server, entity, inventory_object, :parse_messaging)
        end

        inventory_object.middleware_server = persister.middleware_servers.lazy_find(server.ems_ref)
        inventory_object.middleware_server_group = server.middleware_server_group if inventory_object.respond_to?(:middleware_server_group=)
      end

      def process_server_availability(server_state, availability = nil)
        avail = availability.try(:[], 'value') || 'unknown'
        [avail, avail == 'up' ? server_state : avail]
      end

      def process_deployment_availability(availability = nil)
        process_availability(availability, 'up' => 'Enabled', 'down' => 'Disabled')
      end

      def process_domain_availability(availability = nil)
        process_availability(availability, 'up' => 'Running', 'down' => 'Stopped')
      end

      def process_availability(availability, translation = {})
        translation.fetch(availability.try(:[], 'value').try(:downcase), 'Unknown')
      end

      def parse_deployment(deployment, inventory_object)
        parse_base_item(deployment, inventory_object)
        inventory_object.name = deployment.name
      end

      def parse_messaging(messaging, inventory_object, config)
        parse_base_item(messaging, inventory_object)
        inventory_object.name = messaging.name

        inventory_object.messaging_type = messaging.type.id
        inventory_object.properties = config

        inventory_object.properties = config.except('Username', 'Password')
      end

      def parse_datasource(datasource, inventory_object, config)
        parse_base_item(datasource, inventory_object)
        inventory_object.name = datasource.name

        inventory_object.properties = config.except('Username', 'Password')
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
        machine_id = @data_index.fetch_path(:middleware_os_config, :by_feed, feed)['Machine Id']
        host_instance = find_host_by_bios_uuid(machine_id) ||
                        find_host_by_bios_uuid(alternate_machine_id(machine_id)) ||
                        find_host_by_bios_uuid(dashed_machine_id(machine_id))
        set_lives_on(server, host_instance) if host_instance
      end

      private

      def parse_base_item(item, inventory_object)
        inventory_object.nativeid = item.id

        [:properties, :feed].each do |field|
          inventory_object[field] = item.send(field) if item.respond_to?(field)
        end
      end
    end
  end
end
