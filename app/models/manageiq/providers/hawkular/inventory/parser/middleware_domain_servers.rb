module ManageIQ::Providers::Hawkular::Inventory::Parser
  class MiddlewareDomainServers < ::ManageIQ::Providers::Hawkular::Inventory::Parser::MiddlewareServers
    protected

    def fetch_middleware_servers
      collector.host_controllers.each do |host_controller|
        host_controller = collector.resource_tree(host_controller.id)
        host_controller.children_domain_servers(true).each do |domain_server|
          yield(domain_server)
        end
      end
    end

    def collected_resources
      collector.domain_servers
    end

    def parse_middleware_server(server, inventory_object)
      super
      parse_server_group(server, inventory_object)
    end

    def parse_server_group(server, inventory_object)
      # Add the association to server group. The information about what server is in which server group is under
      # the server-config resource's configuration
      server_group_name = server.config['Server Group']
      unless server_group_name.nil?
        inventory_object.middleware_server_group =
          persister.middleware_server_groups
                   .lazy_find_by({:feed => server.feed, :name => server_group_name}, {:ref => :by_feed_and_name})
      end
    end

    def parse_started_state(server)
      server.config['Server State'] != 'STOPPED'
    end
  end
end
