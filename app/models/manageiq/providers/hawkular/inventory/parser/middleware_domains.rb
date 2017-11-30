module ManageIQ::Providers::Hawkular::Inventory::Parser
  class MiddlewareDomains < ManagerRefresh::Inventory::Parser
    include ManageIQ::Providers::Hawkular::Inventory::Parser::HelpersMixin
    include ManageIQ::Providers::Hawkular::Inventory::Parser::AvailabilityMixin

    def parse
      fetch_domains_and_groups
      fetch_domain_availabilities
    end

    protected

    def fetch_domains_and_groups
      collector.host_controllers.each do |host_controller|
        host_controller = collector.resource_tree(host_controller.id)
        host_controller.children_domain_hosts.each do |domain|
          parsed_domain = persister.middleware_domains.find_or_build(domain.id)
          parse_middleware_domain(domain, parsed_domain)

          # add the server groups to the domain
          fetch_server_groups(parsed_domain, host_controller)
        end
      end
    end

    def fetch_server_groups(parsed_domain, host_controller)
      host_controller.children_server_groups.map do |group|
        parsed_group = persister.middleware_server_groups.find_or_build(group.id)
        parse_middleware_server_group(group, parsed_group)
        parsed_group.middleware_domain = persister.middleware_domains.lazy_find(parsed_domain[:ems_ref])
      end
    end

    def fetch_domain_availabilities
      collection = persister.middleware_domains
      fetch_availabilities_for(collector.domains, collection, collection.model_class::AVAIL_TYPE_ID) do |domain, availability|
        domain.properties['Availability'] =
          process_domain_availability(availability.try(:[], 'data').try(:first))
      end
    end

    def process_domain_availability(availability = nil)
      process_availability(availability, 'up' => 'Running', 'down' => 'Stopped')
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
  end
end
