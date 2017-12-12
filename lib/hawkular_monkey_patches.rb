module MonkeyPatches
  module Hawkular
    module Inventory
      module DomainEntities
        def domain_controller?
          config['Is Domain Controller'] == 'true'
        end

        def children_domain_controllers(recursive = false)
          children_domain_hosts(recursive).select(&:domain_controller?)
        end

        def children_domain_hosts(recursive = false)
          children_domain_hosts = []
          ManageIQ::Providers::Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
            children_domain_hosts += children_by_type("Domain Host #{version}", recursive)
            break unless children_domain_hosts.empty?
          end
          children_domain_hosts
        end

        def children_server_groups(recursive = false)
          children_server_groups = []
          ManageIQ::Providers::Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
            children_server_groups += children_by_type("Domain Server Group #{version}", recursive)
            break unless children_server_groups.empty?
          end
          children_server_groups
        end

        def children_domain_servers(recursive = false)
          children_domain_servers = []
          ManageIQ::Providers::Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
            children_domain_servers += children_by_type("Domain WildFly Server #{version}", recursive)
            break unless children_domain_servers.empty?
          end
          children_domain_servers
        end
      end
    end
  end
end

Hawkular::Inventory::Resource.include MonkeyPatches::Hawkular::Inventory::DomainEntities
