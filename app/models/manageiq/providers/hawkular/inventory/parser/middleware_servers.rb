module ManageIQ::Providers::Hawkular::Inventory::Parser
  class MiddlewareServers < ManagerRefresh::Inventory::Parser
    include ManageIQ::Providers::Hawkular::Inventory::Parser::HelpersMixin
    include ManageIQ::Providers::Hawkular::Inventory::Parser::AvailabilityMixin

    def initialize
      super
      @data_index = {}
    end

    def parse
      fetch_oss_configuration
      fetch_agents_configuration
      fetch_and_parse_middleware_servers
      fetch_server_availabilities
    end

    protected

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

    def fetch_and_parse_middleware_servers
      fetch_middleware_servers do |eap|
        parse_middleware_server(eap, persister.middleware_servers.find_or_build(eap.id))
      end
    end

    def fetch_middleware_servers
      collector.eaps.each { |eap| yield(eap) }
    end

    def collected_resources
      collector.eaps
    end

    def fetch_server_availabilities
      collection = persister.middleware_servers
      fetch_availabilities_for(collected_resources,
                               collection,
                               collection.model_class::AVAIL_TYPE_ID) do |server, availability|
        props = server.properties
        props['Availability'], props['Calculated Server State'] =
          process_server_availability(props['Server State'], availability)
      end
    end

    def parse_middleware_server(eap, inventory_object)
      parse_main_properties(eap, inventory_object)
      parse_immutability_through_agent(eap, inventory_object)
      parse_underlying_host(eap, inventory_object)
    end

    def parse_main_properties(eap, inventory_object)
      parse_base_item(eap, inventory_object)

      started = parse_started_state(eap)

      hostname, product = ['Hostname', 'Product Name'].map do |x|
        !started && eap.config[x].nil? ? _('not yet available') : eap.config[x]
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

    def parse_started_state(_)
      true
    end

    def parse_immutability_through_agent(eap, server)
      agent_config = agent_config_by_feed(eap.feed)
      ['Immutable', 'In Container'].each do |feature|
        server.properties[feature] = 'true' if agent_config.try(:[], feature) == 'true'
      end
    end

    def parse_underlying_host(eap, server)
      if server.properties['In Container'] == 'true'
        container_id = container_id_by_feed(eap.feed)
        if container_id
          backing_ref = 'docker://' + container_id
          container = Container.find_by(:backing_ref => backing_ref)
          set_lives_on(server, container) if container
        end
      else
        associate_with_vm(server, eap.feed)
      end
    end

    def associate_with_vm(server, feed)
      # Add the association to vm instance if there is any
      machine_id =  machine_id_by_feed(feed)
      host_instance = find_host_by_bios_uuid(machine_id) ||
                      find_host_by_bios_uuid(alternate_machine_id(machine_id)) ||
                      find_host_by_bios_uuid(dashed_machine_id(machine_id))
      set_lives_on(server, host_instance) if host_instance
    end

    def set_lives_on(server, lives_on)
      server.lives_on_id = lives_on.id
      server.lives_on_type = lives_on.type
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

    def process_server_availability(server_state, availability = nil)
      return %w(unknown unknown) if availability.blank?
      avail = if availability.first['value'] && availability.first['value'][1] == '1'
                'Running'
              else
                'STOPPED'
              end
      [avail, avail == 'Running' ? server_state : avail]
    end

    def machine_id_by_feed(feed)
      @data_index.fetch_path(:middleware_os_config, :by_feed, feed).try(:fetch, 'Machine Id', nil)
    end

    def container_id_by_feed(feed)
      @data_index.fetch_path(:middleware_os_config, :by_feed, feed).try(:fetch, 'Container Id', nil)
    end

    def agent_config_by_feed(feed)
      @data_index.fetch_path(:middleware_agent_config, :by_feed, feed)
    end
  end
end
