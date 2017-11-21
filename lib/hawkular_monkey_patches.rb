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
          children_by_type('Domain Host', recursive)
        end

        def children_server_groups(recursive = false)
          children_by_type('Domain Server Group', recursive)
        end

        def children_domain_servers(recursive = false)
          children_by_type('Domain WildFly Server', recursive)
        end
      end
    end
  end
end

Hawkular::Inventory::Resource.include MonkeyPatches::Hawkular::Inventory::DomainEntities
